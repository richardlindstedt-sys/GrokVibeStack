<#
.SYNOPSIS
    Run all vibe static analysis scanners on the current directory or specific paths.
.DESCRIPTION
    Runs: Trivy, Gitleaks, PSScriptAnalyzer, Pester (if tests), jscpd, Biome (JS/TS), markdownlint,
          Semgrep, Ruff/mypy/bandit/vulture (Python), yamllint/checkov (YAML/IaC), ShellCheck, Hadolint (Docker),
          + rg hints for TODOs/unwired code.
    Exits non-zero on critical findings (secrets, HIGH/CRITICAL vulns, analyzer errors, failed tests).
#>
[CmdletBinding()]
param(
    [string[]]$Paths = @('.'),
    [switch]$Quiet,
    # Auto = staged-first when index non-empty; Staged = require staged; Full = whole tree
    [ValidateSet('Auto', 'Staged', 'Full')]
    [string]$Scope = 'Auto'
)

$ErrorActionPreference = 'Continue'
$failed = 0
$advisory = 0
$root = (Get-Location).Path
if ($env:VIBE_SCAN_SCOPE -match '^(?i)auto$') { $Scope = 'Auto' }
elseif ($env:VIBE_SCAN_SCOPE -match '^(?i)staged$') { $Scope = 'Staged' }
elseif ($env:VIBE_SCAN_SCOPE -match '^(?i)full$') { $Scope = 'Full' }
# Local / tool noise never treated as product findings
$script:ScanExcludeRegex = '(\\node_modules\\|\\\.git\\|\\\.serena\\|\\venv\\|\\\.venv\\|\\\.grok\\|\\__pycache__\\|\\\.tox\\|\\dist\\|\\build\\)'
# Shared Full-only scan-pass cache (Save/Test/Get-TreeHash)
. (Join-Path $PSScriptRoot 'scan-pass-cache.ps1')

# Ensure vibe scanner bins + common tooling are visible even if shell PATH is stale.
foreach ($p in @(
    (Join-Path $env:USERPROFILE '.grok\vibe-tools\venv\Scripts'),
    (Join-Path $env:USERPROFILE '.grok\token-saving\venv\Scripts'),
    (Join-Path $env:USERPROFILE '.local\bin'),
    (Join-Path $env:USERPROFILE '.grok\bin'),
    'C:\Program Files\GitHub CLI'
)) {
    if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
        $env:PATH = "$p;$env:PATH"
    }
}

$script:VibePython = Join-Path $env:USERPROFILE '.grok\vibe-tools\venv\Scripts\python.exe'

function Test-ToolRunnable([string]$cmd) {
    $c = Get-Command $cmd -ErrorAction SilentlyContinue
    if (-not $c) { return $false }
    # Windows pip shims can exist while the package is broken (e.g. checkov.cmd)
    if ($c.Source -and ($c.Source -match '\.cmd$')) {
        try {
            $probe = & $cmd --version 2>&1
            if ("$probe" -match 'ModuleNotFoundError|No module named') { return $false }
            if ($LASTEXITCODE -ne 0 -and "$probe" -match '(?i)error|traceback') { return $false }
        } catch { return $false }
    }
    return $true
}

function Get-StagedNameList {
    $names = @()
    try {
        $names = @(git diff --cached --name-only --diff-filter=ACMR 2>$null | Where-Object { $_ })
    } catch {}
    return $names
}

function New-StagedScanTree {
    <#
      Materialize staged blob contents into a temp tree (binary-safe via checkout-index).
      Returns temp root only when EVERY expected staged path was written.
      On any materialize miss: cleans temp, sets $script:StagedMaterializeFailed, returns $null.
    #>
    param([string[]]$Names)
    $script:StagedMaterializeFailed = $false
    if (-not $Names -or $Names.Count -eq 0) { return $null }
    $tmp = Join-Path $env:TEMP ("vibe-staged-" + [guid]::NewGuid().ToString('n').Substring(0, 10))
    # trailing separator required by git checkout-index --prefix
    $prefix = $tmp.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $n = 0
    $expected = 0
    $missing = [System.Collections.Generic.List[string]]::new()
    $safeGitPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($rel in $Names) {
        $relWin = $rel -replace '/', [IO.Path]::DirectorySeparatorChar
        if ($relWin -match '(?i)(^|[\\/])\.git([\\/]|$)' -or $relWin -match '\.\.') {
            if (-not $Quiet) { Write-Host "  staged skip (unsafe path): $relWin" -ForegroundColor DarkGray }
            continue
        }
        $dest = Join-Path $tmp $relWin
        $fullDest = [System.IO.Path]::GetFullPath($dest)
        $fullTmp = [System.IO.Path]::GetFullPath($tmp)
        if (-not $fullDest.StartsWith($fullTmp, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (-not $Quiet) { Write-Host "  staged skip (path escape): $relWin" -ForegroundColor DarkGray }
            continue
        }
        $expected++
        $gitPath = ($relWin -replace '\\', '/')
        [void]$safeGitPaths.Add($gitPath)
    }

    if ($expected -eq 0) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Binary-safe: checkout index blobs into temp prefix (preserves raw bytes)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $root
    try {
        if ($safeGitPaths.Count -gt 0) {
            & git checkout-index --prefix=$prefix -f -- @($safeGitPaths.ToArray()) 2>$null | Out-Null
        }
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevEap
    }

    foreach ($gitPath in $safeGitPaths) {
        $relWin = $gitPath -replace '/', [IO.Path]::DirectorySeparatorChar
        $dest = Join-Path $tmp $relWin
        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            $n++
            continue
        }
        # Fallback: redirect git show raw stdout to file (still binary-safe)
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path -LiteralPath $destDir)) {
            try { New-Item -ItemType Directory -Force -Path $destDir | Out-Null } catch {}
        }
        $wrote = $false
        try {
            $p = Start-Process -FilePath 'git' -ArgumentList @('show', ":0:$gitPath") `
                -WorkingDirectory $root -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $dest -RedirectStandardError (Join-Path $env:TEMP 'vibe-git-show.err')
            if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $dest -PathType Leaf)) {
                $n++
                $wrote = $true
            }
        } catch {}
        # Never copy the worktree: index blob missing must fail materialize
        # (secret only in the index + cleaned disk would otherwise false-pass).
        if (-not $wrote) {
            [void]$missing.Add($relWin)
            if (-not $Quiet) { Write-Host "  staged missing: $relWin (index blob unavailable)" -ForegroundColor Yellow }
        }
    }

    if ($n -lt $expected) {
        if (-not $Quiet) {
            Write-Host ("[Staged scan tree] FAILED: materialized {0}/{1} path(s) — refusing partial scan" -f $n, $expected) -ForegroundColor Yellow
            foreach ($m in $missing) { Write-Host "  not scanned: $m" -ForegroundColor Yellow }
        }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        $script:StagedMaterializeFailed = $true
        return $null
    }
    return $tmp
}

function Invoke-Checkov {
    param([string[]]$CkArgs)
    # checkov.cmd is a broken PATH-python shim on Windows; drive via venv python.
    $output = $null
    $code = $null
    if (Test-Path -LiteralPath $script:VibePython) {
        # Probe import first — partial venv (python present, checkov missing) must SKIP not fail gate.
        $probeOut = $null
        try {
            $probeOut = & $script:VibePython -c "import checkov" 2>&1
            $probeCode = $LASTEXITCODE
        } catch {
            $probeOut = "$_"
            $probeCode = -1
        }
        $probeText = if ($null -eq $probeOut) { '' } else { "$probeOut" }
        if ($probeCode -ne 0 -or $probeText -match 'ModuleNotFoundError|ImportError|No module named') {
            return @{ Ok = $false; Ran = $false; Output = $probeOut; ExitCode = $null }
        }
        # Unique launcher path — avoids concurrent TEMP clobber
        $launcher = Join-Path $env:TEMP ("vibe-checkov-run-{0}.py" -f [guid]::NewGuid().ToString('n').Substring(0, 8))
        @(
            'import sys'
            'from checkov.main import Checkov'
            'sys.argv[0] = "checkov"'
            'raise SystemExit(Checkov().run())'
        ) -join "`n" | Set-Content -Path $launcher -Encoding utf8
        try {
            $output = & $script:VibePython $launcher @CkArgs 2>&1
            $code = $LASTEXITCODE
        } catch {
            $output = "$_"
            $code = -1
        } finally {
            Remove-Item -LiteralPath $launcher -Force -ErrorAction SilentlyContinue
        }
        return @{ Ok = $true; Ran = $true; Output = $output; ExitCode = $code }
    }
    if (Test-ToolRunnable 'checkov') {
        try {
            $output = & checkov @CkArgs 2>&1
            $code = $LASTEXITCODE
        } catch {
            $output = "$_"
            $code = -1
        }
        return @{ Ok = $true; Ran = $true; Output = $output; ExitCode = $code }
    }
    return @{ Ok = $false; Ran = $false; Output = $null; ExitCode = $null }
}

function Run {
    param(
        [string]$cmd,
        [object[]]$cmdArgs,
        [string]$name,
        # style / noise tools: report but do not fail the gate
        [switch]$Advisory
    )
    if (-not (Test-ToolRunnable $cmd)) {
        if (-not $Quiet) { Write-Host "[$name] SKIPPED (not installed or broken shim)" -ForegroundColor DarkGray }
        return
    }
    if (-not $Quiet) { Write-Host "`n[$name] $cmd $cmdArgs" -ForegroundColor Cyan }
    & $cmd @cmdArgs 2>&1 | ForEach-Object {
        if (-not $Quiet) { $_ }
    }
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        if ($Advisory) {
            $script:advisory++
            if (-not $Quiet) { Write-Host "[$name] exited $LASTEXITCODE (advisory)" -ForegroundColor DarkYellow }
        } else {
            $script:failed++
            if (-not $Quiet) { Write-Host "[$name] exited $LASTEXITCODE" -ForegroundColor Yellow }
        }
    }
}

function Run-PSScriptAnalyzer {
    param([string]$ScanRoot = $root)
    if (-not (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
        if (-not $Quiet) { Write-Host "[PSScriptAnalyzer] SKIPPED (module not imported)" -ForegroundColor DarkGray }
        return
    }
    if (-not $Quiet) { Write-Host "`n[PSScriptAnalyzer] scanning PowerShell files..." -ForegroundColor Cyan }
    $psFiles = Get-ChildItem -Path $ScanRoot -Recurse -Include *.ps1,*.psm1,*.psd1 -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex }
    if (-not $psFiles) { return }
    # Style/noise rules that drown real defects in installer scripts
    $exclude = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        'PSUseBOMForUnicodeEncodedFile',
        'PSAvoidUsingEmptyCatchBlock',
        'PSReviewUnusedParameter',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSPossibleIncorrectComparisonWithNull',
        'PSUseUsingScopeModifierInNewRunspaces'
    )
    $results = Invoke-ScriptAnalyzer -Path $ScanRoot -Recurse -Severity Error,Warning -ExcludeRule $exclude -ErrorAction SilentlyContinue |
        Where-Object { $_.ScriptName -and ($_.ScriptName -notmatch $script:ScanExcludeRegex) }
    if ($results) {
        $errors = @($results | Where-Object Severity -eq 'Error')
        $warns = @($results | Where-Object Severity -eq 'Warning')
        foreach ($r in $errors) {
            if (-not $Quiet) { Write-Host "  Error: $($r.RuleName) - $($r.ScriptName):$($r.Line) - $($r.Message)" -ForegroundColor Yellow }
        }
        # Cap warning dump
        $show = $warns | Select-Object -First 15
        foreach ($r in $show) {
            if (-not $Quiet) { Write-Host "  Warning: $($r.RuleName) - $($r.ScriptName):$($r.Line) - $($r.Message)" -ForegroundColor DarkGray }
        }
        if ($warns.Count -gt 15 -and -not $Quiet) {
            Write-Host "  ... $($warns.Count - 15) more warning(s) suppressed" -ForegroundColor DarkGray
        }
        if ($errors.Count -gt 0) { $script:failed++ }
    } elseif (-not $Quiet) {
        Write-Host "  Clean (no Error findings; noisy style rules excluded)" -ForegroundColor Green
    }
}

function Run-Pester {
    if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        if (-not $Quiet) { Write-Host "[Pester] SKIPPED (not installed)" -ForegroundColor DarkGray }
        return
    }
    $testFiles = Get-ChildItem -Recurse -Include *.Tests.ps1,*Spec.ps1 -Depth 5 -ErrorAction SilentlyContinue
    if (-not $testFiles) { return }
    if (-not $Quiet) { Write-Host "`n[Pester] running tests..." -ForegroundColor Cyan }
    try {
        $config = New-PesterConfiguration
        $config.Run.Path = $root
        $config.Run.PassThru = $true
        $config.Output.Verbosity = 'Normal'
        $config.Should.ErrorAction = 'Continue'
        $res = Invoke-Pester -Configuration $config
        if ($res.FailedCount -gt 0) {
            if (-not $Quiet) { Write-Host "[Pester] $($res.FailedCount) failed test(s)" -ForegroundColor Yellow }
            $script:failed++
        }
    } catch {
        if (-not $Quiet) { Write-Host "[Pester] Error running: $_" -ForegroundColor Yellow }
    }
}

Write-Host "=== Vibe Static Scans ===" -ForegroundColor Cyan
Write-Host "Scanning: $($Paths -join ', ')  scope=$Scope"

$stagedNames = @(Get-StagedNameList)
$useStaged = $false
if ($Scope -eq 'Full') {
    $useStaged = $false
} elseif ($Scope -eq 'Staged') {
    $useStaged = $true
    if ($stagedNames.Count -eq 0) {
        if (-not $Quiet) { Write-Host "[Scope=Staged] no staged files — nothing to scan (pass)." -ForegroundColor DarkGray }
        exit 0
    }
} else {
    # Auto: staged-first when index has paths
    $useStaged = ($stagedNames.Count -gt 0)
}

$stagedTree = $null
$script:StagedMaterializeFailed = $false
$scanRoot = $root
if ($useStaged) {
    $stagedTree = New-StagedScanTree -Names $stagedNames
    if ($script:StagedMaterializeFailed) {
        $script:failed++
        if (-not $Quiet) {
            Write-Host "[Staged scan tree] gate fail (incomplete materialize)" -ForegroundColor Yellow
        }
    } elseif ($stagedTree) {
        $scanRoot = $stagedTree
        if (-not $Quiet) {
            Write-Host ("Staged-first: {0} path(s) -> temp tree (secrets + lang scanners)" -f $stagedNames.Count) -ForegroundColor DarkCyan
        }
    }
}

try {
    # Trivy
    if ($stagedTree) {
        $trivyTarget = @($stagedTree)
    } elseif ($Paths -and @($Paths).Count -gt 0) {
        $trivyTarget = @($Paths)
    } else {
        $trivyTarget = @($root)
    }
    $trivyArgs = @(
        'fs', '--exit-code', '1', '--severity', 'HIGH,CRITICAL',
        '--scanners', 'vuln,secret,misconfig',
        '--skip-dirs', '.git,.serena,node_modules,venv,.venv'
    ) + $trivyTarget
    Run 'trivy' $trivyArgs 'Trivy'

    # Gitleaks
    if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
        if ($stagedTree) {
            Run 'gitleaks' @('detect', '--source', $stagedTree, '--no-git', '--redact') 'Gitleaks (staged)'
        } else {
            Run 'gitleaks' @('detect', '--source', $root, '--redact') 'Gitleaks'
            Run 'gitleaks' @('detect', '--source', $root, '--no-git', '--redact') 'Gitleaks (workdir)' -Advisory
        }
    } else {
        if (-not $Quiet) { Write-Host "[Gitleaks] SKIPPED (not installed)" -ForegroundColor DarkGray }
    }

    # Heuristic secret pass on staged tree
    if ($stagedTree) {
        $rx = [regex]'(?i)(-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----|xai-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})'
        $hits = @()
        Get-ChildItem -Path $stagedTree -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                # Read as bytes then UTF8 for heuristic; binary without text match is fine
                $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                if ($bytes.Length -gt 2MB) { return }
                $t = [System.Text.Encoding]::UTF8.GetString($bytes)
                if ($rx.IsMatch($t)) { $hits += $_.FullName.Substring($stagedTree.Length).TrimStart('\', '/') }
            } catch {}
        }
        if ($hits.Count -gt 0) {
            if (-not $Quiet) {
                Write-Host "`n[Secret heuristic] possible secrets in staged files:" -ForegroundColor Yellow
                $hits | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
            }
            $script:failed++
        } elseif (-not $Quiet) {
            Write-Host "[Secret heuristic] clean on staged tree" -ForegroundColor DarkGray
        }
    }

    # --- Lang / project scanners scoped to $scanRoot (staged tree or repo) ---
    Run-PSScriptAnalyzer -ScanRoot $scanRoot

    # Pester only on full tree (tests need project context)
    if (-not $useStaged) {
        Run-Pester
    } elseif (-not $Quiet) {
        Write-Host "[Pester] skipped in staged-first mode (run full scope / push)" -ForegroundColor DarkGray
    }

    # jscpd — blocking only when JS/TS (or similar) is in scope; else advisory
    if (Get-Command jscpd -ErrorAction SilentlyContinue) {
        if (-not $Quiet) { Write-Host "`n[jscpd] duplicate detection" -ForegroundColor Cyan }
        $jscpdTargets = [System.Collections.Generic.List[string]]::new()
        if ($stagedTree) {
            [void]$jscpdTargets.Add($stagedTree)
        } else {
            $pathList = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $pathsIsDefault = ($pathList.Count -eq 0) -or (
                $pathList.Count -eq 1 -and ($pathList[0] -eq '.' -or $pathList[0] -eq $root)
            )
            if (-not $pathsIsDefault) {
                foreach ($p in $pathList) {
                    $candidate = $p
                    if (-not (Test-Path -LiteralPath $candidate)) {
                        $joined = Join-Path $root $p
                        if (Test-Path -LiteralPath $joined) { $candidate = $joined } else { continue }
                    }
                    [void]$jscpdTargets.Add($candidate)
                }
            }
            if ($jscpdTargets.Count -eq 0) {
                foreach ($cand in @('assets', 'src', 'lib', 'scripts', 'app', 'packages', 'services')) {
                    if (Test-Path -LiteralPath (Join-Path $root $cand)) { [void]$jscpdTargets.Add($cand) }
                }
                Get-ChildItem -Path $root -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -match '\.(ps1|psm1|js|ts|tsx|jsx|py|go|rs|java|cs|md)$' -and $_.Name -notmatch '^\.' } |
                    Select-Object -First 40 |
                    ForEach-Object { [void]$jscpdTargets.Add($_.Name) }
            }
        }
        $jscpdDomain = $false
        $probeList = if ($stagedNames.Count -gt 0) { $stagedNames } else { @($jscpdTargets) }
        foreach ($pp in $probeList) {
            if ("$pp" -match '(?i)\.(js|jsx|ts|tsx|vue|mjs|cjs)$') { $jscpdDomain = $true; break }
        }
        if (-not $jscpdDomain) {
            $jsAny = Get-ChildItem -Path $scanRoot -Recurse -Include *.js,*.ts,*.tsx,*.jsx -Depth 4 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex } | Select-Object -First 1
            if ($jsAny) { $jscpdDomain = $true }
        }
        if ($jscpdTargets.Count -eq 0) {
            if (-not $Quiet) { Write-Host "[jscpd] SKIPPED (no source roots)" -ForegroundColor DarkGray }
        } else {
            $jscpdArgs = @($jscpdTargets.ToArray()) + @('-l', '6', '-k', '45')
            if (-not $Quiet) {
                $mode = if ($jscpdDomain) { 'blocking' } else { 'advisory' }
                Write-Host ("  targets: {0} ({1})" -f ($jscpdTargets -join ', '), $mode) -ForegroundColor DarkGray
            }
            $jscpdOut = & jscpd @jscpdArgs 2>&1
            if (-not $Quiet) { $jscpdOut | Select-Object -Last 25 }
            if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
                if ($jscpdDomain) {
                    $script:failed++
                    if (-not $Quiet) { Write-Host "[jscpd] exited $LASTEXITCODE" -ForegroundColor Yellow }
                } else {
                    $script:advisory++
                    if (-not $Quiet) { Write-Host "[jscpd] exited $LASTEXITCODE (advisory — no JS/TS in scope)" -ForegroundColor DarkYellow }
                }
            }
        }
    }

    # Biome
    $jsHit = Get-ChildItem -Path $scanRoot -Recurse -Include *.js,*.ts,*.jsx,*.tsx -Depth 4 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex } | Select-Object -First 1
    if ($jsHit -or (Test-Path (Join-Path $scanRoot 'package.json'))) {
        if ($stagedTree) {
            Run 'biome' @('check', $stagedTree) 'Biome'
        } else {
            Run 'biome' @('check') 'Biome'
        }
    }

    # markdownlint advisory
    if (Get-Command markdownlint -ErrorAction SilentlyContinue) {
        $mdFiles = Get-ChildItem -Path $scanRoot -Recurse -Include *.md -Depth 5 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex }
        if ($mdFiles) {
            $mdlTarget = if ($stagedTree) { $stagedTree } else { '.' }
            $mdlArgs = @(
                '--ignore', 'node_modules',
                '--ignore', '.serena',
                '--ignore', '.git',
                '--ignore', 'venv',
                $mdlTarget
            )
            if (-not (Test-Path (Join-Path $root '.markdownlint.json')) -and -not (Test-Path (Join-Path $root '.markdownlint.yaml'))) {
                $mdlArgs = @('-d', 'MD013,MD033,MD041,MD060') + $mdlArgs
            }
            Run 'markdownlint' $mdlArgs 'markdownlint' -Advisory
        }
    }

    # Semgrep
    if (Get-Command semgrep -ErrorAction SilentlyContinue) {
        $sgPath = if ($stagedTree) { $stagedTree } else { '.' }
        Run 'semgrep' @('scan', '--config=auto', '--severity=ERROR', '--error', '--quiet', $sgPath) 'Semgrep'
    }

    # Python
    $pyFiles = Get-ChildItem -Path $scanRoot -Recurse -Include *.py -Depth 4 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex } | Select-Object -First 1
    if ($pyFiles) {
        $pyTarget = if ($stagedTree) { $stagedTree } else { '.' }
        Run 'ruff' @('check', $pyTarget) 'Ruff'
        if (Get-Command vulture -ErrorAction SilentlyContinue) {
            Run 'vulture' @($pyTarget, '--min-confidence', '80') 'Vulture (dead code)'
        }
        if (Get-Command mypy -ErrorAction SilentlyContinue) {
            Run 'mypy' @($pyTarget, '--ignore-missing-imports', '--no-error-summary') 'mypy (types)'
        }
        if (Get-Command bandit -ErrorAction SilentlyContinue) {
            Run 'bandit' @('-r', $pyTarget, '-ll', '-q') 'bandit (Python security)'
        }
    }

    # YAML / IaC
    $yamlFiles = Get-ChildItem -Path $scanRoot -Recurse -Include *.yml,*.yaml -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex } | Select-Object -First 1
    if ($yamlFiles) {
        $ylTarget = if ($stagedTree) { $stagedTree } else { '.' }
        if (Get-Command yamllint -ErrorAction SilentlyContinue) {
            $ylCfg = Join-Path $env:TEMP ("vibe-yamllint-{0}.yml" -f [guid]::NewGuid().ToString('n').Substring(0, 8))
            @"
extends: default
ignore: |
  .serena/
  .git/
  node_modules/
  venv/
  .venv/
rules:
  line-length: disable
  document-start: disable
  truthy:
    check-keys: false
"@ | Set-Content -Path $ylCfg -Encoding utf8
            try {
                Run 'yamllint' @('-s', '-c', $ylCfg, $ylTarget) 'yamllint' -Advisory
            } finally {
                Remove-Item -LiteralPath $ylCfg -Force -ErrorAction SilentlyContinue
            }
        }
        $ckDir = if ($stagedTree) { $stagedTree } else { $root }
        $ckArgs = @(
            '-d', $ckDir, '--compact', '--quiet', '--framework', 'all',
            '--skip-path', '.serena', '--skip-path', '.git', '--skip-path', 'node_modules',
            '--skip-path', 'venv', '--skip-path', '.venv'
        )
        # Blocking only for real IaC domains; plain app YAML stays advisory
        $iacDomain = $false
        $iacProbe = if ($stagedNames.Count -gt 0) { $stagedNames } else {
            @(Get-ChildItem -Path $scanRoot -Recurse -Include *.tf,*.tfvars,*.yml,*.yaml -Depth 5 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex } |
                ForEach-Object { $_.FullName })
        }
        foreach ($ip in $iacProbe) {
            if ("$ip" -match '(?i)\.(tf|tfvars)$') { $iacDomain = $true; break }
            if ("$ip" -match '(?i)(cloudformation|cdk\.out|kubernetes|k8s|/helm/|chart\.yaml|values\.ya?ml|terraform)') {
                $iacDomain = $true; break
            }
        }
        if (-not $Quiet) {
            $ckMode = if ($iacDomain) { 'blocking' } else { 'advisory' }
            Write-Host "`n[checkov (IaC/cloud security) — $ckMode]" -ForegroundColor Cyan
        }
        $ck = Invoke-Checkov -CkArgs $ckArgs
        if (-not $ck.Ran) {
            if (-not $Quiet) { Write-Host "[checkov] SKIPPED (venv python/checkov missing)" -ForegroundColor DarkGray }
        } else {
            if (-not $Quiet -and $ck.Output) { @($ck.Output) | Select-Object -Last 30 | ForEach-Object { $_ } }
            if ($null -ne $ck.ExitCode -and $ck.ExitCode -ne 0) {
                if ($iacDomain) {
                    $script:failed++
                    if (-not $Quiet) { Write-Host "[checkov] exited $($ck.ExitCode)" -ForegroundColor Yellow }
                } else {
                    $script:advisory++
                    if (-not $Quiet) { Write-Host "[checkov] exited $($ck.ExitCode) (advisory — no IaC domain paths)" -ForegroundColor DarkYellow }
                }
            }
        }
    }

    # Docker / shell — staged tree or full
    $dockerFiles = @(Get-ChildItem -Path $scanRoot -Recurse -Include Dockerfile*,*.dockerfile -Depth 4 -ErrorAction SilentlyContinue)
    if ($dockerFiles.Count -gt 0 -and (Get-Command hadolint -ErrorAction SilentlyContinue)) {
        Run 'hadolint' @($dockerFiles.FullName) 'hadolint'
    }
    $shFiles = @(Get-ChildItem -Path $scanRoot -Recurse -Include *.sh,*.bash,*.zsh -Depth 3 -ErrorAction SilentlyContinue)
    if ($shFiles.Count -gt 0 -and (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
        Run 'shellcheck' @($shFiles.FullName) 'ShellCheck'
    }

    # Hints
    if (Get-Command rg -ErrorAction SilentlyContinue) {
        if (-not $Quiet) {
            Write-Host "`n[Hints] Possible incomplete / unwired code (TODO, FIXME, XXX, dead-ish patterns)" -ForegroundColor DarkGray
            $rgPath = if ($stagedTree) { $stagedTree } else { '.' }
            rg -i --heading 'TODO|FIXME|XXX|HACK|UNIMPLEMENTED|NOT WIRED|STUB' --glob '!node_modules/**' $rgPath | Select-Object -First 30
        }
    }
} finally {
    if ($stagedTree -and (Test-Path -LiteralPath $stagedTree)) {
        Remove-Item -LiteralPath $stagedTree -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Critical scanner presence — default FAIL if missing (set VIBE_REQUIRE_SCANNERS=0 to soft-warn only)
$haveTrivy = [bool](Get-Command trivy -ErrorAction SilentlyContinue)
$haveGitleaks = [bool](Get-Command gitleaks -ErrorAction SilentlyContinue)
$requireScanners = $env:VIBE_REQUIRE_SCANNERS -ne '0'
if (-not $haveTrivy -or -not $haveGitleaks) {
    $msg = "Critical scanners missing: $(if (-not $haveTrivy) { 'trivy ' })$(if (-not $haveGitleaks) { 'gitleaks' })".Trim()
    if (-not $Quiet) {
        $hint = if ($requireScanners) { 'Gate FAIL. Install via winget or re-run Install-GrokVibeStack. Soft-warn only: VIBE_REQUIRE_SCANNERS=0' } else { 'Gate soft-warn (VIBE_REQUIRE_SCANNERS=0). Coverage degraded.' }
        Write-Host "[WARN] $msg — $hint" -ForegroundColor Yellow
    }
    if ($requireScanners) {
        $script:failed++
    }
}

Write-Host ""
if ($advisory -gt 0 -and -not $Quiet) {
    Write-Host "Advisory scanner findings: $advisory (style/docs; non-blocking)." -ForegroundColor DarkYellow
}
if ($failed -gt 0) {
    Write-Host "Scans completed with $failed critical non-zero result(s) (check output above)." -ForegroundColor Yellow
    exit 1
}

# Only Full-tree passes write cache (Staged/Auto must not authorize push Full skip).
$th = Get-TreeHashForScanCache
if ($th) { Save-ScanPassCache -TreeHash $th -ScopeUsed $Scope -Cwd $root }
if (-not $Quiet) { Write-Host "Static scans passed (or only low/advisory findings)." -ForegroundColor Green }
# Explicit 0: advisory tools leave $LASTEXITCODE non-zero; callers check it after &.
exit 0
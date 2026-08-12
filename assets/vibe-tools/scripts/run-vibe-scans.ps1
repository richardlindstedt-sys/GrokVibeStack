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
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$failed = 0
$advisory = 0
$root = (Get-Location).Path
# Local / tool noise never treated as product findings
$script:ScanExcludeRegex = '(\\node_modules\\|\\\.git\\|\\\.serena\\|\\venv\\|\\\.venv\\|\\\.grok\\|\\__pycache__\\|\\\.tox\\|\\dist\\|\\build\\)'

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
      Materialize staged blob contents into a temp tree so trivy/gitleaks --no-git
      see the commit payload even when the repo has no commits yet (or only history).
      Returns temp root only when EVERY expected staged path was written.
      On any materialize miss: cleans temp, sets $script:StagedMaterializeFailed, returns $null.
    #>
    param([string[]]$Names)
    $script:StagedMaterializeFailed = $false
    if (-not $Names -or $Names.Count -eq 0) { return $null }
    $tmp = Join-Path $env:TEMP ("vibe-staged-" + [guid]::NewGuid().ToString('n').Substring(0, 10))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $n = 0
    $expected = 0
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $Names) {
        $rel = $rel -replace '/', [IO.Path]::DirectorySeparatorChar
        if ($rel -match '(?i)(^|[\\/])\.git([\\/]|$)' -or $rel -match '\.\.') {
            if (-not $Quiet) { Write-Host "  staged skip (unsafe path): $rel" -ForegroundColor DarkGray }
            continue
        }
        $dest = Join-Path $tmp $rel
        # Refuse path escape outside temp root
        $fullDest = [System.IO.Path]::GetFullPath($dest)
        $fullTmp = [System.IO.Path]::GetFullPath($tmp)
        if (-not $fullDest.StartsWith($fullTmp, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (-not $Quiet) { Write-Host "  staged skip (path escape): $rel" -ForegroundColor DarkGray }
            continue
        }
        $expected++
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path -LiteralPath $destDir)) {
            try {
                New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            } catch {
                if (-not $Quiet) { Write-Host "  staged mkdir failed: $rel ($_)" -ForegroundColor Yellow }
                [void]$missing.Add($rel)
                continue
            }
        }
        $gitPath = ($rel -replace '\\', '/')
        $src = Join-Path $root $rel
        # Always prefer index blob (pre-commit must scan staged payload, not dirty worktree).
        # Worktree copy only if index read fails (e.g. rare git show edge cases).
        $wrote = $false
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $blob = & git show ":0:$gitPath" 2>$null
        $showCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($showCode -eq 0 -and $null -ne $blob) {
            $text = if ($blob -is [array]) { $blob -join "`n" } else { [string]$blob }
            $utf8 = New-Object System.Text.UTF8Encoding $false
            try {
                [System.IO.File]::WriteAllText($dest, $text, $utf8)
                $n++
                $wrote = $true
            } catch {
                if (-not $Quiet) { Write-Host "  staged write failed: $rel ($_)" -ForegroundColor Yellow }
            }
        }
        if (-not $wrote -and (Test-Path -LiteralPath $src -PathType Leaf)) {
            try {
                Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
                $n++
                $wrote = $true
            } catch {
                if (-not $Quiet) { Write-Host "  staged copy failed: $rel ($_)" -ForegroundColor Yellow }
            }
        }
        if (-not $wrote) {
            [void]$missing.Add($rel)
            if (-not $Quiet) { Write-Host "  staged missing: $rel (index + worktree unavailable)" -ForegroundColor Yellow }
        }
    }
    if ($expected -eq 0) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return $null
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
    if (-not (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
        if (-not $Quiet) { Write-Host "[PSScriptAnalyzer] SKIPPED (module not imported)" -ForegroundColor DarkGray }
        return
    }
    if (-not $Quiet) { Write-Host "`n[PSScriptAnalyzer] scanning PowerShell files..." -ForegroundColor Cyan }
    $psFiles = Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1 -Depth 5 -ErrorAction SilentlyContinue |
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
    $results = Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error,Warning -ExcludeRule $exclude -ErrorAction SilentlyContinue |
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
Write-Host "Scanning: $($Paths -join ', ')"

# Prefer staged payload when present (pre-commit / empty-history safe)
$stagedNames = @(Get-StagedNameList)
$stagedTree = $null
$script:StagedMaterializeFailed = $false
if ($stagedNames.Count -gt 0) {
    $stagedTree = New-StagedScanTree -Names $stagedNames
    if ($script:StagedMaterializeFailed) {
        # Partial/missing staged materialize must fail gate — never scan a subset as "clean"
        $script:failed++
        if (-not $Quiet) {
            Write-Host "[Staged scan tree] gate fail (incomplete materialize); secret scanners will use worktree fallback only after fix" -ForegroundColor Yellow
        }
    } elseif ($stagedTree) {
        if (-not $Quiet) {
            Write-Host ("Staged payload: {0} path(s) -> temp tree for secret/vuln scan" -f $stagedNames.Count) -ForegroundColor DarkCyan
        }
    }
}

try {
    # Trivy - secrets/vuln/misconfig on staged tree when available, else caller $Paths / root
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

    # Gitleaks - --no-git on staged tree so empty history still scans file contents
    if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
        if ($stagedTree) {
            Run 'gitleaks' @('detect', '--source', $stagedTree, '--no-git', '--redact') 'Gitleaks (staged)'
        } else {
            # Worktree + git history when available
            Run 'gitleaks' @('detect', '--source', $root, '--redact') 'Gitleaks'
            # Also no-git pass so untracked dirty files are covered
            Run 'gitleaks' @('detect', '--source', $root, '--no-git', '--redact') 'Gitleaks (workdir)' -Advisory
        }
    } else {
        if (-not $Quiet) { Write-Host "[Gitleaks] SKIPPED (not installed)" -ForegroundColor DarkGray }
    }

    # Heuristic secret pass on staged tree (backup when rules miss / allowlisted examples)
    if ($stagedTree) {
        $rx = [regex]'(?i)(-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----|xai-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})'
        $hits = @()
        Get-ChildItem -Path $stagedTree -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $t = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
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
} finally {
    if ($stagedTree -and (Test-Path -LiteralPath $stagedTree)) {
        Remove-Item -LiteralPath $stagedTree -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# PSScriptAnalyzer (PowerShell)
Run-PSScriptAnalyzer

# Pester (only if test files exist)
Run-Pester

# jscpd - Windows jscpd often analyzes 0 files for bare "."; pass concrete dirs/files.
if (Get-Command jscpd -ErrorAction SilentlyContinue) {
    if (-not $Quiet) { Write-Host "`n[jscpd] duplicate detection" -ForegroundColor Cyan }
    $jscpdTargets = [System.Collections.Generic.List[string]]::new()
    $pathList = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $pathsIsDefault = ($pathList.Count -eq 0) -or (
        $pathList.Count -eq 1 -and ($pathList[0] -eq '.' -or $pathList[0] -eq $root)
    )
    if (-not $pathsIsDefault) {
        # Caller-selected roots/files first
        foreach ($p in $pathList) {
            $candidate = $p
            if (-not (Test-Path -LiteralPath $candidate)) {
                $joined = Join-Path $root $p
                if (Test-Path -LiteralPath $joined) { $candidate = $joined } else { continue }
            }
            [void]$jscpdTargets.Add($candidate)
        }
    }
    if ($jscpdTargets.Count -eq 0 -and $pathsIsDefault) {
        # Fallback discovery only when $Paths is '.' / empty (bare "." yields 0 files on Windows)
        foreach ($cand in @('assets', 'src', 'lib', 'scripts', 'app', 'packages', 'services')) {
            if (Test-Path -LiteralPath (Join-Path $root $cand)) { [void]$jscpdTargets.Add($cand) }
        }
        Get-ChildItem -Path $root -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '\.(ps1|psm1|js|ts|tsx|jsx|py|go|rs|java|cs|md)$' -and $_.Name -notmatch '^\.' } |
            Select-Object -First 40 |
            ForEach-Object { [void]$jscpdTargets.Add($_.Name) }
    }
    if ($jscpdTargets.Count -eq 0) {
        if (-not $Quiet) { Write-Host "[jscpd] SKIPPED (no source roots)" -ForegroundColor DarkGray }
    } else {
        # jscpd 5.x: long --min-lines with multi-path often yields 0 files on Windows; use short flags + path first
        $jscpdArgs = @($jscpdTargets.ToArray()) + @('-l', '6', '-k', '45')
        if (-not $Quiet) { Write-Host ("  targets: {0}" -f ($jscpdTargets -join ', ')) -ForegroundColor DarkGray }
        $jscpdOut = & jscpd @jscpdArgs 2>&1
        if (-not $Quiet) { $jscpdOut | Select-Object -Last 25 }
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
            $script:failed++
            if (-not $Quiet) { Write-Host "[jscpd] exited $LASTEXITCODE" -ForegroundColor Yellow }
        }
    }
}

# Biome (JS/TS/JSON etc.) — read-only check only (gates must not rewrite the tree)
if ( (Test-Path 'package.json') -or (Get-ChildItem -Recurse -Include *.js,*.ts,*.jsx,*.tsx -Depth 3 -ErrorAction SilentlyContinue) ) {
    Run 'biome' @('check') 'Biome'
}

# markdownlint (docs) — style-only; advisory so long READMEs don't block secrets/vuln gates
if (Get-Command markdownlint -ErrorAction SilentlyContinue) {
    $mdFiles = Get-ChildItem -Recurse -Include *.md -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex }
    if ($mdFiles) {
        $mdlArgs = @(
            '--ignore', 'node_modules',
            '--ignore', '.serena',
            '--ignore', '.git',
            '--ignore', 'venv',
            '.'
        )
        # Prefer repo config if present; else disable noisy length/table rules via CLI
        if (-not (Test-Path (Join-Path $root '.markdownlint.json')) -and -not (Test-Path (Join-Path $root '.markdownlint.yaml'))) {
            $mdlArgs = @('-d', 'MD013,MD033,MD041,MD060') + $mdlArgs
        }
        Run 'markdownlint' $mdlArgs 'markdownlint' -Advisory
    }
}

# Semgrep (excellent multi-language rules)
if (Get-Command semgrep -ErrorAction SilentlyContinue) {
    Run 'semgrep' @('scan', '--config=auto', '--severity=ERROR', '--error', '--quiet') 'Semgrep'
}

# Python specific
$pyFiles = Get-ChildItem -Recurse -Include *.py -Depth 4 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex } | Select-Object -First 1
if ($pyFiles) {
    Run 'ruff' @('check', '.') 'Ruff'
    if (Get-Command vulture -ErrorAction SilentlyContinue) {
        Run 'vulture' @('.', '--min-confidence', '80') 'Vulture (dead code)'
    }
    if (Get-Command mypy -ErrorAction SilentlyContinue) {
        Run 'mypy' @('.', '--ignore-missing-imports', '--no-error-summary') 'mypy (types)'
    }
    if (Get-Command bandit -ErrorAction SilentlyContinue) {
        Run 'bandit' @('-r', '.', '-ll', '-q') 'bandit (Python security)'
    }
}

# YAML / IaC — skip local tool metadata; style line-length is advisory
$yamlFiles = Get-ChildItem -Recurse -Include *.yml,*.yaml -Depth 5 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $script:ScanExcludeRegex } | Select-Object -First 1
if ($yamlFiles) {
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
            Run 'yamllint' @('-s', '-c', $ylCfg, '.') 'yamllint' -Advisory
        } finally {
            Remove-Item -LiteralPath $ylCfg -Force -ErrorAction SilentlyContinue
        }
    }
    $ckArgs = @(
        '-d', $root, '--compact', '--quiet', '--framework', 'all',
        '--skip-path', '.serena', '--skip-path', '.git', '--skip-path', 'node_modules',
        '--skip-path', 'venv', '--skip-path', '.venv'
    )
    if (-not $Quiet) { Write-Host "`n[checkov (IaC/cloud security)]" -ForegroundColor Cyan }
    $ck = Invoke-Checkov -CkArgs $ckArgs
    if (-not $ck.Ran) {
        if (-not $Quiet) { Write-Host "[checkov] SKIPPED (venv python/checkov missing)" -ForegroundColor DarkGray }
    } else {
        if (-not $Quiet -and $ck.Output) { @($ck.Output) | Select-Object -Last 30 | ForEach-Object { $_ } }
        if ($null -ne $ck.ExitCode -and $ck.ExitCode -ne 0) {
            $script:failed++
            if (-not $Quiet) { Write-Host "[checkov] exited $($ck.ExitCode)" -ForegroundColor Yellow }
        }
    }
}

# Dockerfiles (best effort)
if (Get-ChildItem -Recurse -Include Dockerfile*,*.dockerfile -Depth 4 -ErrorAction SilentlyContinue) {
    if (Get-Command hadolint -ErrorAction SilentlyContinue) {
        Run 'hadolint' @((Get-ChildItem -Recurse -Include Dockerfile*,*.dockerfile -Depth 4).FullName) 'hadolint'
    }
}

# Shell scripts
$shFiles = Get-ChildItem -Recurse -Include *.sh,*.bash,*.zsh -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($shFiles -and (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
    Run 'shellcheck' @((Get-ChildItem -Recurse -Include *.sh,*.bash,*.zsh -Depth 3).FullName) 'ShellCheck'
}

# Quick dead/unwired feature hints via ripgrep (always available from token stack or system)
if (Get-Command rg -ErrorAction SilentlyContinue) {
    if (-not $Quiet) {
        Write-Host "`n[Hints] Possible incomplete / unwired code (TODO, FIXME, XXX, dead-ish patterns)" -ForegroundColor DarkGray
        rg -i --heading 'TODO|FIXME|XXX|HACK|UNIMPLEMENTED|NOT WIRED|STUB' --glob '!node_modules/**' . | Select-Object -First 30
    }
}

# Critical scanner presence (soft warn; set VIBE_REQUIRE_SCANNERS=1 to fail gate)
$haveTrivy = [bool](Get-Command trivy -ErrorAction SilentlyContinue)
$haveGitleaks = [bool](Get-Command gitleaks -ErrorAction SilentlyContinue)
if (-not $haveTrivy -or -not $haveGitleaks) {
    $msg = "Critical scanners missing: $(if (-not $haveTrivy) { 'trivy ' })$(if (-not $haveGitleaks) { 'gitleaks' })".Trim()
    if (-not $Quiet) { Write-Host "[WARN] $msg — gate coverage degraded. Install via winget or re-run Install-GrokVibeStack." -ForegroundColor Yellow }
    if ($env:VIBE_REQUIRE_SCANNERS -eq '1') {
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
} else {
    if (-not $Quiet) { Write-Host "Static scans passed (or only low/advisory findings)." -ForegroundColor Green }
}
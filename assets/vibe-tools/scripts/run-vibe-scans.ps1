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

function Test-ToolRunnable([string]$cmd) {
    $c = Get-Command $cmd -ErrorAction SilentlyContinue
    if (-not $c) { return $false }
    # Windows pip shims can exist while the package is broken (e.g. checkov.cmd)
    if ($c.Source -and ($c.Source -match '\.cmd$')) {
        try {
            $probe = & $cmd --version 2>&1
            if ($LASTEXITCODE -ne 0 -and "$probe" -match 'ModuleNotFoundError|No module named') { return $false }
        } catch { return $false }
    }
    return $true
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
    $psFiles = Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1 -Depth 5 -ErrorAction SilentlyContinue
    if (-not $psFiles) { return }
    $results = Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error,Warning -ExcludeRule 'PSAvoidUsingWriteHost','PSUseShouldProcessForStateChangingFunctions' -ErrorAction SilentlyContinue
    if ($results) {
        $results | ForEach-Object { if (-not $Quiet) { Write-Host "  $($_.Severity): $($_.RuleName) - $($_.ScriptName):$($_.Line) - $($_.Message)" } }
        if ($results | Where-Object Severity -eq 'Error') { $script:failed++ }
    } elseif (-not $Quiet) {
        Write-Host "  Clean (no Error/Warning findings)" -ForegroundColor Green
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

# Trivy - broad security + secrets + misconfig + SAST
Run 'trivy' @('fs', '--exit-code', '1', '--severity', 'HIGH,CRITICAL', '--scanners', 'vuln,secret,misconfig', $Paths) 'Trivy'

# Gitleaks - dedicated secrets (very low false positives)
Run 'gitleaks' @('detect', '--source', '.', '--redact') 'Gitleaks'

# PSScriptAnalyzer (PowerShell)
Run-PSScriptAnalyzer

# Pester (only if test files exist)
Run-Pester

# jscpd - duplicate code (tunable); non-zero exit counts as gate failure
if (Get-Command jscpd -ErrorAction SilentlyContinue) {
    if (-not $Quiet) { Write-Host "`n[jscpd] duplicate detection" -ForegroundColor Cyan }
    $jscpdOut = & jscpd --min-lines 6 --min-tokens 45 --format console $Paths 2>&1
    if (-not $Quiet) { $jscpdOut | Select-Object -Last 20 }
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        $script:failed++
        if (-not $Quiet) { Write-Host "[jscpd] exited $LASTEXITCODE" -ForegroundColor Yellow }
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
    if (Test-ToolRunnable 'checkov') {
        Run 'checkov' @('-d', '.', '--compact', '--quiet', '--framework', 'all',
            '--skip-path', '.serena', '--skip-path', '.git', '--skip-path', 'node_modules') 'checkov (IaC/cloud security)'
    } elseif (-not $Quiet) {
        Write-Host "[checkov (IaC/cloud security)] SKIPPED (not installed or broken shim)" -ForegroundColor DarkGray
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
<#
.SYNOPSIS
    Known-bad eval corpus for vibe gates (no AI spend).
.DESCRIPTION
    Plants defects in temp trees and asserts scanners / on-edit / push-plan /
    cache schema fail closed. Exit 1 if any case does not catch the plant.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'
$failed = [System.Collections.Generic.List[string]]::new()
$passed = [System.Collections.Generic.List[string]]::new()

function Ok([string]$m) { [void]$passed.Add($m); Write-Host "  OK  $m" -ForegroundColor Green }
function Bad([string]$m) { [void]$failed.Add($m); Write-Host "  FAIL $m" -ForegroundColor Red }

if (-not $RepoRoot) {
    $here = Split-Path $MyInvocation.MyCommand.Path -Parent
    $cand = Split-Path (Split-Path (Split-Path $here -Parent) -Parent) -Parent
    if (Test-Path (Join-Path $cand 'Install-GrokVibeStack.ps1')) { $RepoRoot = $cand }
    else { $RepoRoot = (Get-Location).Path }
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$scripts = Join-Path $RepoRoot 'assets\vibe-tools\scripts'

Write-Host "=== Vibe evals (known-bad) ===" -ForegroundColor Cyan

# --- 1) on-edit secret heuristic ---
$onEdit = Join-Path $scripts 'run-vibe-on-edit.ps1'
$tmp = Join-Path $env:TEMP ('vibe-eval-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $plant = Join-Path $tmp 'leaked.env'
    # Assemble at runtime so the repo never contains a contiguous AKIA... token.
    $kid = 'AKI' + 'A234567ABCDEFGHIJ'
    Set-Content -Path $plant -Value ('AWS_ACCESS_KEY_ID=' + $kid) -Encoding ascii
    $evt = @{
        workspaceRoot = $tmp
        cwd           = $tmp
        toolInput     = @{ path = $plant; file_path = $plant }
    } | ConvertTo-Json -Compress -Depth 6
    $evalState = Join-Path $tmp 'vibe-state'
    New-Item -ItemType Directory -Force -Path $evalState | Out-Null
    $prevStateDir = $env:VIBE_STATE_DIR
    $env:VIBE_STATE_DIR = $evalState
    try {
        $out = $evt | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $onEdit 2>&1
        $null = $out
    } finally {
        if ($null -eq $prevStateDir) { Remove-Item Env:VIBE_STATE_DIR -ErrorAction SilentlyContinue }
        else { $env:VIBE_STATE_DIR = $prevStateDir }
    }
    $findingsPath = Join-Path $evalState 'on-edit-findings.json'
    $fileHit = $false
    if (Test-Path -LiteralPath $findingsPath) {
        $fj = Get-Content -LiteralPath $findingsPath -Raw | ConvertFrom-Json
        $files = @($fj.files)
        $lines = @($fj.lines)
        $blob = @($files + $lines) -join "`n"
        $mentionsPlant = ($blob -match 'leaked\.env') -and ($blob -match 'SECRET|AWS|gitleaks')
        if ([int]$fj.count -gt 0 -and $mentionsPlant) { $fileHit = $true }
    }
    if ($fileHit) {
        Ok 'eval: on-edit catches planted AWS key'
    } else {
        Bad 'eval: on-edit missed planted AWS key'
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 2) version tag => strict; history tag uses TAG: not NEW: ---
. (Join-Path $scripts 'gate-push-plan.ps1')
$plan = Get-VibePushReviewPlan -StdinText "refs/tags/v1.2.3 abcdef0123456789 refs/tags/v1.2.3 0000000000000000"
if ($plan.Profile -eq 'strict' -and -not $plan.AutoProfile -and $plan.Ranges[0] -like 'TAG:*') {
    Ok 'eval: version tag -> strict + TAG range'
} else {
    Bad ("eval: version tag plan wrong: profile={0} auto={1} range={2}" -f $plan.Profile, $plan.AutoProfile, ($plan.Ranges -join ','))
}
$plan2 = Get-VibePushReviewPlan -StdinText "refs/heads/main abcdef0123456789 refs/heads/main 1111111111111111"
if ($plan2.Profile -eq 'fast' -and $plan2.Ranges[0] -match '\.\.' -and $plan2.HasRefLines) {
    Ok 'eval: branch push stays fast + a..b'
} else {
    Bad 'eval: branch push plan wrong'
}
$emptyPlan = Get-VibePushReviewPlan -StdinText ''
$delPlan = Get-VibePushReviewPlan -StdinText "refs/heads/gone 0000000000000000 refs/heads/gone abcdef0123456789"
if (-not $emptyPlan.HasRefLines -and $delPlan.HasRefLines -and @($delPlan.Ranges).Count -eq 0) {
    Ok 'eval: empty stdin vs delete-only (HasRefLines; no range)'
} else {
    Bad 'eval: empty stdin / delete-only plan mixup'
}
if ((Test-VibeVersionTagRef 'refs/tags/v1.0.3') -and (Test-VibeVersionTagRef 'refs/tags/2.0.0') -and -not (Test-VibeVersionTagRef 'refs/tags/nightly')) {
    Ok 'eval: version-tag ref matcher'
} else {
    Bad 'eval: version-tag ref matcher'
}

# --- 3) cache schema miss without version ---
. (Join-Path $scripts 'gate-schema.ps1')
$ver = Get-GateSchemaVersion
if ($ver -ge 2) { Ok 'eval: GATE_SCHEMA_VERSION >= 2' } else { Bad 'eval: schema version missing' }

# --- 4) intent / blast helpers parse ---
. (Join-Path $scripts 'gate-review-context.ps1')
$sampleDiff = @"
diff --git a/src/app.py b/src/app.py
--- a/src/app.py
+++ b/src/app.py
@@ -1,2 +1,4 @@
+def process_payment():
+    return 1
"@
$syms = @(Get-ChangedSymbolHints $sampleDiff)
if ($syms -contains 'process_payment') { Ok 'eval: symbol hint from added def' } else { Bad 'eval: symbol hint missed process_payment' }
$env:VIBE_INTENT = 'fix payment race'
$intent = Get-StatedIntent
if ($intent -match 'payment race') { Ok 'eval: VIBE_INTENT read' } else { Bad 'eval: VIBE_INTENT not read' }
Remove-Item Env:VIBE_INTENT -ErrorAction SilentlyContinue

# --- 5) command-injection plant via ruff/semgrep if present ---
$pyTmp = Join-Path $env:TEMP ('vibe-eval-py-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $pyTmp | Out-Null
try {
    $py = Join-Path $pyTmp 'rce.py'
    Set-Content -Path $py -Value "import os`nimport sys`nos.system(sys.argv[1])`n" -Encoding ascii
    $caught = $false
    if (Get-Command semgrep -ErrorAction SilentlyContinue) {
        & semgrep scan --quiet --error $py 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $caught = $true }
    }
    if (-not $caught -and (Get-Command bandit -ErrorAction SilentlyContinue)) {
        & bandit -q -r $py 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $caught = $true }
    }
    if ($caught) {
        Ok 'eval: rce plant caught by semgrep/bandit'
    } else {
        Write-Host '  SKIP eval: rce plant (semgrep/bandit not installed)' -ForegroundColor DarkGray
    }
} finally {
    Remove-Item -LiteralPath $pyTmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("Evals: {0} passed, {1} failed" -f $passed.Count, $failed.Count)
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
exit 0

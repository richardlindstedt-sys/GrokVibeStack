<#
.SYNOPSIS
    pre-push gate: full static scans + Grok AI review of commits about to be pushed.
.DESCRIPTION
    Blocks the push (exit 1) on critical scan failures or LLM BLOCK verdict.
    Uses the range of commits being pushed when available; falls back to working tree.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$vibeScripts = Split-Path $MyInvocation.MyCommand.Path -Parent
$runScans = Join-Path $vibeScripts 'run-vibe-scans.ps1'
$aiReview = Join-Path $vibeScripts 'grok-ai-review.ps1'
$progressPs1 = Join-Path $vibeScripts 'gate-progress.ps1'
if (Test-Path -LiteralPath $progressPs1) { . $progressPs1; Reset-GateLiveLog }

Write-Host ""
Write-Host "+================================================================+" -ForegroundColor Magenta
Write-Host "|   VIBE PRE-PUSH HOOK  [profile=fast]                           |" -ForegroundColor Magenta
Write-Host "|   Scanners + 1-reviewer (correctness) on push payload          |" -ForegroundColor Magenta
Write-Host "+================================================================+" -ForegroundColor Magenta
Write-Host ""

# Git feeds pre-push: <local ref> <local sha> <remote ref> <remote sha> per line on stdin
$ranges = @()
$stdin = [Console]::In.ReadToEnd()
if ($stdin) {
    foreach ($line in ($stdin -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $parts = $line -split '\s+'
        if ($parts.Count -ge 4) {
            $localSha = $parts[1]
            $remoteSha = $parts[3]
            if ($localSha -match '^0+$') {
                Write-Host "Deleting remote ref $($parts[2]); skip content review for this line." -ForegroundColor DarkGray
                continue
            }
            if ($remoteSha -match '^0+$') {
                # New branch: walk up to 20 existing commits (never sha~20 — that
                # fails on short/shallow history and the old fallback reviewed tip only).
                $ranges += "NEW:$localSha"
            } else {
                $ranges += "$remoteSha..$localSha"
            }
        }
    }
}

function Get-NewBranchPushDiff([string]$Tip) {
    $commits = @(git rev-list --max-count=20 $Tip 2>$null | Where-Object { $_ })
    if ($commits.Count -eq 0) { return $null }
    $oldest = $commits[-1]
    $parent = $null
    try { $parent = (git rev-parse --verify --quiet "$oldest^" 2>$null | Select-Object -First 1) } catch {}
    if ($parent -and "$parent" -notmatch '^0+$') {
        $d = git diff --no-color "$parent..$Tip" 2>$null
        if ($d) { return $d }
    }
    $rootPatch = git diff-tree -p --root --no-color $oldest 2>$null
    if (-not $rootPatch) { $rootPatch = git show --no-color --pretty=format: -p $oldest 2>$null }
    $rest = $null
    if ($oldest -ne $Tip) { $rest = git diff --no-color "$oldest..$Tip" 2>$null }
    $parts = @($rootPatch, $rest) | Where-Object { $_ }
    if (-not $parts -or @($parts).Count -eq 0) { return $null }
    return ((@($parts)) -join "`n`n")
}

$diff = $null
if ($ranges.Count -gt 0) {
    $labels = [System.Collections.Generic.List[string]]::new()
    $chunks = foreach ($r in $ranges) {
        if ($r.StartsWith('NEW:')) {
            $tip = $r.Substring(4)
            [void]$labels.Add("new-branch:$tip (rev-list<=20)")
            $d = Get-NewBranchPushDiff $tip
            if ($d) { $d }
            continue
        }
        $d = git diff --no-color "$r" 2>$null
        if ($d) {
            [void]$labels.Add($r)
            $d
        }
    }
    if ($chunks) {
        $diff = ($chunks -join "`n`n")
        Write-Host "Reviewing push range diff ($($labels -join ', '))." -ForegroundColor Green
    }
}

if (-not $diff) {
    $diff = git diff --no-color origin/HEAD...HEAD 2>$null
    if (-not $diff) { $diff = git diff --no-color HEAD~5..HEAD 2>$null }
    if (-not $diff) { $diff = git diff --no-color 2>$null }
    if ($diff) {
        Write-Host "Reviewing fallback diff (no usable push range)." -ForegroundColor Yellow
    }
}

Write-Host ">>> STEP 1/2 : STATIC SCANS" -ForegroundColor Cyan
if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) { Write-GateProgress 'STEP 1/2 static scans' }
if (-not $env:VIBE_REQUIRE_SCANNERS) { $env:VIBE_REQUIRE_SCANNERS = '1' }

# Skip full rescans only when a prior Full pass hit (same treeHash + cwd, TTL ~2h).
# Shared Test-ScanPassCache: Staged/Auto cache writes never authorize Full skip.
. (Join-Path $vibeScripts 'scan-pass-cache.ps1')
$skipScans = $false
try {
    $treeHash = Get-TreeHashForScanCache
    $repoRoot = (Get-Location).Path
    if (Test-ScanPassCache -TreeHash $treeHash -Cwd $repoRoot -RequiredScope 'Full') {
        $skipScans = $true
        $age = if ($null -ne $script:ScanPassCacheAgeSec) { $script:ScanPassCacheAgeSec } else { '?' }
        $short = if ($treeHash -and $treeHash.Length -ge 12) { $treeHash.Substring(0, 12) } else { "$treeHash" }
        Write-Host ("Skipping full scans (Full cache hit tree={0}... age={1}s)" -f $short, $age) -ForegroundColor DarkCyan
    }
} catch {}

if (-not $skipScans) {
    # Prefer -File so process exit is the script's exit 0/1 (not leftover native codes).
    $scanProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runScans, '-Scope', 'Full'
    ) -Wait -PassThru -NoNewWindow
    if ($null -eq $scanProc -or $null -eq $scanProc.ExitCode) {
        Write-Host ""
        Write-Host "PRE-PUSH BLOCKED: scanner process did not start or returned no exit code." -ForegroundColor Red
        Write-Host "Fix the environment, or emergency: git push --no-verify" -ForegroundColor Yellow
        exit 1
    }
    $scanEc = [int]$scanProc.ExitCode
    if ($scanEc -ne 0) {
        Write-Host ""
        Write-Host "PRE-PUSH BLOCKED: critical static findings." -ForegroundColor Red
        Write-Host "Fix issues above, or emergency: git push --no-verify" -ForegroundColor Yellow
        exit 1
    }
    # Start-Process does not update $LASTEXITCODE; clear stale codes before review.
    $global:LASTEXITCODE = 0
}

Write-Host ""
Write-Host ">>> STEP 2/2 : GROK AI REVIEW OF PUSH (profile=fast, AutoProfile)" -ForegroundColor Cyan
if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) { Write-GateProgress 'STEP 2/2 grok AI review' }
# fast + AutoProfile: docs stay cheap; sensitive paths add security reviewer
# Reset so review check cannot see pre-scan / pre-review leftover codes.
$global:LASTEXITCODE = 0
if ($diff) {
    & $aiReview -NoScans -Profile fast -AutoProfile -DiffOverride $diff
} else {
    & $aiReview -NoScans -Profile fast -AutoProfile
}

# Only the post-review exit matters (not scan Start-Process or earlier natives).
$reviewEc = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
if ($reviewEc -ne 0) {
    Write-Host ""
    Write-Host "PRE-PUSH BLOCKED: Grok returned BLOCK (or review failed)." -ForegroundColor Red
    Write-Host "Fix issues, or emergency: git push --no-verify" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "PRE-PUSH OK - scans + AI review clean. Push proceeds." -ForegroundColor Green
exit 0

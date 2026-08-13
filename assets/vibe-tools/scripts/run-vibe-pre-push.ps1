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
            $zero = '0' * 40
            if ($localSha -eq $zero) {
                Write-Host "Deleting remote ref $($parts[2]); skip content review for this line." -ForegroundColor DarkGray
                continue
            }
            if ($remoteSha -eq $zero) {
                # new branch: review last ~20 commits or all unique
                $ranges += "$localSha~20..$localSha"
            } else {
                $ranges += "$remoteSha..$localSha"
            }
        }
    }
}

$diff = $null
if ($ranges.Count -gt 0) {
    $chunks = foreach ($r in $ranges) {
        # tolerate shallow history / missing ~20
        $d = git diff --no-color "$r" 2>$null
        if (-not $d) {
            $tip = ($r -split '\.\.')[-1]
            $d = git show --no-color --format= --pretty=format: $tip 2>$null
            if (-not $d) { $d = git log -1 -p --no-color $tip 2>$null }
        }
        if ($d) { $d }
    }
    if ($chunks) {
        $diff = ($chunks -join "`n`n")
        Write-Host "Reviewing push range diff ($($ranges -join ', '))." -ForegroundColor Green
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
    & $runScans -Quiet:$false -Scope Full
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "PRE-PUSH BLOCKED: critical static findings." -ForegroundColor Red
        Write-Host "Fix issues above, or emergency: git push --no-verify" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ""
Write-Host ">>> STEP 2/2 : GROK AI REVIEW OF PUSH (profile=fast, AutoProfile)" -ForegroundColor Cyan
# fast + AutoProfile: docs stay cheap; sensitive paths add security reviewer
if ($diff) {
    & $aiReview -NoScans -Profile fast -AutoProfile -DiffOverride $diff
} else {
    & $aiReview -NoScans -Profile fast -AutoProfile
}

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "PRE-PUSH BLOCKED: Grok returned BLOCK (or review failed)." -ForegroundColor Red
    Write-Host "Fix issues, or emergency: git push --no-verify" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "PRE-PUSH OK - scans + AI review clean. Push proceeds." -ForegroundColor Green
exit 0

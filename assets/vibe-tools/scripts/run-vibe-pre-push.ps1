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
$pushPlanPs1 = Join-Path $vibeScripts 'gate-push-plan.ps1'
if (Test-Path -LiteralPath $progressPs1) { . $progressPs1; Reset-GateLiveLog }
if (-not (Test-Path -LiteralPath $pushPlanPs1)) {
    Write-Host "PRE-PUSH BLOCKED: missing gate-push-plan.ps1" -ForegroundColor Red
    if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
        Write-GateDone -Summary 'missing gate-push-plan.ps1'
    }
    exit 1
}
. $pushPlanPs1

# Git feeds pre-push: <local ref> <local sha> <remote ref> <remote sha> per line on stdin
$stdin = [Console]::In.ReadToEnd()
$plan = Get-VibePushReviewPlan -StdinText $stdin
$gateProfile = $plan.Profile
if (-not $gateProfile) { $gateProfile = 'fast' }
$useAuto = [bool]$plan.AutoProfile

Write-Host ""
Write-Host "+================================================================+" -ForegroundColor Magenta
Write-Host ("|   VIBE PRE-PUSH HOOK  [profile={0,-6}]                        |" -f $gateProfile) -ForegroundColor Magenta
Write-Host "|   Scanners + AI review on push payload                         |" -ForegroundColor Magenta
Write-Host "+================================================================+" -ForegroundColor Magenta
Write-Host ""
if ($plan.Notes -and $plan.Notes.Count -gt 0) {
    Write-Host ("Push plan: {0}" -f ($plan.Notes -join '; ')) -ForegroundColor DarkCyan
}

$ranges = @($plan.Ranges)

function ConvertTo-SinglePatchText($raw) {
    # git.exe on Windows PowerShell 5.1 returns string[] for multi-line patches.
    # Nesting those in @($a, $b) -join emits "System.String[]", not the patch.
    if ($null -eq $raw) { return $null }
    $s = if ($raw -is [string]) { $raw } else { (@($raw) | ForEach-Object { "$_" }) -join "`n" }
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

function Get-NewBranchPushDiff([string]$Tip) {
    $commits = @(git rev-list --max-count=20 $Tip 2>$null | Where-Object { $_ })
    if ($commits.Count -eq 0) { return $null }
    $oldest = $commits[-1]
    $parent = $null
    try { $parent = (git rev-parse --verify --quiet "$oldest^" 2>$null | Select-Object -First 1) } catch {}
    if ($parent -and "$parent" -notmatch '^0+$') {
        $d = ConvertTo-SinglePatchText (git diff --no-color "$parent..$Tip" 2>$null)
        if ($d) { return $d }
    }
    $rootPatch = ConvertTo-SinglePatchText (git diff-tree -p --root --no-color $oldest 2>$null)
    if (-not $rootPatch) { $rootPatch = ConvertTo-SinglePatchText (git show --no-color --pretty=format: -p $oldest 2>$null) }
    $rest = $null
    if ($oldest -ne $Tip) { $rest = ConvertTo-SinglePatchText (git diff --no-color "$oldest..$Tip" 2>$null) }
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
        if ($r.StartsWith('TAG:')) {
            $tip = $r.Substring(4)
            [void]$labels.Add("tag-commit:$tip")
            $d = Get-TagCommitDiff -Sha $tip
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
        if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
            Write-GateDone -Summary 'scanner process did not start'
        }
        exit 1
    }
    $scanEc = [int]$scanProc.ExitCode
    if ($scanEc -ne 0) {
        Write-Host ""
        Write-Host "PRE-PUSH BLOCKED: critical static findings." -ForegroundColor Red
        Write-Host "Fix issues above, or emergency: git push --no-verify" -ForegroundColor Yellow
        if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
            if ("$script:GateNow" -notmatch 'GATE DONE') {
                Write-GateDone -Summary ("scans exit {0}" -f $scanEc)
            }
        }
        exit 1
    }
    # Start-Process does not update $LASTEXITCODE; clear stale codes before review.
    $global:LASTEXITCODE = 0
}

Write-Host ""
Write-Host (">>> STEP 2/2 : GROK AI REVIEW OF PUSH (profile={0}, AutoProfile={1})" -f $gateProfile, $useAuto) -ForegroundColor Cyan
if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) { Write-GateProgress 'STEP 2/2 grok AI review' }
# Reset so review check cannot see pre-scan / pre-review leftover codes.
$global:LASTEXITCODE = 0
$diffText = ConvertTo-SinglePatchText $diff
try {
    # Named params only. Never splat a patch: PS 5.1 git diffs are string[] and
    # each "-..." hunk line would bind as a new parameter (e.g. ProxyPort).
    if ($diffText) {
        & $aiReview -NoScans -Profile $gateProfile -AutoProfile:$useAuto -DiffOverride $diffText
    } else {
        & $aiReview -NoScans -Profile $gateProfile -AutoProfile:$useAuto
    }
} catch {
    Write-Host ""
    Write-Host ("PRE-PUSH BLOCKED: AI review failed to start: {0}" -f $_) -ForegroundColor Red
    if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
        if ("$script:GateNow" -notmatch 'GATE DONE') {
            Write-GateDone -Summary ("review failed to start: {0}" -f $_)
        }
    }
    exit 1
}

# Only the post-review exit matters (not scan Start-Process or earlier natives).
$reviewEc = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
if ($reviewEc -ne 0) {
    Write-Host ""
    Write-Host "PRE-PUSH BLOCKED: Grok returned BLOCK (or review failed)." -ForegroundColor Red
    Write-Host "Fix issues, or emergency: git push --no-verify" -ForegroundColor Yellow
    if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
        if ("$script:GateNow" -notmatch 'GATE DONE') {
            Write-GateDone -Summary ("review exit {0}" -f $reviewEc)
        }
    }
    exit 1
}

Write-Host ""
Write-Host "PRE-PUSH OK - scans + AI review clean. Push proceeds." -ForegroundColor Green
exit 0

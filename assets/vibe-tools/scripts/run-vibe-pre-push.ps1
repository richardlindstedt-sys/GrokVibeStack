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
    # Unique commits vs remotes — never cap at 20 (first push of a long branch).
    # No guessed origin/HEAD / origin/main / origin/master / checkout HEAD base.
    $Tip = "$Tip".Trim()
    if ([string]::IsNullOrWhiteSpace($Tip)) { return $null }
    if ($Tip -notmatch '^[0-9a-fA-F]{7,64}$') { return $null }
    $unique = @(
        git rev-list --not --remotes --end-of-options $Tip 2>$null |
            ForEach-Object { "$_".Trim() } |
            Where-Object { $_ -match '^[0-9a-fA-F]{7,64}$' }
    )
    if ($unique.Count -eq 0) {
        $unique = @(
            git rev-list $Tip --not --remotes 2>$null |
                ForEach-Object { "$_".Trim() } |
                Where-Object { $_ -match '^[0-9a-fA-F]{7,64}$' }
        )
    }
    if ($unique.Count -eq 0) { return $null }
    $oldest = $unique[-1]
    $parent = $null
    try { $parent = (git rev-parse --verify --quiet "$oldest^" 2>$null | Select-Object -First 1) } catch {}
    $parent = "$parent".Trim()
    if ($parent -and $parent -match '^[0-9a-f]{40}([0-9a-f]{24})?$' -and $parent -notmatch '^0+$') {
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
            $tip = $r.Substring(4).Trim()
            [void]$labels.Add("new-branch:$tip (unique-vs-remotes)")
            $d = Get-NewBranchPushDiff $tip
            if ($d) { $d }
            continue
        }
        if ($r.StartsWith('TAG:')) {
            $tip = $r.Substring(4).Trim()
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

$hasRefLines = [bool]$plan.HasRefLines
# Empty stdin only. Zero $ranges is normal for delete-only / some create-ref notes.
if (-not $hasRefLines) {
    Write-Host ""
    Write-Host "PRE-PUSH BLOCKED: no push refs on stdin (refusing a guessed origin/HEAD or HEAD~5 diff)." -ForegroundColor Red
    if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
        Write-GateDone -Summary 'no push refs on stdin'
    }
    exit 1
}
if (-not $diff) {
    Write-Host "Push refs present; range diff empty (nothing to review)." -ForegroundColor DarkGray
}

Write-Host ">>> STEP 1/2 : STATIC SCANS" -ForegroundColor Cyan
if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) { Write-GateProgress 'STEP 1/2 static scans' }
if (-not $env:VIBE_REQUIRE_SCANNERS) { $env:VIBE_REQUIRE_SCANNERS = '1' }

# Scan/cache the push tip tree(s), not the current checkout (write-tree / HEAD).
. (Join-Path $vibeScripts 'scan-pass-cache.ps1')
$repoRoot = (Get-Location).Path
$pushTips = @(Get-VibePushTipShas $ranges)
$tipJobs = [System.Collections.Generic.List[string]]::new()
$seenTrees = @{}
foreach ($tip in $pushTips) {
    $th = Get-TreeHashForScanCache -TreeIsh $tip
    if (-not $th) {
        Write-Host ""
        Write-Host ("PRE-PUSH BLOCKED: cannot resolve tree for push tip {0}." -f $tip) -ForegroundColor Red
        if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
            Write-GateDone -Summary ("unresolved push tip {0}" -f $tip)
        }
        exit 1
    }
    if ($seenTrees.ContainsKey($th)) { continue }
    $seenTrees[$th] = $true
    [void]$tipJobs.Add($tip)
}
$skipScans = $false
try {
    if ($tipJobs.Count -gt 0) {
        $allHit = $true
        $ages = [System.Collections.Generic.List[string]]::new()
        foreach ($tip in $tipJobs) {
            $treeHash = Get-TreeHashForScanCache -TreeIsh $tip
            if (-not (Test-ScanPassCache -TreeHash $treeHash -Cwd $repoRoot -RequiredScope 'Full')) {
                $allHit = $false
                break
            }
            $age = if ($null -ne $script:ScanPassCacheAgeSec) { $script:ScanPassCacheAgeSec } else { '?' }
            $short = if ($treeHash -and $treeHash.Length -ge 12) { $treeHash.Substring(0, 12) } else { "$treeHash" }
            [void]$ages.Add("{0}... age={1}s" -f $short, $age)
        }
        if ($allHit) {
            $skipScans = $true
            Write-Host ("Skipping full scans (Full cache hit tip tree {0})" -f ($ages -join '; ')) -ForegroundColor DarkCyan
        }
    }
} catch {}

if (-not $skipScans) {
    $scanTargets = if ($tipJobs.Count -gt 0) { @($tipJobs) } else { @('') }
    foreach ($tip in $scanTargets) {
        $scanArgs = [System.Collections.Generic.List[string]]::new()
        [void]$scanArgs.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runScans, '-Scope', 'Full'))
        if ($tip) {
            [void]$scanArgs.Add('-TreeIsh')
            [void]$scanArgs.Add($tip)
            Write-Host ("Scanning push tip {0}" -f $tip) -ForegroundColor DarkCyan
        }
        $prevChild = $env:VIBE_GATE_CHILD
        $env:VIBE_GATE_CHILD = '1'
        $scanProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @($scanArgs.ToArray()) -Wait -PassThru -NoNewWindow
        if ($null -eq $prevChild) { Remove-Item Env:VIBE_GATE_CHILD -ErrorAction SilentlyContinue } else { $env:VIBE_GATE_CHILD = $prevChild }
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
    }
    $global:LASTEXITCODE = 0
}

if (-not $diff) {
    Write-Host ""
    Write-Host "PRE-PUSH OK - scans clean; no payload to review." -ForegroundColor Green
    if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
        Write-GateDone -Passed -Summary 'no payload to review'
    }
    exit 0
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

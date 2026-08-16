#Requires -Version 5.1
<#
.SYNOPSIS
    UserPromptSubmit: inject on-edit findings + live gate snapshot as additionalContext.
.DESCRIPTION
    PostToolUse stdout is ignored by Grok. This hook is the only reliable
    chat-side inject. Fail-open. Does not block.

    Always injects GATE DONE + VOTES (not only live waiting). Also injects
    gate-last-done.txt when that RUN differs from the live file so commit
    votes survive the moment push overwrites gate-now.txt.
#>
$ErrorActionPreference = 'SilentlyContinue'

$chunks = [System.Collections.Generic.List[string]]::new()

function Get-GateFileRun([string[]]$Lines) {
    $run = ($Lines | Where-Object { $_ -match '^RUN:\s+\S+' } | Select-Object -First 1)
    if ($run -and $run -match '^RUN:\s+(\S+)') { return $Matches[1] }
    return ''
}

function Add-GateSnapshotChunk {
    param(
        [string]$Path,
        [string]$Banner
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $head = @(Get-Content -LiteralPath $Path)
    if ($head.Count -eq 0) { return }
    $run = ($head | Where-Object { $_ -match '^RUN:\s+\S+' } | Select-Object -First 1)
    $now = ($head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
    $elapsed = ($head | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
    if (-not $run -or -not $now) { return }
    $votes = @($head | Where-Object {
            $_ -and (
                $_ -match '^VOTE:' -or
                $_ -match '(?i)^\[[\d:]+\]\s*(correctness|security|simplicity):'
            )
        })
    $evts = @($head | Where-Object {
            $_ -and
            $_ -notmatch '^(RUN|NOW|ELAPSED|PHASE|PID|CWD|LOG|EVENTS|VOTE):' -and
            $_ -notmatch 'waiting vibe-' -and
            $_ -notmatch '(?i)(correctness|security|simplicity):' -and
            $_ -match 'scan:|scans passed|scans start|profile=|Round |reviewers running|start reviewer|done reviewer|arbiter|fixer|BLOCKER|GATE DONE'
        } | Select-Object -Last 24)
    $evtBlock = ''
    if ($votes.Count -gt 0) {
        $evtBlock += "`n`nVOTES (verdict + reason; speak these as they land):`n" + ($votes -join "`n")
    }
    if ($evts.Count -gt 0) {
        $evtBlock += "`n`nGATE EVENTS (paste this whole block in chat):`n" + ($evts -join "`n")
    }
    [void]$chunks.Add(@"
$Banner
$run
$now
$elapsed$evtBlock
"@)
}

$nowFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt'
$lastDoneFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-last-done.txt'
$liveLines = @()
if (Test-Path -LiteralPath $nowFile) {
    $liveLines = @(Get-Content -LiteralPath $nowFile)
}
$liveRun = Get-GateFileRun $liveLines
$lastLines = @()
if (Test-Path -LiteralPath $lastDoneFile) {
    $lastLines = @(Get-Content -LiteralPath $lastDoneFile)
}
$lastRun = Get-GateFileRun $lastLines

# Prior RUN recap first so a new push/commit cannot hide commit votes.
if ($lastRun -and $lastRun -ne $liveRun) {
    Add-GateSnapshotChunk -Path $lastDoneFile -Banner @'
LAST GATE (speak this recap in chat BEFORE any next git commit/push; do not skip votes/arbiter/GATE DONE):
'@
}

if ($liveRun) {
    $liveBanner = if ($liveLines -match 'GATE DONE') {
        @'
GATE DONE (must post RUN + every VOTE + arbiter + this DONE line in chat before starting the next git command):
'@
    } else {
        @'
GATE LIVE (do not stay silent — report NOW plus scan/reviewer/arbiter events, then poll again in ~15s):
'@
    }
    Add-GateSnapshotChunk -Path $nowFile -Banner $liveBanner
}

$findingsFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\state\on-edit-findings.json'
if (Test-Path -LiteralPath $findingsFile) {
    try {
        $doc = Get-Content -LiteralPath $findingsFile -Raw | ConvertFrom-Json
        $when = $null
        try { $when = [datetime]::Parse([string]$doc.at) } catch {}
        $fresh = (-not $when) -or (((Get-Date) - $when).TotalHours -le 2)
        if ($fresh -and $doc -and [int]$doc.count -gt 0) {
            $lines = @($doc.lines)
            if ($lines.Count -gt 0) {
                $body = ($lines | Select-Object -First 40) -join "`n"
                if ($body.Length -gt 4000) { $body = $body.Substring(0, 4000) + "`n..." }
                [void]$chunks.Add("ON-EDIT FINDINGS (advisory, edit was not blocked). Fix before commit:`n$body")
            }
        } elseif ($when -and ((Get-Date) - $when).TotalHours -gt 2) {
            Remove-Item -LiteralPath $findingsFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

if ($chunks.Count -eq 0) { exit 0 }

$msg = $chunks -join "`n`n"
$payload = @{
    hookSpecificOutput = @{
        hookEventName     = 'UserPromptSubmit'
        additionalContext = $msg
    }
} | ConvertTo-Json -Compress -Depth 6

[Console]::Out.WriteLine($payload)
exit 0

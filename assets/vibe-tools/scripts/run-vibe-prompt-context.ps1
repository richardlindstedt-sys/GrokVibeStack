#Requires -Version 5.1
<#
.SYNOPSIS
    UserPromptSubmit: inject on-edit findings + live gate snapshot as additionalContext.
.DESCRIPTION
    PostToolUse stdout is ignored by Grok. This hook is the only reliable
    chat-side inject. Fail-open. Does not block.
#>
$ErrorActionPreference = 'SilentlyContinue'

$chunks = [System.Collections.Generic.List[string]]::new()

$nowFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt'
if (Test-Path -LiteralPath $nowFile) {
    $head = @(Get-Content -LiteralPath $nowFile -TotalCount 8)
    $rest = @(Get-Content -LiteralPath $nowFile | Select-Object -Skip 8)
    $head = @($head + $rest)
    $run = ($head | Where-Object { $_ -match '^RUN:\s+\S+' } | Select-Object -First 1)
    $now = ($head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
    $elapsed = ($head | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
    if ($run -and $now -and $now -notmatch 'GATE DONE') {
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
                $_ -match 'scan:|scans passed|scans start|profile=|Round |reviewers running|start reviewer|done reviewer|arbiter|fixer|BLOCKER'
            } | Select-Object -Last 24)
        $evtBlock = ''
        if ($votes.Count -gt 0) {
            $evtBlock += "`n`nVOTES (verdict + reason; speak these as they land):`n" + ($votes -join "`n")
        }
        if ($evts.Count -gt 0) {
            $evtBlock += "`n`nGATE EVENTS (paste this whole block in chat):`n" + ($evts -join "`n")
        }
        [void]$chunks.Add(@"
GATE LIVE (do not stay silent — report NOW plus scan/reviewer/arbiter events, then poll again in ~15s):
$run
$now
$elapsed$evtBlock
"@)
    }
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

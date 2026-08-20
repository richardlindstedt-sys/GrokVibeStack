#Requires -Version 5.1
<#
.SYNOPSIS
  Stop hook: keep the turn alive while a gate is live, and nag after edits.
.DESCRIPTION
  If gate-now.txt is not GATE DONE and this is a real end_turn, keep the turn
  alive for speakable events (vote/arbiter/fixer/DONE). Waiting ticks must not
  nag — that produced 'no new votes' spam.
  Then the existing edit-session reminder. Fail-open.
#>
$ErrorActionPreference = 'SilentlyContinue'

function Write-Json([hashtable]$Obj) {
    Write-Output (($Obj | ConvertTo-Json -Compress -Depth 6))
}

function Invoke-EditRemind {
    if ($env:VIBE_STOP_REMIND -eq '1' -or $env:VIBE_STOP_REMIND -eq 'always') {
        [Console]::Error.WriteLine('[vibe] Turn end - edits this session: confirm scans/review (vibe-review) before calling done.')
        return
    }
    $stateDir = if (Get-Command Get-VibeStateDir -ErrorAction SilentlyContinue) { Get-VibeStateDir } else { Join-Path $env:USERPROFILE '.grok\vibe-tools\state' }
    $flag = Join-Path $stateDir 'edited-this-session.flag'
    $findingsFile = Join-Path $stateDir 'on-edit-findings.json'
    $hadFindings = Test-Path -LiteralPath $findingsFile
    if (Test-Path -LiteralPath $flag) {
        if ($hadFindings) {
            [Console]::Error.WriteLine('[vibe] Turn end - on-edit findings pending; next prompt will inject them. Fix before commit.')
        } else {
            [Console]::Error.WriteLine('[vibe] Turn end - you edited code: confirm on-edit clean / vibe-review before done.')
        }
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
}

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw) -and $input) { $raw = ($input | Out-String) }
$evt = $null
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try { $evt = $raw | ConvertFrom-Json } catch { $evt = $null }
}

$reason = ''
if ($evt) {
    $reason = [string]$evt.reason
    if (-not $reason) { $reason = [string]$evt.hookEventName }
}
# Session teardown / cancel: never block.
if ($reason -and $reason -ne 'end_turn' -and $reason -notmatch 'Stop$') {
    Invoke-EditRemind
    exit 0
}

$gateChatLib = Join-Path $PSScriptRoot 'gate-chat-lib.ps1'
if (-not (Test-Path -LiteralPath $gateChatLib)) { throw 'gate-chat-lib.ps1 missing' }
. $gateChatLib
if (-not (Get-Command Test-IsGateWaitNow -ErrorAction SilentlyContinue)) { throw 'gate-chat-lib.ps1 failed to load' }

$nowFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt'
if (($env:VIBE_GATE_STOP -ne '0') -and (Test-Path -LiteralPath $nowFile)) {
    $head = @(Get-Content -LiteralPath $nowFile)
    $run = ($head | Where-Object { $_ -match '^RUN:\s+\S+' } | Select-Object -First 1)
    $now = ($head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
    $elapsed = ($head | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
    $pidLine = ($head | Where-Object { $_ -match '^PID:\s+(\d+)' } | Select-Object -First 1)
    $gatePid = 0
    if ($pidLine -and $pidLine -match '^PID:\s+(\d+)') { $gatePid = [int]$Matches[1] }
    elseif ($run -and $run -match '^RUN:\s+(\d+)-') { $gatePid = [int]$Matches[1] }
    $gateAlive = $false
    if ($gatePid -gt 0) { $gateAlive = $null -ne (Get-Process -Id $gatePid -ErrorAction SilentlyContinue) }
    if ($run -and $now -and $now -notmatch 'GATE DONE' -and $gateAlive) {
        $last = ''
        if ($evt) {
            $last = [string]$evt.lastAssistantMessage
            if (-not $last) { $last = [string]$evt.last_assistant_message }
        }
        $runId = ''
        if ($run -match '^RUN:\s+(\S+)') { $runId = $Matches[1] }
        $nowVal = $now -replace '^NOW:\s+', ''
        $spokeFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-last-spoke.txt'
        $spokeNow = ''
        if (Test-Path -LiteralPath $spokeFile) {
            try { $spokeNow = ((Get-Content -LiteralPath $spokeFile -TotalCount 1) -replace '[\r\n]+', '').Trim() } catch { $spokeNow = '' }
        }
        # Waiting is not speakable unless VOTE lines already landed (NOW can lag).
        $hasVotes = @($head | Where-Object { $_ -match '^VOTE:' }).Count -gt 0
        if ((Test-IsGateWaitNow $now) -and -not $hasVotes) {
            Invoke-EditRemind
            exit 0
        }
        $spoke = ($runId -and $last.Contains($runId)) -or ($nowVal -and $last.Contains($nowVal))
        if ($spoke -and $nowVal) {
            try { [System.IO.File]::WriteAllText($spokeFile, (Get-GateNowTickKey $nowVal)) } catch {}
        }
        $nowKey = Get-GateNowTickKey $nowVal
        $spokeKey = Get-GateNowTickKey $spokeNow
        if (-not $spoke -and $spokeKey -and $nowKey -eq $spokeKey) { $spoke = $true }
        $snap = @"
GATE LIVE — Speak scan/vote/arbiter/fixer/DONE and PROGRESS (phase + elapsed). Never 'still waiting' or 'no new votes'.
$run
$now
$elapsed
Optional: start monitor on ~/.grok/vibe-tools/scripts/watch-gate-now.ps1 -Monitor
"@
        if (-not $spoke) {
            Write-Json @{
                decision = 'block'
                reason   = $snap
            }
            exit 0
        }
        Write-Json @{
            hookSpecificOutput = @{
                hookEventName     = 'Stop'
                additionalContext = $snap
            }
        }
        exit 0
    }
    # Fresh GATE DONE: do not let the turn end until chat has the recap.
    # Stops commit-then-push from skipping votes.
    $ageMin = 999
    try {
        $ageMin = ((Get-Date) - (Get-Item -LiteralPath $nowFile).LastWriteTime).TotalMinutes
    } catch { $ageMin = 999 }
    if ($run -and $now -match 'GATE DONE' -and $ageMin -lt 8) {
        $last = ''
        if ($evt) {
            $last = [string]$evt.lastAssistantMessage
            if (-not $last) { $last = [string]$evt.last_assistant_message }
        }
        $runId = ''
        if ($run -match '^RUN:\s+(\S+)') { $runId = $Matches[1] }
        $ackFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-last-done-ack.txt'
        $acked = ''
        if (Test-Path -LiteralPath $ackFile) {
            try { $acked = ((Get-Content -LiteralPath $ackFile -TotalCount 1) -replace '[\r\n]+', '').Trim() } catch { $acked = '' }
        }
        $spoke = ($runId -and $last.Contains($runId) -and $last -match 'GATE DONE')
        if ($spoke -and $runId) {
            try { [System.IO.File]::WriteAllText($ackFile, $runId) } catch {}
        }
        # Recap once: later turns must not re-block while this RUN stays DONE.
        if (-not $spoke -and $runId -and $acked -eq $runId) { $spoke = $true }
        $votes = @($head | Where-Object { $_ -match '^VOTE:' })
        $voteBlock = if ($votes.Count -gt 0) { "`n" + ($votes -join "`n") } else { '' }
        $snap = @"
GATE DONE recap required in chat before the next git command (votes + arbiter + this DONE line):
$run
$now
$elapsed$voteBlock
"@
        if (-not $spoke) {
            Write-Json @{
                decision = 'block'
                reason   = $snap
            }
            exit 0
        }
    }
}

Invoke-EditRemind
exit 0

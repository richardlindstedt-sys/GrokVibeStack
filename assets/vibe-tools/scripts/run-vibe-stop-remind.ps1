#Requires -Version 5.1
<#
.SYNOPSIS
  Stop hook: silent while a gate is live. One recap when it is GATE DONE.
.DESCRIPTION
  The monitor is the only wake during a live gate. Blocking Stop on a live
  gate started a new turn with the same text and looped the session. A
  reviewer process (VIBE_GATE_CHILD=1) never blocks, or its own Stop hook
  becomes the next user message and the vote never finishes.
  GATE DONE blocks once, then the ack is stored so a paraphrased reply
  cannot re-block. Then the edit-session reminder. Fail-open.
#>
$ErrorActionPreference = 'SilentlyContinue'

function Write-StopBlock([string]$Reason) {
    # Hand-built ASCII JSON. ConvertTo-Json plus hookSpecificOutput was rejected
    # at a fixed column ("expected , or }") and ignored on every review turn.
    if ($null -eq $Reason) { $Reason = '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Reason.ToCharArray()) {
        $c = [int]$ch
        if ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
        elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
        elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
        elseif ($c -ge 32 -and $c -le 126) { [void]$sb.Append($ch) }
        else { [void]$sb.AppendFormat('\u{0:x4}', $c) }
    }
    [Console]::Out.WriteLine(('{{"decision":"block","reason":"{0}"}}' -f $sb.ToString()))
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

# Reviewer and arbiter grok processes inherit this. A block becomes their next
# user message, so they never finish the vote and the gate loops.
if ($env:VIBE_GATE_CHILD -eq '1') {
    exit 0
}

$gateChatLib = Join-Path $PSScriptRoot 'gate-chat-lib.ps1'
if (-not (Test-Path -LiteralPath $gateChatLib)) { throw 'gate-chat-lib.ps1 missing' }
. $gateChatLib
if (-not (Get-Command Test-IsGateWaitNow -ErrorAction SilentlyContinue)) { throw 'gate-chat-lib.ps1 failed to load' }

$reportDir = if (-not [string]::IsNullOrWhiteSpace($env:VIBE_GATE_REPORT_DIR)) {
    $env:VIBE_GATE_REPORT_DIR
} else {
    Join-Path $env:USERPROFILE '.grok\vibe-tools\reports'
}
$nowFile = Join-Path $reportDir 'gate-now.txt'
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
    # Live gate: never block. PROGRESS lines come from the monitor, which is
    # the only wake. A Stop block is a new user turn with the same GATE LIVE
    # text, which looped this session and any reviewer that inherited the hook.
    if ($run -and $now -and $now -notmatch 'GATE DONE' -and $gateAlive) {
        Invoke-EditRemind
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
        $ackFile = Join-Path $reportDir 'gate-last-done-ack.txt'
        $acked = ''
        if (Test-Path -LiteralPath $ackFile) {
            try { $acked = ((Get-Content -LiteralPath $ackFile -TotalCount 1) -replace '[\r\n]+', '').Trim() } catch { $acked = '' }
        }
        $spoke = ($runId -and $last.Contains($runId) -and $last -match 'GATE DONE')
        if ($spoke -and $runId) {
            try { [System.IO.File]::WriteAllText($ackFile, $runId) } catch {}
        }
        # Recap once: later turns must not re-block while this RUN stays DONE.
        # Record the ack when the block is emitted. Waiting for the reply to
        # quote the RUN id re-blocked every turn when the reply paraphrased.
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
            if ($runId) {
                try { [System.IO.File]::WriteAllText($ackFile, $runId) } catch {}
            }
            Write-StopBlock $snap
            exit 0
        }
    }
}

Invoke-EditRemind
exit 0

#Requires -Version 5.1
<#
.SYNOPSIS
    Gate chat helper: refresh ELAPSED while the hook is blocked, and/or print
    one line per tick for Grok `monitor` (wakes chat).
.PARAMETER Heartbeat
    Hidden loop: rewrite ELAPSED on gate-now.txt every 15s until GATE DONE.
.PARAMETER Monitor
    Print RUN | NOW when that pair changes (not ELAPSED-only ticks). GATE DONE is a tick, not process
    exit. Leftover GATE DONE at startup does not start the idle clock (that
    printed DONE and killed the Grok monitor before the next gate). Idle arms
    only after this process has seen a live (non-DONE) NOW, then lingers
    IdleSec (default 600s) after that RUN becomes GATE DONE so commit-then-push
    reuses this watch. IdleSec 0 keeps the 2h-only deadline.
.PARAMETER IdleSec
    Seconds of stale GATE DONE (same RUN) before Monitor prints DONE and exits.
    Default 600. 0 = never idle-exit.
.PARAMETER ProgressSec
    During a live gate, print PROGRESS elapsed|phase this often (wakes chat).
    0 = off. Default 60. Not a wait-tick: no 'still waiting' / 'no new votes'.
.PARAMETER IntervalSec
    Poll interval. Default 15.
.PARAMETER NowFile
    Override path to gate-now.txt (tests).
#>
param(
    [switch]$Heartbeat,
    [switch]$Monitor,
    [int]$IdleSec = 600,
    [int]$ProgressSec = 60,
    [int]$IntervalSec = 15,
    [string]$NowFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'
try {
    [Console]::Out.AutoFlush = $true
    [Console]::Error.AutoFlush = $true
} catch {}

$gateChatLib = Join-Path $PSScriptRoot 'gate-chat-lib.ps1'
if (-not (Test-Path -LiteralPath $gateChatLib)) { throw 'gate-chat-lib.ps1 missing' }
. $gateChatLib
if (-not (Get-Command Test-IsGateWaitNow -ErrorAction SilentlyContinue)) { throw 'gate-chat-lib.ps1 failed to load' }

if ($IntervalSec -lt 1) { $IntervalSec = 1 }
if ($IdleSec -lt 0) { $IdleSec = 0 }
$nowFile = if ($NowFile) { $NowFile } else { Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt' }
$deadline = (Get-Date).AddHours(2)
$lastPrint = ''
$idleSince = $null
$idleRun = $null
$sawLive = $false
$seenEvents = New-Object 'System.Collections.Generic.HashSet[string]'
$seenEventsRun = $null
$lastProgress = $null
$lastProgressKey = $null
$primedRun = $null

function Get-InterestingGateEvents([object[]]$Snap) {
    return @($Snap | Where-Object {
            $_ -and
            $_ -notmatch '^(RUN|NOW|ELAPSED|PHASE|PID|CWD|LOG|EVENTS):' -and
            $_ -notmatch 'waiting vibe-' -and
            $_ -match '^VOTE:|STREAM:|scan:|scans passed|scans start|profile=|Round |reviewers running|start reviewer|done reviewer|correctness:|security:|simplicity:|arbiter|fixer|GATE DONE|BLOCKER'
        })
}

function Get-GateSnapshot {
    # Whole gate-now.txt: 8 meta lines, then VOTE:* (sticky), then event tail.
    # Not a header-only read. Name used to be Get-GateHead; that lied.
    if (-not (Test-Path -LiteralPath $nowFile)) { return @() }
    # Windows PowerShell 5.1 Get-Content defaults to ANSI and corrupts UTF-8.
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        return @([System.IO.File]::ReadAllLines($nowFile, $utf8))
    } catch {
        return @(Get-Content -LiteralPath $nowFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
}

function Get-RunStart([string]$RunId) {
    if ($RunId -match '-(\d{17})$') {
        try {
            return [datetime]::ParseExact($Matches[1], 'yyyyMMddHHmmssfff', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch { return $null }
    }
    return $null
}

function Format-Elapsed([datetime]$Start) {
    $sec = [Math]::Max(0, [int]((Get-Date) - $Start).TotalSeconds)
    if ($sec -ge 60) {
        return '{0}m {1}s' -f [int][Math]::Floor($sec / 60), ($sec % 60)
    }
    return '{0}s' -f $sec
}

function Update-GateElapsed {
    # Lock first, re-read, skip write if no mutex or NOW is already GATE DONE.
    $mutex = $null
    $owned = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\VibeGateNowWrite')
        $owned = $mutex.WaitOne(2000)
    } catch { $owned = $false }
    if (-not $owned) {
        if ($mutex) { try { $mutex.Dispose() } catch {} }
        return @(Get-GateSnapshot)
    }
    try {
        $lines = @(Get-GateSnapshot)
        if (-not $lines) { return $lines }
        $nowLine = ($lines | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
        if ($nowLine -and $nowLine -match 'GATE DONE') { return $lines }
        $run = ($lines | Where-Object { $_ -match '^RUN:\s+(\S+)' } | Select-Object -First 1)
        if (-not $run -or $run -notmatch '^RUN:\s+(\S+)') { return $lines }
        $start = Get-RunStart $Matches[1]
        if (-not $start) { return $lines }
        $elapsed = Format-Elapsed $start
        $out = foreach ($ln in $lines) {
            if ($ln -match '^ELAPSED:') { "ELAPSED: $elapsed" } else { $ln }
        }
        $utf8 = New-Object System.Text.UTF8Encoding $false
        # ASCII-strip like Write-GateFileRetry. Do not cut NOW: a 300-char
        # writeback deletes the rest of the live step on every heartbeat.
        $clean = @(foreach ($ln in $out) {
            ConvertTo-GatePlainText (("$ln" -replace '[\r\n]+', ' ').TrimEnd())
        })
        [System.IO.File]::WriteAllLines($nowFile, [string[]]$clean, $utf8)
        return $clean
    } catch {
        return @(Get-GateSnapshot)
    } finally {
        if ($owned -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($mutex) { $mutex.Dispose() }
    }
}

if (-not $Heartbeat -and -not $Monitor) { $Monitor = $true }

# Monitor lingers IdleSec after GATE DONE so commit-then-push can reuse it.
# GATE DONE is a tick, not process exit. Heartbeat-only still stops on GATE DONE.
# Do not idle until a live gate — leftover GATE DONE must not print DONE.
# Missing gate-now.txt does not reset an idle clock already started.
while ((Get-Date) -lt $deadline) {
    $snap = Get-GateSnapshot
    $nowLine = ($snap | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
    $runLine = ($snap | Where-Object { $_ -match '^RUN:\s+' } | Select-Object -First 1)
    $done = $nowLine -and ($nowLine -match 'GATE DONE')
    $runId = $null
    if ($runLine -and $runLine -match '^RUN:\s+(\S+)') { $runId = $Matches[1] }
    if (-not $snap) {
        if ($Monitor -and $IdleSec -gt 0 -and $null -ne $idleSince -and ((Get-Date) - $idleSince).TotalSeconds -ge $IdleSec) {
            [Console]::Out.WriteLine('DONE')
            exit 0
        }
        Start-Sleep -Seconds $IntervalSec
        continue
    }
    if ($Heartbeat -and -not $done) {
        $snap = Update-GateElapsed
        $nowLine = ($snap | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
        $runLine = ($snap | Where-Object { $_ -match '^RUN:\s+' } | Select-Object -First 1)
        $done = $nowLine -and ($nowLine -match 'GATE DONE')
        $runId = $null
        if ($runLine -and $runLine -match '^RUN:\s+(\S+)') { $runId = $Matches[1] }
    }
    if ($done) {
        if ($sawLive -and ($null -eq $idleSince -or $runId -ne $idleRun)) {
            $idleSince = Get-Date
            $idleRun = $runId
        }
    } else {
        $sawLive = $true
        $idleSince = $null
        $idleRun = $null
    }
    if ($Monitor) {
        if ($runId -and $runId -ne $seenEventsRun) {
            $seenEvents.Clear()
            $seenEventsRun = $runId
            $lastProgress = $null
            $lastProgressKey = $null
            $primedRun = $null
        }
        # ELAPSED-only must not wake. Wait ticks must not print. Every stdout line wakes chat.
        # PROGRESS prints only when the phase or the step text changes. A second counter is not a change.
        # First sight of a finished run must not replay it.
        # A live run still prints VOTE lines already on disk (late attach).
        $prime = ($null -ne $runId -and $primedRun -ne $runId)
        if ($prime) {
            foreach ($evt in (Get-InterestingGateEvents $snap)) {
                $evtText = [string]$evt
                if (-not $done -and $evtText -match '(?i)^VOTE:') {
                    [Console]::Out.WriteLine($evtText)
                }
                [void]$seenEvents.Add($evtText)
            }
        }
        $tick = ('{0} | {1}' -f $runLine, (Get-GateNowTickKey $nowLine))
        if (-not $prime -and -not (Test-IsGateWaitNow $nowLine) -and $tick -ne $lastPrint) {
            $elapsed = ($snap | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
            [Console]::Out.WriteLine(('{0} | {1}' -f $tick, $elapsed))
            $lastPrint = $tick
        } else {
            $lastPrint = $tick
        }
        if (-not $prime) {
            foreach ($evt in (Get-InterestingGateEvents $snap)) {
                if ($seenEvents.Add([string]$evt)) {
                    $tag = if ([string]$evt -match '(?i)^VOTE:|correctness:|security:|simplicity:') { 'VOTE' } else { 'EVT' }
                    [Console]::Out.WriteLine(('{0} {1}' -f $tag, $evt))
                }
            }
        }
        if (-not $done -and $ProgressSec -gt 0) {
            $nowTs = Get-Date
            if ($null -eq $lastProgress -or ($nowTs - $lastProgress).TotalSeconds -ge $ProgressSec) {
                $elapsedLn = ($snap | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
                $phaseLn = ($snap | Where-Object { $_ -match '^PHASE:' } | Select-Object -First 1)
                if (-not $phaseLn) { $phaseLn = 'PHASE: live' }
                $doing = 'DOING: no step output yet'
                $nowIsWait = Test-IsGateWaitNow $nowLine
                if (-not $nowIsWait -and $nowLine -match '^NOW:\s+(.+)$') {
                    $nowBody = $Matches[1].Trim()
                    if ($nowBody) { $doing = 'DOING: ' + $nowBody }
                } else {
                    $doingSrc = @($snap | Where-Object {
                            $_ -and $_ -match 'reviewer:|arbiter|fixer|scan:|scans\+tests skipped|tests skipped|compile:|test:'
                        } | Select-Object -Last 1)
                    if ($doingSrc) {
                        $doing = 'DOING: ' + (("$doingSrc" -replace '^\[[^\]]+\]\s*', '') -replace '^EVT\s+', '')
                    }
                }
                $progressKey = '{0}|{1}' -f $phaseLn, (Get-GateNowTickKey $doing)
                $doingIsWait = Test-IsGateWaitNow $doing
                if (-not $prime -and -not $doingIsWait -and $progressKey -ne $lastProgressKey) {
                    [Console]::Out.WriteLine(('PROGRESS {0} | {1} | {2}' -f $elapsedLn, $phaseLn, $doing))
                }
                $lastProgressKey = $progressKey
                $lastProgress = $nowTs
            }
        }
        if ($prime) { $primedRun = $runId }
        if ($IdleSec -gt 0 -and $null -ne $idleSince -and ((Get-Date) - $idleSince).TotalSeconds -ge $IdleSec) {
            [Console]::Out.WriteLine('DONE')
            exit 0
        }
    }
    if ($done -and $Heartbeat -and -not $Monitor) { exit 0 }
    Start-Sleep -Seconds $IntervalSec
}

if ($Monitor) { [Console]::Out.WriteLine('DONE') }
exit 0

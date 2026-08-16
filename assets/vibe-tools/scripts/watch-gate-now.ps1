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
    IdleSec (default 45s) after that RUN becomes GATE DONE. After the last
    gate of a pair the agent kills the watch; if the next gate starts later,
    start a new monitor. IdleSec 0 keeps the 2h-only deadline.
.PARAMETER IdleSec
    Seconds of stale GATE DONE (same RUN) before Monitor prints DONE and exits.
    Default 45. 0 = never idle-exit.
.PARAMETER IntervalSec
    Poll interval. Default 15.
.PARAMETER NowFile
    Override path to gate-now.txt (tests).
#>
param(
    [switch]$Heartbeat,
    [switch]$Monitor,
    [int]$IdleSec = 45,
    [int]$IntervalSec = 15,
    [string]$NowFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'
try {
    [Console]::Out.AutoFlush = $true
    [Console]::Error.AutoFlush = $true
} catch {}

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

function Get-GateNowTickKey([string]$NowLine) {
    # Waiting (~15s)/(~30s) is not a new event. Must not print or wake chat.
    $s = "$NowLine"
    $s = $s -replace '\s*\(~\d+s\)', ''
    $s = $s -replace '\s*none finished yet[^\|]*', ''
    $s = $s -replace '\s{2,}', ' '
    return $s.Trim()
}

function Test-IsGateWaitNow([string]$NowLine) {
    $s = (Get-GateNowTickKey $NowLine) -replace '^NOW:\s+', ''
    return [bool]($s -match '(?i)^Waiting on\b')
}

function Get-InterestingGateEvents([object[]]$Snap) {
    return @($Snap | Where-Object {
            $_ -and
            $_ -notmatch '^(RUN|NOW|ELAPSED|PHASE|PID|CWD|LOG|EVENTS):' -and
            $_ -notmatch 'waiting vibe-' -and
            $_ -match '^VOTE:|scan:|scans passed|scans start|profile=|Round |reviewers running|start reviewer|done reviewer|correctness:|security:|simplicity:|arbiter|fixer|GATE DONE|BLOCKER'
        })
}

function Get-GateSnapshot {
    # Whole gate-now.txt: 8 meta lines, then VOTE:* (sticky), then event tail.
    # Not a header-only read. Name used to be Get-GateHead; that lied.
    if (-not (Test-Path -LiteralPath $nowFile)) { return @() }
    return @(Get-Content -LiteralPath $nowFile -ErrorAction SilentlyContinue)
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
        $clean = foreach ($ln in $out) { ("$ln" -replace '[\r\n]+', ' ').TrimEnd() }
        [System.IO.File]::WriteAllLines($nowFile, [string[]]$clean, $utf8)
        return $out
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
        }
        # ELAPSED-only must not wake. Wait ticks must not print. Every stdout line wakes chat.
        $tick = ('{0} | {1}' -f $runLine, (Get-GateNowTickKey $nowLine))
        if (-not (Test-IsGateWaitNow $nowLine) -and $tick -ne $lastPrint) {
            $elapsed = ($snap | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
            [Console]::Out.WriteLine(('{0} | {1}' -f $tick, $elapsed))
            $lastPrint = $tick
        } elseif (Test-IsGateWaitNow $nowLine) {
            $lastPrint = $tick
        }
        foreach ($evt in (Get-InterestingGateEvents $snap)) {
            if ($seenEvents.Add([string]$evt)) {
                $tag = if ([string]$evt -match '(?i)^VOTE:|correctness:|security:|simplicity:') { 'VOTE' } else { 'EVT' }
                [Console]::Out.WriteLine(('{0} {1}' -f $tag, $evt))
            }
        }
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

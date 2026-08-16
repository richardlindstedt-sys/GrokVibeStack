#Requires -Version 5.1
<#
.SYNOPSIS
    Gate chat helper: refresh ELAPSED while the hook is blocked, and/or print
    one line per tick for Grok `monitor` (wakes chat).
.PARAMETER Heartbeat
    Hidden loop: rewrite ELAPSED on gate-now.txt every 15s until GATE DONE.
.PARAMETER Monitor
    Print RUN | NOW | ELAPSED when it changes. GATE DONE is a tick, not process
    exit — stay up across sequential gates (commit then push). Print DONE only
    at the 2h deadline. Use as the monitor tool command.
#>
param(
    [switch]$Heartbeat,
    [switch]$Monitor
)

$ErrorActionPreference = 'SilentlyContinue'
try {
    [Console]::Out.AutoFlush = $true
    [Console]::Error.AutoFlush = $true
} catch {}

$nowFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt'
$intervalSec = 15
$deadline = (Get-Date).AddHours(2)
$lastPrint = ''

function Get-GateHead {
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
        return @(Get-GateHead)
    }
    try {
        $lines = @(Get-GateHead)
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
        return @(Get-GateHead)
    } finally {
        if ($owned -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($mutex) { $mutex.Dispose() }
    }
}

if (-not $Heartbeat -and -not $Monitor) { $Monitor = $true }

# Monitor stays up across sequential gates (commit then push).
# GATE DONE is a tick, not process exit. Heartbeat-only still stops on GATE DONE.
while ((Get-Date) -lt $deadline) {
    $head = Get-GateHead
    $nowLine = ($head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
    $done = $nowLine -and ($nowLine -match 'GATE DONE')
    if (-not $head) {
        Start-Sleep -Seconds $intervalSec
        continue
    }
    if ($Heartbeat -and -not $done) {
        $head = Update-GateElapsed
        $nowLine = ($head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
        $done = $nowLine -and ($nowLine -match 'GATE DONE')
    }
    if ($Monitor) {
        $run = ($head | Where-Object { $_ -match '^RUN:\s+' } | Select-Object -First 1)
        $now = ($head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
        $elapsed = ($head | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
        $snap = ('{0} | {1} | {2}' -f $run, $now, $elapsed)
        if ($snap -ne $lastPrint) {
            [Console]::Out.WriteLine($snap)
            $lastPrint = $snap
        }
    }
    if ($done -and $Heartbeat -and -not $Monitor) { exit 0 }
    Start-Sleep -Seconds $intervalSec
}

if ($Monitor) { [Console]::Out.WriteLine('DONE') }
exit 0

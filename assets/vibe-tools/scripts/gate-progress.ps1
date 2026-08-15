#Requires -Version 5.1
<#
.SYNOPSIS
    Flushed gate progress (console + stderr + live-gate.log + append-only gate-status.txt + gate-now.txt).
.NOTES
    Write-Host is dropped when git/Grok redirects the hook. Console + stderr + files
    stay visible. Popup is opt-in (VIBE_GATE_POPUP=1). Default watch is chat:
    agent polls gate-now.txt while commit/push runs in the background.
    First line of gate-now.txt is RUN: <pid-timestamp>. Poller must ignore
    GATE DONE until it has seen that RUN (stale DONE from a prior gate).
#>

if (-not $script:GateLiveLog) {
    $script:GateLiveLog = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\live-gate.log'
}
if (-not $script:GateStatusFile) {
    $script:GateStatusFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-status.txt'
}
if (-not $script:GateNowFile) {
    $script:GateNowFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt'
}
if (-not $script:GateEvents) {
    $script:GateEvents = [System.Collections.Generic.List[string]]::new()
}
if (-not $script:GateNow) { $script:GateNow = 'starting' }
if (-not $script:GatePhase) { $script:GatePhase = '' }
if (-not $script:GateSw) { $script:GateSw = [System.Diagnostics.Stopwatch]::StartNew() }

try {
    [Console]::Out.AutoFlush = $true
    [Console]::Error.AutoFlush = $true
} catch {}

function New-GateRunId {
    '{0}-{1}' -f $PID, (Get-Date -Format 'yyyyMMddHHmmssfff')
}

function Write-GateFileRetry {
    param(
        [string]$Path,
        [string[]]$Lines,
        [switch]$Append,
        [int]$Tries = 4
    )
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $last = $null
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            if ($Append) {
                [System.IO.File]::AppendAllLines($Path, [string[]]$Lines, $utf8)
            } else {
                [System.IO.File]::WriteAllLines($Path, [string[]]$Lines, $utf8)
            }
            return
        } catch {
            $last = $_
            Start-Sleep -Milliseconds (40 * $i)
        }
    }
    $msg = 'GATE STATUS WRITE FAILED ({0}): {1}' -f $Path, $last
    try { [Console]::Error.WriteLine($msg) } catch {}
    Write-Warning $msg
}

function Import-GateStatusTail {
    if (-not $script:GateEvents) {
        $script:GateEvents = [System.Collections.Generic.List[string]]::new()
    }
    if (-not (Test-Path -LiteralPath $script:GateStatusFile)) { return }
    $all = @(Get-Content -LiteralPath $script:GateStatusFile -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return }
    $start = 0
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        if ($all[$i] -match '^==== gate start') { $start = $i; break }
    }
    foreach ($ln in @($all | Select-Object -Skip $start -Last 60)) {
        if ([string]$ln -match 'GATE DONE') { continue }
        [void]$script:GateEvents.Add([string]$ln)
    }
}

function Write-GateStatusFile {
    # Snapshot (RUN/NOW/ELAPSED) is rewritten; gate-status.txt is append-only.
    if (-not $script:GateRunId) { $script:GateRunId = New-GateRunId }
    if (-not $script:GateSw) { $script:GateSw = [System.Diagnostics.Stopwatch]::StartNew() }
    $sec = [int]$script:GateSw.Elapsed.TotalSeconds
    $elapsed = if ($sec -ge 60) { '{0}m {1}s' -f [int][math]::Floor($sec / 60), ($sec % 60) } else { '{0}s' -f $sec }
    $body = @(
        "RUN:     $($script:GateRunId)"
        "NOW:     $($script:GateNow)"
        "ELAPSED: $elapsed"
        "PHASE:   $($script:GatePhase)"
        "LOG:     $($script:GateLiveLog)"
        "EVENTS:  $($script:GateStatusFile)"
        ''
    )
    $ev = @($script:GateEvents | Where-Object {
        if ($script:GateNow -match 'GATE DONE') { $true } else { $_ -notmatch 'GATE DONE' }
    } | Select-Object -Last 20)
    $body = $body + $ev
    Write-GateFileRetry -Path $script:GateNowFile -Lines $body
}

function Add-GateStatusLine([string]$Line) {
    Write-GateFileRetry -Path $script:GateStatusFile -Lines @($Line) -Append
}

function Write-GateNow([string]$Now, [string]$Phase) {
    if ($Now) { $script:GateNow = $Now }
    if ($Phase) { $script:GatePhase = $Phase }
    Write-GateStatusFile
}

function Start-GateWatchPopup {
    # Opt-in only. Default surface is this Grok chat (poll gate-now.txt).
    if ($env:VIBE_GATE_POPUP -ne '1') { return }
    if ($env:CI -or $env:GITHUB_ACTIONS) { return }
    if (-not [Environment]::UserInteractive) { return }
    if ($script:GateWatchStarted) { return }
    $script:GateWatchStarted = $true
    $status = $script:GateStatusFile
    $nowFile = $script:GateNowFile
    $runId = $script:GateRunId
    $watcher = @"
`$Host.UI.RawUI.WindowTitle = 'Vibe gate'
while (`$true) {
    Clear-Host
    Write-Host 'VIBE GATE  (safe to close this window)' -ForegroundColor Cyan
    Write-Host 'snapshot: $nowFile' -ForegroundColor DarkGray
    Write-Host 'events:   $status  (Get-Content -Wait)' -ForegroundColor DarkGray
    Write-Host ''
    if (Test-Path -LiteralPath '$nowFile') {
        Get-Content -LiteralPath '$nowFile' -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath '$status') {
        Get-Content -LiteralPath '$status' -ErrorAction SilentlyContinue
    } else {
        Write-Host '(waiting for first status write...)' -ForegroundColor DarkGray
    }
    `$snap = ''
    if (Test-Path -LiteralPath '$nowFile') {
        `$snap = [string](Get-Content -LiteralPath '$nowFile' -Raw -ErrorAction SilentlyContinue)
    }
    `$runOk = (-not '$runId') -or (`$snap -match [regex]::Escape('$runId'))
    if (`$runOk -and `$snap -match 'GATE DONE') {
        Write-Host ''
        Write-Host 'Gate finished. Window closes in 12s...' -ForegroundColor DarkGray
        Start-Sleep -Seconds 12
        break
    }
    Start-Sleep -Seconds 2
}
"@
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $watcher
        ) -WindowStyle Normal | Out-Null
        Write-GateProgress 'opened optional desktop window (VIBE_GATE_POPUP=1)'
    } catch {
        Write-Warning ("Start-GateWatchPopup failed: {0}" -f $_)
    }
}

function Reset-GateLiveLog {
    # New RUN first so poller can latch before any GATE DONE. Append-only status.
    $dir = Split-Path $script:GateLiveLog -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $script:GateRunId = New-GateRunId
    $script:GateEvents = [System.Collections.Generic.List[string]]::new()
    $script:GateNow = 'starting'
    $script:GatePhase = 'init'
    $script:GateSw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:GateWatchStarted = $false
    Write-GateStatusFile
    $hdr = '==== gate start {0} run={1} pid={2} cwd={3} ====' -f (Get-Date -Format 'o'), $script:GateRunId, $PID, (Get-Location).Path
    $last = $null
    for ($i = 1; $i -le 4; $i++) {
        try {
            Set-Content -LiteralPath $script:GateLiveLog -Value $hdr -Encoding utf8
            $last = $null
            break
        } catch {
            $last = $_
            Start-Sleep -Milliseconds (40 * $i)
        }
    }
    if ($last) {
        $msg = 'GATE LIVE-LOG WRITE FAILED: {0}' -f $last
        try { [Console]::Error.WriteLine($msg) } catch {}
        Write-Warning $msg
    }
    Add-GateStatusLine $hdr
    Write-GateProgress 'live status -> ~/.grok/vibe-tools/reports/gate-status.txt (append; Get-Content -Wait)'
    Write-GateProgress 'live log    -> ~/.grok/vibe-tools/reports/live-gate.log'
    Start-GateWatchPopup
}

function Start-GateRun {
    # Adopt a live RUN from gate-now.txt, or start a new one (replaces stale GATE DONE).
    if ($script:GateRunId) { return }
    if (Test-Path -LiteralPath $script:GateNowFile) {
        $head = @(Get-Content -LiteralPath $script:GateNowFile -TotalCount 8 -ErrorAction SilentlyContinue)
        $runLine = $head | Where-Object { $_ -match '^RUN:\s+(\S+)' } | Select-Object -First 1
        $nowLine = $head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1
        if ($runLine -and $runLine -match '^RUN:\s+(\S+)' -and $nowLine -notmatch 'GATE DONE') {
            $script:GateRunId = $Matches[1]
            Import-GateStatusTail
            return
        }
    }
    Reset-GateLiveLog
}

function Write-GateProgress {
    param(
        [string]$Message,
        [string]$Now,
        [string]$Phase
    )
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message
    foreach ($writer in @([Console]::Out, [Console]::Error)) {
        try {
            $writer.WriteLine($line)
            $writer.Flush()
        } catch {}
    }
    try {
        $dir = Split-Path $script:GateLiveLog -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Add-Content -LiteralPath $script:GateLiveLog -Value $line -Encoding utf8
    } catch {}
    try {
        [void]$script:GateEvents.Add($line)
        Add-GateStatusLine $line
        if ($script:GateEvents.Count -gt 80) {
            $script:GateEvents.RemoveRange(0, $script:GateEvents.Count - 60)
        }
    } catch {}
    if ($Now) { $script:GateNow = $Now }
    if ($Phase) { $script:GatePhase = $Phase }
    Write-GateStatusFile
}

function Write-GateDone {
    param(
        [string]$Summary,
        [switch]$Passed
    )
    $tag = if ($Passed) { 'GATE DONE - passed' } else { 'GATE DONE - blocked' }
    $msg = if ($Summary) { "$tag. $Summary" } else { $tag }
    $script:GateNow = $msg
    $script:GatePhase = if ($Passed) { 'done-pass' } else { 'done-block' }
    Write-GateProgress $msg
}

function Wait-VibeJobs {
    param(
        $Jobs,
        [int]$TimeoutSec = 1200,
        [int]$PulseSec = 15
    )
    $list = @($Jobs | Where-Object { $_ })
    if ($list.Count -eq 0) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $allNames = ($list | ForEach-Object { $_.Name }) -join ', '
    Write-GateProgress ("reviewers running: {0} (findings appear as each finishes)" -f $allNames) `
        -Now ("Waiting on reviewers: $allNames") -Phase 'reviewers'
    while ($true) {
        $running = @($list | Where-Object { $_.State -eq 'Running' })
        $done = @($list | Where-Object { $_.State -ne 'Running' })
        if ($running.Count -eq 0) { break }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
            Write-GateProgress ('job timeout after {0:n0}s - stopping leftover jobs' -f $sw.Elapsed.TotalSeconds)
            foreach ($j in $running) {
                try { Stop-Job $j -ErrorAction SilentlyContinue } catch {}
            }
            break
        }
        $waitNames = ($running | ForEach-Object { $_.Name }) -join ', '
        $doneBit = if ($done.Count -gt 0) {
            ' finished: ' + (($done | ForEach-Object { $_.Name }) -join ', ')
        } else {
            ' none finished yet - still thinking, no findings to show'
        }
        $elapsed = [int]$sw.Elapsed.TotalSeconds
        Write-GateProgress ("waiting {0} ({1}s).{2}" -f $waitNames, $elapsed, $doneBit) `
            -Now ("Waiting on $waitNames (~${elapsed}s).$doneBit")
        $null = Wait-Job -Job $running -Timeout $PulseSec
    }
}

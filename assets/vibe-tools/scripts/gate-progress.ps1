#Requires -Version 5.1
<#
.SYNOPSIS
    Flushed gate progress (console + stderr + live-gate.log + append-only gate-status.txt + gate-now.txt).
.NOTES
    Write-Host is dropped when git/Grok redirects the hook. Console + stderr + files
    stay visible. Popup is opt-in (VIBE_GATE_POPUP=1). Default watch is chat:
    watch-gate-now -Monitor wakes chat on real events only (not wait ticks).
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
if (-not $script:GateLastDoneFile) {
    $script:GateLastDoneFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-last-done.txt'
}
if (-not $script:GateEvents) {
    $script:GateEvents = [System.Collections.Generic.List[string]]::new()
}
if (-not $script:GateVotes) {
    $script:GateVotes = [ordered]@{}
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
    $clean = foreach ($ln in @($Lines)) {
        ("$ln" -replace '[\r\n]+', ' ').TrimEnd()
    }
    $mutex = $null
    $owned = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\VibeGateNowWrite')
        $owned = $mutex.WaitOne(2000)
    } catch { $owned = $false }
    $last = $null
    try {
        for ($i = 1; $i -le $Tries; $i++) {
            try {
                if ($Append) {
                    [System.IO.File]::AppendAllLines($Path, [string[]]$clean, $utf8)
                } else {
                    [System.IO.File]::WriteAllLines($Path, [string[]]$clean, $utf8)
                }
                return
            } catch {
                $last = $_
                Start-Sleep -Milliseconds (40 * $i)
            }
        }
    } finally {
        if ($owned -and $mutex) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        if ($mutex) { $mutex.Dispose() }
    }
    $msg = 'GATE STATUS WRITE FAILED ({0}): {1}' -f $Path, $last
    try { [Console]::Error.WriteLine($msg) } catch {}
    Write-Warning $msg
}

function Save-GateLastDone {
    # Keep the finished snapshot when the next RUN overwrites gate-now.txt.
    param([string]$From = $script:GateNowFile)
    if (-not $From -or -not (Test-Path -LiteralPath $From)) { return }
    $lines = @(Get-Content -LiteralPath $From -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return }
    $blob = $lines -join "`n"
    if ($blob -notmatch 'GATE DONE' -and $blob -notmatch '(?m)^VOTE:') { return }
    if (-not $script:GateLastDoneFile) {
        $script:GateLastDoneFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-last-done.txt'
    }
    Write-GateFileRetry -Path $script:GateLastDoneFile -Lines $lines
}

function Get-GateOpenAdvisoriesFile {
    Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-open-advisories.json'
}

function Save-GateOpenAdvisories {
    # Hashtable merge by cwd+id (no ForEach-Object $hit). This cwd's ids in $Items
    # stay open; this cwd's ids missing from $Items are marked resolved.
    param(
        [object[]]$Items,
        [string]$RunId,
        [string]$Cwd
    )
    if (-not $Cwd) {
        try { $Cwd = (Get-Location).Path } catch { $Cwd = '' }
    }
    if (-not $Cwd) { return }
    $path = Get-GateOpenAdvisoriesFile
    $prevItems = @()
    if (Test-Path -LiteralPath $path) {
        try {
            $prev = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
            if ($prev -and $prev.items) { $prevItems = @($prev.items) }
        } catch { $prevItems = @() }
    }
    $byKey = @{}
    foreach ($old in $prevItems) {
        $oc = [string]$old.cwd
        $oid = [string]$old.id
        if (-not $oc -or -not $oid) { continue }
        $byKey[('{0}|{1}' -f $oc, $oid)] = $old
    }
    $seen = @{}
    foreach ($raw in @($Items | Where-Object { $_ })) {
        $id = [string]$raw.id
        if (-not $id) { $id = [string]$raw.title }
        if (-not $id) { continue }
        $k = '{0}|{1}' -f $Cwd, $id
        $seen[$k] = $true
        $byKey[$k] = [pscustomobject]@{
            cwd    = $Cwd
            id     = $id
            title  = [string]$raw.title
            detail = [string]$raw.detail
            file   = [string]$raw.file
            run    = $RunId
            status = 'open'
        }
    }
    foreach ($k in @($byKey.Keys)) {
        $row = $byKey[$k]
        if ([string]$row.cwd -ne $Cwd) { continue }
        if ($seen.ContainsKey($k)) { continue }
        if ([string]$row.status -eq 'resolved') { continue }
        $byKey[$k] = [pscustomobject]@{
            cwd         = [string]$row.cwd
            id          = [string]$row.id
            title       = [string]$row.title
            detail      = [string]$row.detail
            file        = [string]$row.file
            run         = [string]$row.run
            status      = 'resolved'
            resolvedRun = $RunId
        }
    }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $doc = [pscustomobject]@{
        updated = (Get-Date).ToString('o')
        items   = @($byKey.Values)
    }
    $json = $doc | ConvertTo-Json -Depth 6
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json, $utf8)
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
    # Slice first. Select-Object -Skip + -Last applies -Last to the whole file in PS 5.1.
    $slice = @($all[$start..($all.Count - 1)])
    $take = [Math]::Min(60, $slice.Count)
    $tail = if ($take -le 0) { @() } else { @($slice[($slice.Count - $take)..($slice.Count - 1)]) }
    foreach ($ln in $tail) {
        if ([string]$ln -match 'GATE DONE') { continue }
        [void]$script:GateEvents.Add([string]$ln)
    }
}

function Write-GateStatusFile {
    # Snapshot (RUN/NOW/ELAPSED) is rewritten; gate-status.txt is append-only.
    if (-not $script:GateRunId) { $script:GateRunId = New-GateRunId }
    if (-not $script:GateSw) { $script:GateSw = [System.Diagnostics.Stopwatch]::StartNew() }
    if (-not $script:GatePid) { $script:GatePid = $PID }
    if (-not $script:GateCwd) {
        try { $script:GateCwd = (Get-Location).Path } catch { $script:GateCwd = '' }
    }
    $sec = [int]$script:GateSw.Elapsed.TotalSeconds
    $elapsed = if ($sec -ge 60) { '{0}m {1}s' -f [int][math]::Floor($sec / 60), ($sec % 60) } else { '{0}s' -f $sec }
    $body = @(
        "RUN:     $($script:GateRunId)"
        "NOW:     $($script:GateNow)"
        "ELAPSED: $elapsed"
        "PHASE:   $($script:GatePhase)"
        "PID:     $($script:GatePid)"
        "CWD:     $($script:GateCwd)"
        "LOG:     $($script:GateLiveLog)"
        "EVENTS:  $($script:GateStatusFile)"
    )
    if ($script:GateVotes) {
        foreach ($vk in @($script:GateVotes.Keys)) {
            $body += ('VOTE:    {0}' -f $script:GateVotes[$vk])
        }
    }
    $body += ''
    $ev = @($script:GateEvents | Where-Object {
        if ($script:GateNow -match 'GATE DONE') { $true } else { $_ -notmatch 'GATE DONE' }
    } | Select-Object -Last 20)
    $body = $body + $ev
    Write-GateFileRetry -Path $script:GateNowFile -Lines $body
}

function Add-GateStatusLine([string]$Line) {
    Write-GateFileRetry -Path $script:GateStatusFile -Lines @($Line) -Append
}

function Start-GateElapsedHeartbeat {
    # Separate process: parent is often blocked inside grok.exe (fixer).
    if ($env:VIBE_GATE_CHILD -eq '1') { return }
    $dir = Split-Path $script:GateNowFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $pidFile = Join-Path $dir 'gate-beat.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $old = 0
        try { $old = [int]((Get-Content -LiteralPath $pidFile -TotalCount 1).Trim()) } catch { $old = 0 }
        if ($old -gt 0) {
            $proc = Get-Process -Id $old -ErrorAction SilentlyContinue
            if ($proc) {
                $cmd = ''
                try { $cmd = [string]$proc.Path + ' ' + [string]$proc.ProcessName } catch {}
                return
            }
        }
    }
    $watch = Join-Path $PSScriptRoot 'watch-gate-now.ps1'
    if (-not (Test-Path -LiteralPath $watch)) { return }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch, '-Heartbeat'
        ) -WindowStyle Hidden -PassThru
        if ($p) {
            Set-Content -LiteralPath $pidFile -Value ([string]$p.Id) -Encoding ascii
            $script:GateBeatPid = $p.Id
        }
    } catch {}
}

function Stop-GateElapsedHeartbeat {
    $dir = Split-Path $script:GateNowFile -Parent
    $pidFile = Join-Path $dir 'gate-beat.pid'
    $old = 0
    if (Test-Path -LiteralPath $pidFile) {
        try { $old = [int]((Get-Content -LiteralPath $pidFile -TotalCount 1).Trim()) } catch { $old = 0 }
    }
    if ($script:GateBeatPid -and $script:GateBeatPid -gt 0) { $old = [int]$script:GateBeatPid }
    if ($old -gt 0) {
        $proc = Get-Process -Id $old -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match 'powershell') {
            try { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    if (Test-Path -LiteralPath $pidFile) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
    $script:GateBeatPid = $null
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
    $runId = [string]$script:GateRunId
    if ($runId -notmatch '^\d+-\d{17}$') {
        Write-Warning 'Start-GateWatchPopup: refusing invalid run id'
        return
    }
    $nowFile = [string]$script:GateNowFile
    $status = [string]$script:GateStatusFile
    $dir = Split-Path $script:GateNowFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $watchPs1 = Join-Path $dir ("gate-watch-{0}.ps1" -f $runId)
    $watcher = @"
`$Host.UI.RawUI.WindowTitle = 'Vibe gate'
`$nowFile = $($nowFile | ConvertTo-Json -Compress)
`$status = $($status | ConvertTo-Json -Compress)
`$runId = $($runId | ConvertTo-Json -Compress)
while (`$true) {
    Clear-Host
    Write-Host 'VIBE GATE  (safe to close this window)' -ForegroundColor Cyan
    Write-Host ("snapshot: {0}" -f `$nowFile) -ForegroundColor DarkGray
    Write-Host ("events:   {0}  (Get-Content -Wait)" -f `$status) -ForegroundColor DarkGray
    Write-Host ''
    if (Test-Path -LiteralPath `$nowFile) {
        Get-Content -LiteralPath `$nowFile -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath `$status) {
        Get-Content -LiteralPath `$status -ErrorAction SilentlyContinue
    } else {
        Write-Host '(waiting for first status write...)' -ForegroundColor DarkGray
    }
    `$snap = ''
    if (Test-Path -LiteralPath `$nowFile) {
        `$snap = [string](Get-Content -LiteralPath `$nowFile -Raw -ErrorAction SilentlyContinue)
    }
    `$runOk = (-not `$runId) -or (`$snap -match [regex]::Escape(`$runId))
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
        Set-Content -LiteralPath $watchPs1 -Value $watcher -Encoding utf8
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watchPs1
        ) -WindowStyle Normal | Out-Null
        Write-GateProgress 'opened optional desktop window (VIBE_GATE_POPUP=1)'
    } catch {
        Write-Warning ("Start-GateWatchPopup failed: {0}" -f $_)
    }
}

function Reset-GateLiveLog {
    # Persist votes/DONE before this new RUN overwrites gate-now.txt.
    Save-GateLastDone
    # New RUN first so poller can latch before any GATE DONE. Append-only status.
    $dir = Split-Path $script:GateLiveLog -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $script:GateRunId = New-GateRunId
    $script:GatePid = $PID
    try { $script:GateCwd = (Get-Location).Path } catch { $script:GateCwd = '' }
    $script:GateEvents = [System.Collections.Generic.List[string]]::new()
    $script:GateVotes = [ordered]@{}
    $script:GateNow = 'starting'
    $script:GatePhase = 'init'
    $script:GateSw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:GateWatchStarted = $false
    $script:LastWaitNow = $null
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
    Start-GateElapsedHeartbeat
}

function Start-GateRun {
    # Adopt a live RUN only when its PID is still alive and CWD matches this repo.
    # Child scan processes must never reset the parent's RUN (that tears gate-now.txt).
    if ($script:GateRunId) { return }
    $child = ($env:VIBE_GATE_CHILD -eq '1')
    if (Test-Path -LiteralPath $script:GateNowFile) {
        $head = @(Get-Content -LiteralPath $script:GateNowFile -TotalCount 16 -ErrorAction SilentlyContinue)
        $runLine = $head | Where-Object { $_ -match '^RUN:\s+(\S+)' } | Select-Object -First 1
        $nowLine = $head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1
        $pidLine = $head | Where-Object { $_ -match '^PID:\s+(\d+)' } | Select-Object -First 1
        $cwdLine = $head | Where-Object { $_ -match '^CWD:\s+(.+)$' } | Select-Object -First 1
        $runId = $null
        if ($runLine -and $runLine -match '^RUN:\s+(\S+)') { $runId = $Matches[1] }
        $adoptPid = 0
        if ($pidLine -and $pidLine -match '^PID:\s+(\d+)') {
            $adoptPid = [int]$Matches[1]
        } elseif ($runId -and $runId -match '^(\d+)-\d{17}$') {
            $adoptPid = [int]$Matches[1]
        }
        $adoptCwd = $null
        if ($cwdLine -and $cwdLine -match '^CWD:\s+(.+)$') { $adoptCwd = $Matches[1].Trim() }
        $alive = $false
        if ($adoptPid -gt 0) {
            $alive = $null -ne (Get-Process -Id $adoptPid -ErrorAction SilentlyContinue)
        }
        $cwdOk = $false
        if ($adoptCwd) {
            try {
                $here = [System.IO.Path]::GetFullPath((Get-Location).Path).TrimEnd('\', '/').ToLowerInvariant()
                $there = [System.IO.Path]::GetFullPath($adoptCwd).TrimEnd('\', '/').ToLowerInvariant()
                $cwdOk = ($here -eq $there)
            } catch { $cwdOk = $false }
        }
        $inherit = ($env:VIBE_GATE_INHERIT -eq '1')
        if ($runId -and $nowLine -notmatch 'GATE DONE' -and $cwdOk -and ($child -or $alive -or $inherit)) {
            $script:GateRunId = $runId
            if ($adoptPid -gt 0) { $script:GatePid = $adoptPid }
            if ($adoptCwd) { $script:GateCwd = $adoptCwd }
            Import-GateStatusTail
            if (-not $child) { Start-GateElapsedHeartbeat }
            return
        }
    }
    if ($child) { return }
    Reset-GateLiveLog
}

function Set-GateVote {
    param(
        [string]$Role,
        [string]$Text
    )
    if (-not $Role -or -not $Text) { return }
    if (-not $script:GateVotes) { $script:GateVotes = [ordered]@{} }
    $script:GateVotes[$Role] = ($Text -replace '[\r\n]+', ' ').Trim()
    Write-GateStatusFile
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
    Save-GateLastDone
    Stop-GateElapsedHeartbeat
}

function Set-GateWaitNow {
    # Refresh ELAPSED without rewriting NOW on every pulse. Never embed (~Ns).
    param([string]$WaitNames)
    if (-not $WaitNames) { return }
    $nowWait = "Waiting on $WaitNames"
    if ($nowWait -ne $script:LastWaitNow) {
        $script:LastWaitNow = $nowWait
        Write-GateProgress ("waiting {0}" -f $WaitNames) -Now $nowWait
    } elseif (Get-Command Write-GateStatusFile -ErrorAction SilentlyContinue) {
        Write-GateStatusFile
    }
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
        Set-GateWaitNow $waitNames
        $null = Wait-Job -Job $running -Timeout $PulseSec
    }
}

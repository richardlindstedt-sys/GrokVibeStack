#Requires -Version 5.1
<#
.SYNOPSIS
    Flushed gate progress (stdout + stderr + live-gate.log).
.NOTES
    Write-Host is dropped when git/Grok redirects the hook. Console + stderr + file
    stay visible. Heartbeats while reviewer jobs run so the session is not silent.
#>

if (-not $script:GateLiveLog) {
    $script:GateLiveLog = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\live-gate.log'
}

function Reset-GateLiveLog {
    try {
        $dir = Split-Path $script:GateLiveLog -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $hdr = '==== gate start {0} pid={1} cwd={2} ====' -f (Get-Date -Format 'o'), $PID, (Get-Location).Path
        Set-Content -LiteralPath $script:GateLiveLog -Value $hdr -Encoding utf8
        Write-GateProgress 'live log -> ~/.grok/vibe-tools/reports/live-gate.log'
    } catch {}
}

function Write-GateProgress {
    param([string]$Message)
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
    while ($true) {
        $running = @($list | Where-Object { $_.State -eq 'Running' })
        if ($running.Count -eq 0) { break }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
            Write-GateProgress ('job timeout after {0:n0}s - stopping leftover jobs' -f $sw.Elapsed.TotalSeconds)
            break
        }
        $names = ($running | ForEach-Object { $_.Name }) -join ', '
        Write-GateProgress ("waiting {0} ({1:n0}s)" -f $names, $sw.Elapsed.TotalSeconds)
        $null = Wait-Job -Job $running -Timeout $PulseSec
    }
}

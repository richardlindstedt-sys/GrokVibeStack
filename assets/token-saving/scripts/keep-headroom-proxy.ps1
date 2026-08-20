#Requires -Version 5.1
<#
.SYNOPSIS
  Keep the Headroom proxy alive. Restarts it within a few seconds if it dies.

.DESCRIPTION
  Singleton (mutex). start-grok launches this hidden; a logon scheduled task
  also starts it. -StopProxy on start-grok kills this first, then the proxy.

  Invokes start-grok as a *child* process. Dot-sourcing / & would hit that
  script's `exit 0` and kill this keeper.
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [int]$IntervalSec = 5,
    [int]$Port = 8787
)
$ErrorActionPreference = 'Continue'
if ($IntervalSec -lt 2) { $IntervalSec = 2 }

$GrokHome = Join-Path $env:USERPROFILE '.grok'
$TokenRoot = Join-Path $GrokHome 'token-saving'
$StateDir = Join-Path $TokenRoot 'state'
$LogDir = Join-Path $TokenRoot 'logs'
$StartPs1 = Join-Path $TokenRoot 'scripts\start-grok.ps1'
$PidFile = Join-Path $StateDir 'headroom-keeper.pid'
$LogFile = Join-Path $LogDir 'headroom-keeper.log'
$MutexName = 'Local\GrokVibeHeadroomKeeper'

function Write-KeepLog([string]$msg) {
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $msg
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        }
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 2MB)) {
            Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.bak') -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {}
}

function Test-ProxyReady([int]$p) {
    foreach ($path in @('/readyz', '/health', '/livez')) {
        try {
            $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}{1}" -f $p, $path) -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { return $true }
        } catch {}
    }
    return $false
}

function Start-ProxyChild([int]$p) {
    if (-not (Test-Path -LiteralPath $StartPs1)) {
        Write-KeepLog ("missing {0}" -f $StartPs1)
        return 1
    }
    $outFile = Join-Path $env:TEMP ('headroom-keep-out-{0}.log' -f $PID)
    $errFile = Join-Path $env:TEMP ('headroom-keep-err-{0}.log' -f $PID)
    foreach ($f in @($outFile, $errFile)) {
        try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch {}
    }
    $arg = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $StartPs1,
        '-ProxyOnly', '-Quiet', '-Port', "$p"
    )
    Write-KeepLog ('start-grok child -ProxyOnly -Port {0}' -f $p)
    $code = 1
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $arg `
            -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if ($proc) { $code = [int]$proc.ExitCode }
    } catch {
        Write-KeepLog ("start failed: {0}" -f $_.Exception.Message)
        return 1
    }
    foreach ($f in @($outFile, $errFile)) {
        try {
            if (Test-Path -LiteralPath $f) {
                Get-Content -LiteralPath $f -ErrorAction SilentlyContinue |
                    ForEach-Object { if ("$_".Trim()) { Write-KeepLog ("  {0}" -f $_) } }
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    if ($code -ne 0) { Write-KeepLog ("start-grok exit {0}" -f $code) }
    return $code
}

if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
}

$mutex = $null
$owned = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # Previous keeper was killed; we own the mutex.
    $owned = $true
} catch {
    $owned = $false
}
if (-not $owned) {
    exit 0
}

try {
    Set-Content -Path $PidFile -Value $PID -Encoding ascii -NoNewline
    Write-KeepLog ("keeper start pid={0} interval={1}s once={2} port={3}" -f $PID, $IntervalSec, [bool]$Once, $Port)

    $failStreak = 0
    while ($true) {
        if (Test-ProxyReady $Port) {
            $failStreak = 0
            if ($Once) { exit 0 }
            Start-Sleep -Seconds $IntervalSec
            continue
        }
        $failStreak++
        # One HTTP blip must not kill a live proxy (start-grok -ProxyOnly restarts).
        if ($failStreak -lt 2 -and -not $Once) {
            Write-KeepLog ("proxy not ready ({0}) - retry" -f $failStreak)
            Start-Sleep -Seconds $IntervalSec
            continue
        }
        Write-KeepLog 'proxy not ready - start-grok -ProxyOnly -Quiet (child)'
        $null = Start-ProxyChild $Port
        if ($Once) {
            if (Test-ProxyReady $Port) { exit 0 } else { exit 1 }
        }
        $failStreak = 0
        Start-Sleep -Seconds $IntervalSec
    }
} finally {
    try { if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } } catch {}
    if ($owned -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
    if ($mutex) { try { $mutex.Dispose() } catch {} }
}

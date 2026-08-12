#Requires -Version 5.1
<#
.SYNOPSIS
  Start Grok with the full token-saving stack (Headroom proxy + rtk + caveman).

.DESCRIPTION
  From any directory:
    start-grok
    start-grok -m grok-build          # override model (skips default grok-via-headroom)
    start-grok -NoProxy               # skip Headroom proxy (MCP + rtk + caveman only)
    start-grok -ProxyOnly             # only ensure proxy is up, do not launch grok
    start-grok -StopProxy             # stop background Headroom proxy and exit
    start-grok -Status                # print stack status and exit
#>
[CmdletBinding()]
param(
    [switch]$NoProxy,
    [switch]$ProxyOnly,
    [switch]$StopProxy,
    [switch]$Status,
    [switch]$NoOutputShaper,   # deprecated/ignored (kept for compat)
    [switch]$UseOutputShaper,  # opt-in: enables HEADROOM_OUTPUT_SHAPER (can cause repeats)
    [switch]$SkipRtk,          # skip ensure-rtk (not recommended)
    [int]$Port = 8787,
    [int]$ProxyWaitSeconds = 45,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GrokArgs
)

$ErrorActionPreference = 'Stop'

$GrokHome      = Join-Path $env:USERPROFILE '.grok'
$TokenRoot     = Join-Path $GrokHome 'token-saving'
$VenvScripts   = Join-Path $TokenRoot 'venv\Scripts'
$HeadroomExe   = Join-Path $VenvScripts 'headroom.exe'
$GrokExe       = Join-Path $GrokHome 'bin\grok.exe'
$GrokBin       = Join-Path $GrokHome 'bin'
$HeadroomBin   = Join-Path $env:USERPROFILE '.headroom\bin'
$EnsureRtkPs1  = Join-Path $TokenRoot 'scripts\ensure-rtk.ps1'
$StateDir      = Join-Path $TokenRoot 'state'
$LogDir        = Join-Path $TokenRoot 'logs'
$ProxyPidFile  = Join-Path $StateDir 'headroom-proxy.pid'
$ProxyLog      = Join-Path $LogDir 'headroom-proxy.log'
$ProxyErrLog   = Join-Path $LogDir 'headroom-proxy.err.log'
$CavemanFlag   = Join-Path $GrokHome '.caveman-active'
$XaiUpstream   = if ($env:OPENAI_TARGET_API_URL) { $env:OPENAI_TARGET_API_URL } else { 'https://api.x.ai/v1' }

function Write-Info([string]$msg)  { Write-Host "[start-grok] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)    { Write-Host "[start-grok] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg)  { Write-Host "[start-grok] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)   { Write-Host "[start-grok] $msg" -ForegroundColor Red }

function Test-PortListening([int]$p) {
    try {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        return $null -ne $c
    } catch {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect('127.0.0.1', $p, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(400)
            if ($ok -and $client.Connected) { $client.Close(); return $true }
            $client.Close(); return $false
        } catch { return $false }
    }
}

function Get-ProxyPid {
    if (-not (Test-Path $ProxyPidFile)) { return $null }
    $raw = (Get-Content $ProxyPidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $raw) { return $null }
    $procId = 0
    if (-not [int]::TryParse($raw, [ref]$procId)) { return $null }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $null }
    return $procId
}

function Ensure-Dirs { New-Item -ItemType Directory -Force -Path $StateDir, $LogDir | Out-Null }

function Ensure-Caveman {
    if (-not (Test-Path $CavemanFlag)) {
        Set-Content -Path $CavemanFlag -Value 'ultra' -Encoding utf8 -NoNewline
    }
    $level = (Get-Content $CavemanFlag -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $level) {
        Set-Content -Path $CavemanFlag -Value 'ultra' -Encoding utf8 -NoNewline
        $level = 'ultra'
    }
    return $level
}

function Ensure-Path {
    $parts = @(
        $GrokBin,
        $HeadroomBin,
        $VenvScripts,
        (Join-Path $env:USERPROFILE '.local\bin'),
        (Join-Path $GrokHome 'vibe-tools\venv\Scripts'),
        'C:\Program Files\GitHub CLI'
    )
    foreach ($p in $parts) {
        if ($p -and (Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
            $env:PATH = "$p;$env:PATH"
        }
    }
}

function Ensure-Rtk {
    if ($SkipRtk) { return $null }
    if (Test-Path $EnsureRtkPs1) {
        try {
            & $EnsureRtkPs1 -Quiet 2>$null | Out-Null
        } catch {
            Write-Warn "ensure-rtk failed: $_"
        }
    }
    Ensure-Path
    $cmd = Get-Command rtk -ErrorAction SilentlyContinue
    if ($cmd) {
        try { return (& $cmd.Source --version 2>&1 | Select-Object -First 1) } catch { return $cmd.Source }
    }
    foreach ($c in @(
        (Join-Path $GrokBin 'rtk.exe'),
        (Join-Path $HeadroomBin 'rtk.exe')
    )) {
        if (Test-Path $c) {
            try { return (& $c --version 2>&1 | Select-Object -First 1) } catch { return $c }
        }
    }
    return $null
}

function Stop-HeadroomProxy {
    Ensure-Dirs
    $stopped = $false
    $proxyPid = Get-ProxyPid
    if ($proxyPid) {
        Write-Info "Stopping Headroom proxy PID $proxyPid ..."
        Stop-Process -Id $proxyPid -Force -ErrorAction SilentlyContinue
        $stopped = $true
    }
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            if ($c.OwningProcess) {
                $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                if ($p -and ($p.ProcessName -match 'headroom|python')) {
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                    $stopped = $true
                }
            }
        }
    } catch {}
    Remove-Item $ProxyPidFile -Force -ErrorAction SilentlyContinue
    if ($stopped) { Write-Ok "Proxy stopped." } else { Write-Warn "No Headroom proxy was running." }
}

function Show-Status {
    Ensure-Dirs
    Ensure-Path
    $caveman = Ensure-Caveman
    $rtkVer = Ensure-Rtk
    $listening = Test-PortListening $Port
    $proxyPid = Get-ProxyPid
    $headroomOk = Test-Path $HeadroomExe
    $grokOk = Test-Path $GrokExe

    Write-Host ""
    Write-Host "=== start-grok status ===" -ForegroundColor Cyan
    Write-Host "grok.exe:     $(if ($grokOk) { $GrokExe } else { 'MISSING' })"
    Write-Host "headroom:     $(if ($headroomOk) { & $HeadroomExe -v 2>&1 } else { 'MISSING' })"
    Write-Host "rtk:          $(if ($rtkVer) { $rtkVer } else { 'MISSING — run ensure-rtk.ps1' })"
    Write-Host "caveman:      $caveman (always-on via ~/.grok/rules)"
    Write-Host "proxy port:   $Port listening=$(if ($listening) { 'yes' } else { 'no' }) pid=$(if ($proxyPid) { $proxyPid } else { '-' })"
    Write-Host "proxy log:    $ProxyLog"
    Write-Host "MCP:          configured in ~/.grok/config.toml (Grok starts mcp serve)"
    Write-Host "model:        grok-via-headroom (grok-4.5) -> http://127.0.0.1:$Port/v1"
    Write-Host "proxy flags:  MAX savings profile (token + lossless + code-aware + intercept + ratio 0.35)"
    Write-Host "context tool: rtk (auto-enforce hook + HEADROOM_CONTEXT_TOOL=rtk)"
    Write-Host "XAI_API_KEY:  $(if ($env:XAI_API_KEY) { 'set' } else { 'not set (session login / auth.json may still work)' })"
    Write-Host ""
}

function Start-HeadroomProxyIfNeeded {
    Ensure-Dirs
    Ensure-Path

    if (-not (Test-Path $HeadroomExe)) {
        throw "headroom.exe not found at $HeadroomExe"
    }

    if (Test-PortListening $Port) {
        $proxyPid = Get-ProxyPid
        Write-Ok "Headroom proxy already up on port $Port$(if ($proxyPid) { " (pid $proxyPid)" })."
        return
    }

    Write-Info "Starting Headroom proxy on 127.0.0.1:$Port ..."
    Write-Info "Upstream: $XaiUpstream"

    # Do NOT set HEADROOM_OUTPUT_SHAPER by default - can cause output loops/repetition.
    # Opt-in: start-grok -UseOutputShaper
    if ($UseOutputShaper) { $env:HEADROOM_OUTPUT_SHAPER = '1' }
    $env:OPENAI_TARGET_API_URL = $XaiUpstream
    $env:PATH = "$VenvScripts;$env:PATH"

    # --- MAX token-savings env (quality-safe for coding agents) ---
    # coding profile features + more aggressive keep-ratio than stock 0.55.
    # Avoid --memory/--learn (re-inject loops with caveman). Avoid agent-90 (too lossy on system).
    $env:HEADROOM_SAVINGS_PROFILE = 'coding'
    $env:HEADROOM_MODE = 'token'
    $env:HEADROOM_TARGET_RATIO = '0.35'
    $env:HEADROOM_SAVINGS_TARGET = '0.65'
    $env:HEADROOM_MIN_TOKENS = '25'
    $env:HEADROOM_MAX_ITEMS = '12'
    $env:HEADROOM_PROTECT_RECENT = '2'
    $env:HEADROOM_PROTECT_ANALYSIS_CONTEXT = '1'
    $env:HEADROOM_COMPRESS_USER_MESSAGES = '1'
    $env:HEADROOM_COMPRESS_SYSTEM_MESSAGES = '0'
    $env:HEADROOM_SMART_CRUSHER_COMPACTION = '1'
    $env:HEADROOM_FORCE_KOMPRESS = '0'
    $env:HEADROOM_ACCURACY_GUARD = 'strict'
    $env:HEADROOM_TOOL_SEARCH = '1'
    $env:HEADROOM_DEDUPE = '1'
    $env:HEADROOM_LOSSLESS_THEN_LOSSY = '1'
    $env:HEADROOM_PROTECT_READS = '1'
    $env:HEADROOM_CODE_AWARE_ENABLED = '1'
    $env:HEADROOM_LOSSLESS = '1'
    $env:HEADROOM_EFFORT_ROUTER = '0'
    $env:HEADROOM_CONTEXT_TOOL = 'rtk'
    # Hold large file reads then crush once quiet (extra savings on long sessions)
    $env:HEADROOM_READ_MATURATION = '1'

    foreach ($f in @($ProxyLog, $ProxyErrLog)) {
        if ((Test-Path $f) -and ((Get-Item $f).Length -gt 5MB)) {
            Move-Item $f ("{0}.bak" -f $f) -Force -ErrorAction SilentlyContinue
        }
    }

    # --memory / --learn off: re-injection loops with caveman.
    # --lossless + code-aware + intercept: keep code/tool fidelity while crushing bulk.
    # --target-ratio 0.35: keep ~35% of crushable prose (was 0.55).
    # --no-ccr-proactive-expansion: do not re-inflate compressed history.
    # --read-maturation: delay/crush stale Read payloads.
    $argList = @(
        'proxy',
        '--host', '127.0.0.1',
        '--port', "$Port",
        '--openai-api-url', $XaiUpstream,
        '--mode', 'token',
        '--lossless',
        '--code-aware',
        '--intercept-tool-results',
        '--target-ratio', '0.35',
        '--no-ccr-proactive-expansion',
        '--read-maturation'
    )

    $proc = Start-Process -FilePath $HeadroomExe `
        -ArgumentList $argList `
        -WorkingDirectory $TokenRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $ProxyLog `
        -RedirectStandardError $ProxyErrLog `
        -PassThru

    Set-Content -Path $ProxyPidFile -Value $proc.Id -Encoding ascii -NoNewline
    Write-Info "Proxy PID $($proc.Id) - waiting up to ${ProxyWaitSeconds}s ..."

    $deadline = (Get-Date).AddSeconds($ProxyWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            $err = Get-Content $ProxyErrLog -ErrorAction SilentlyContinue | Select-Object -Last 30
            $out = Get-Content $ProxyLog -ErrorAction SilentlyContinue | Select-Object -Last 15
            throw "Headroom proxy exited early (code $($proc.ExitCode)).`n--- stderr ---`n$($err -join "`n")`n--- stdout ---`n$($out -join "`n")"
        }
        if (Test-PortListening $Port) {
            Write-Ok "Headroom proxy ready on http://127.0.0.1:$Port"
            return
        }
        Start-Sleep -Milliseconds 400
    }
    throw "Timed out waiting for Headroom proxy on port $Port. Check $ProxyErrLog"
}

function Resolve-GrokExe {
    if (Test-Path $GrokExe) { return $GrokExe }
    $cmd = Get-Command grok -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "grok.exe not found. Expected $GrokExe or grok on PATH."
}

# --- main ---
Ensure-Dirs
Ensure-Path
$cavemanLevel = Ensure-Caveman
$rtkVer = Ensure-Rtk
# Headroom proxy labels/metrics for the CLI context tool
$env:HEADROOM_CONTEXT_TOOL = if ($env:HEADROOM_CONTEXT_TOOL) { $env:HEADROOM_CONTEXT_TOOL } else { 'rtk' }

if ($Status) { Show-Status; exit 0 }
if ($StopProxy) { Stop-HeadroomProxy; exit 0 }

Write-Info "Caveman level: $cavemanLevel (rules + skills auto-load)"
Write-Info "RTK:           $(if ($rtkVer) { $rtkVer } else { 'not found — shell compression limited' })"
Write-Info "Token rules:   ~/.grok/rules/token-efficiency.md + rtk.md"
Write-Info "Headroom MCP:  enabled in config (Grok spawns on session start)"

if (-not $NoProxy) {
    Start-HeadroomProxyIfNeeded
} else {
    Write-Warn "Skipping Headroom proxy (-NoProxy). Caveman + rtk + MCP still apply when Grok starts."
}

if ($ProxyOnly) {
    Show-Status
    Write-Ok "Proxy-only done. Run: start-grok   (or grok -m grok-via-headroom)"
    exit 0
}

$grok = Resolve-GrokExe
$launch = [System.Collections.Generic.List[string]]::new()

if (-not $NoProxy) {
    $hasModel = $false
    if ($GrokArgs) {
        for ($i = 0; $i -lt $GrokArgs.Count; $i++) {
            if ($GrokArgs[$i] -eq '-m' -or $GrokArgs[$i] -eq '--model' -or $GrokArgs[$i] -like '-m=*' -or $GrokArgs[$i] -like '--model=*') {
                $hasModel = $true; break
            }
        }
    }
    if (-not $hasModel) {
        $launch.Add('-m'); $launch.Add('grok-via-headroom')
    }
}

if ($GrokArgs) { foreach ($a in $GrokArgs) { $launch.Add($a) } }

Write-Ok "Launching: $grok $($launch -join ' ')"
Write-Host ""

$argString = ($launch | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
}) -join ' '

& $grok @($launch.ToArray())
exit $LASTEXITCODE
#Requires -Version 5.1
<#
.SYNOPSIS
  Start Grok with the full token-saving stack (Headroom proxy + rtk + caveman).

.DESCRIPTION
  From any directory:
    start-grok
    start-grok -m grok-build          # override model (skips default grok-4.6 / Headroom)
    start-grok -m grok-4.6-direct     # vanilla Grok 4.6, no Headroom proxy
    start-grok -NoProxy               # skip Headroom proxy (MCP + rtk + caveman only)
    start-grok -ProxyOnly             # only ensure proxy is up, do not launch grok
    start-grok -ProxyOnly -Port 8788 -NoLogonKeeper  # dedicated review proxy
    start-grok -StopProxy             # stop keeper + Headroom proxy and exit
    start-grok -StopProxy -Port 8788  # stop the review proxy only (chat :8787 stays)
    start-grok -Status                # print stack status and exit
#>
[CmdletBinding()]
param(
    [switch]$NoProxy,
    [switch]$ProxyOnly,
    [switch]$StopProxy,
    [switch]$NoLogonKeeper,  # session keeper only (gate :8788 never registers a logon task)
    [switch]$Status,
    [switch]$Quiet,
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
# :8787 keeps legacy names so existing chat keepers still find the files.
$portTag = if ($Port -eq 8787) { '' } else { "-$Port" }
$ProxyPidFile  = Join-Path $StateDir "headroom-proxy$portTag.pid"
$ProxyFpFile   = Join-Path $StateDir "headroom-proxy$portTag.fingerprint"
$KeeperPidFile = Join-Path $StateDir "headroom-keeper$portTag.pid"
$KeepPs1       = Join-Path $TokenRoot 'scripts\keep-headroom-proxy.ps1'
$ProxyLog      = Join-Path $LogDir "headroom-proxy$portTag.log"
$ProxyErrLog   = Join-Path $LogDir "headroom-proxy$portTag.err.log"
$KeeperTask    = if ($Port -eq 8787) { 'GrokVibeStack-HeadroomKeeper' } else { "GrokVibeStack-HeadroomKeeper-$Port" }
$CavemanFlag   = Join-Path $GrokHome '.caveman-active'
$GrokTomlPs1   = Join-Path $TokenRoot 'scripts\GrokToml.ps1'
if (Test-Path -LiteralPath $GrokTomlPs1) { . $GrokTomlPs1 }
$ListenProbePs1 = Join-Path $TokenRoot 'scripts\ListenProbe.ps1'
if (-not (Test-Path -LiteralPath $ListenProbePs1)) { $ListenProbePs1 = Join-Path $PSScriptRoot 'ListenProbe.ps1' }
if (Test-Path -LiteralPath $ListenProbePs1) { . $ListenProbePs1 }
# Upstream: session login (auth.json) uses cli-chat-proxy.grok.com.
# api.x.ai needs XAI_API_KEY — without it the proxy 401s and the TUI sits on
# "waiting for response". OPENAI_TARGET_API_URL is an explicit override only
# when it is NOT leftover api.x.ai (old start-grok wrote that onto the grok child).
# Bump fingerprint prefix when stack CLI flags change so stale proxies restart.
# hr=<version> forces restart after pip upgrade. Headroom 0.35 502'd Grok
# /v1/responses SSE (TUI "Retrying"); 0.36 adapts those 200 streams.
# --read-maturation (beta) and --intercept-tool-results (canary) dropped:
# 0.36 stable aborts if those flags are set.
# --no-http2: Grok SSE cancel + HTTP/2 can hang. --no-rate-limit: default 60rpm
# stalls a tool-heavy agent (TUI "waiting for response").

function Write-Info([string]$msg)  { if ($Quiet) { return }; Write-Host "[start-grok] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)    { if ($Quiet) { return }; Write-Host "[start-grok] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg)  { if ($Quiet) { return }; Write-Host "[start-grok] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)   { Write-Host "[start-grok] $msg" -ForegroundColor Red }

function Test-HeadroomUrlIsXai([string]$url) {
    if (-not $url) { return $false }
    return [bool]($url -match '(?i)api\.x\.ai')
}

function Resolve-HeadroomUpstream {
    $raw = $env:OPENAI_TARGET_API_URL
    if ($raw) { $raw = $raw.Trim().TrimEnd('/') }
    # Stale OPENAI_TARGET_API_URL=api.x.ai without XAI_API_KEY is not an override (401 hang).
    if ($raw -and -not (Test-HeadroomUrlIsXai $raw)) { return $raw }
    if ($env:XAI_API_KEY) { return 'https://api.x.ai/v1' }
    return 'https://cli-chat-proxy.grok.com/v1'
}

function Get-HeadroomUpstreamHost {
    $u = Resolve-HeadroomUpstream
    try { return ([Uri]$u).Host } catch { return 'unknown' }
}

function Test-PortListening([int]$p) {
    # Local listen table (IPHlp). Get-NetTCPConnection / CIM hang for minutes.
    # No connect => no Close hang, no leaked ESTABLISHED sockets on keeper polls.
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($e in $listeners) {
            if ($e.Port -ne $p) { continue }
            if ([System.Net.IPAddress]::IsLoopback($e.Address)) { return $true }
            if ($e.Address.Equals([System.Net.IPAddress]::Any)) { return $true }
            if ($e.Address.Equals([System.Net.IPAddress]::IPv6Any)) { return $true }
        }
    } catch {}
    return $false
}

function Get-ProxyPid {
    if (-not (Test-Path $ProxyPidFile)) { return $null }
    $raw = (Get-Content $ProxyPidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $raw) { return $null }
    $procId = 0
    if (-not [int]::TryParse($raw, [ref]$procId)) { return $null }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $null }
    # PID reuse after reboot: only trust a live Headroom cmdline.
    if (Get-Command Test-ProxyProcessOk -ErrorAction SilentlyContinue) {
        if (-not (Test-ProxyProcessOk $procId)) {
            Remove-Item $ProxyPidFile -Force -ErrorAction SilentlyContinue
            return $null
        }
    }
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

function Get-HeadroomCliVersion {
    if (-not (Test-Path -LiteralPath $HeadroomExe)) { return 'unknown' }
    try {
        $raw = & $HeadroomExe -v 2>&1 | Out-String
        if ($raw -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    } catch {}
    return 'unknown'
}

function Get-ProxyStackFingerprintBase {
    return ('v3|hr={0}|mode=token|ratio=0.35|lossless|code-aware|no-ccr|no-http2|no-rl|up={1}' -f (Get-HeadroomCliVersion), (Get-HeadroomUpstreamHost))
}

function Get-ExpectedProxyFingerprint {
    return ("{0}|port={1}" -f (Get-ProxyStackFingerprintBase), $Port)
}

function Test-ProxyHttpReady([int]$p) {
    # HttpClient honors Timeout. PS 5.1 Invoke-WebRequest -TimeoutSec can hang
    # for minutes while Headroom is busy on SSE (that froze gate preflight).
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch {}
    foreach ($path in @('/readyz', '/health', '/livez')) {
        $client = $null
        try {
            $client = New-Object System.Net.Http.HttpClient
            $client.Timeout = [TimeSpan]::FromSeconds(1)
            $resp = $client.GetAsync(('http://127.0.0.1:{0}{1}' -f $p, $path)).GetAwaiter().GetResult()
            if ($resp -and [int]$resp.StatusCode -ge 200 -and [int]$resp.StatusCode -lt 300) { return $true }
        } catch {}
        finally { if ($client) { try { $client.Dispose() } catch {} } }
    }
    return $false
}

function Save-ProxyFingerprint {
    Ensure-Dirs
    Set-Content -Path $ProxyFpFile -Value (Get-ExpectedProxyFingerprint) -Encoding ascii -NoNewline
}

function Get-ProcessCommandLine([int]$procId) {
    try {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -OperationTimeoutSec 3 -ErrorAction SilentlyContinue
        if ($wmi -and $wmi.CommandLine) { return [string]$wmi.CommandLine }
    } catch {}
    return $null
}

function Get-ListenOwnerPids([int]$p) {
    # CIM Headroom `--port N` plus netstat LISTENING PIDs (ListenProbe.ps1).
    # Get-NetTCPConnection can block for minutes — never on this path.
    if (Get-Command Get-VibeListenOwnerPids -ErrorAction SilentlyContinue) {
        return @(Get-VibeListenOwnerPids -Port $p)
    }
    return @()
}

function Test-IsDescendantOf([int]$ancestorId, [int]$procId) {
    if ($ancestorId -le 0 -or $procId -le 0) { return $false }
    $cur = $procId
    for ($i = 0; $i -lt 16; $i++) {
        if ($cur -eq $ancestorId) { return $true }
        $w = $null
        try {
            $w = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        } catch { return $false }
        if (-not $w -or -not $w.ParentProcessId) { return $false }
        $cur = [int]$w.ParentProcessId
        if ($cur -le 0) { return $false }
    }
    return $false
}

function Test-ProxyCommandLineIsHeadroom([string]$cmdLine) {
    # Loose: our Headroom proxy on this port (any flag generation). Used to stop stale stacks.
    if ([string]::IsNullOrWhiteSpace($cmdLine)) { return $false }
    if ($cmdLine -notmatch '(?i)headroom') { return $false }
    if ($cmdLine -notmatch '(?i)(\s|^)proxy(\s|$)') { return $false }
    if ($cmdLine -notmatch ("(?i)--port(\s|=)+{0}(\s|$)" -f $Port)) { return $false }
    return $true
}

function Test-ProxyCommandLineMatchesStack([string]$cmdLine) {
    # Live argv must look like our headroom proxy stack (not any python on the port).
    if ([string]::IsNullOrWhiteSpace($cmdLine)) { return $false }
    if ($cmdLine -notmatch '(?i)headroom') { return $false }
    if ($cmdLine -notmatch '(?i)(\s|^)proxy(\s|$)') { return $false }
    # Bare 'token' matches token-saving\venv\...; require the flag pair.
    if ($cmdLine -notmatch '(?i)--mode(\s+|=)token(\s|$)') { return $false }
    $needles = @(
        '--lossless',
        '--code-aware',
        '--target-ratio',
        '0.35',
        '--no-ccr-proactive-expansion',
        '--no-http2',
        '--no-rate-limit',
        '--openai-api-url'
    )
    foreach ($n in $needles) {
        if ($cmdLine -notlike "*$n*") { return $false }
    }
    # Port must appear (as --port N or bound in args)
    if ($cmdLine -notmatch ("(?i)--port(\s|=)+{0}(\s|$)" -f $Port)) { return $false }
    return $true
}

function Test-ProxyProcessOk([int]$procId) {
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $false }
    $name = [string]$proc.ProcessName
    if ($name -notmatch '(?i)headroom|python|pythonw') {
        # Still allow if cmdline clearly is headroom (renamed binary edge case)
        $cl = Get-ProcessCommandLine $procId
        if (-not $cl -or $cl -notmatch '(?i)headroom') { return $false }
    }
    $cmdLine = Get-ProcessCommandLine $procId
    return (Test-ProxyCommandLineMatchesStack $cmdLine)
}

function Clear-StaleProxyFingerprint {
    Remove-Item $ProxyFpFile -Force -ErrorAction SilentlyContinue
}

function Test-ProxyMatchesStack {
    # Port listening is not enough: TCP owner must be our Start-Process PID (or a
    # verified Headroom argv) and the fingerprint file must match this stack.
    if (-not (Test-PortListening $Port)) {
        Clear-StaleProxyFingerprint
        return $false
    }

    $expected = Get-ExpectedProxyFingerprint
    $fp = $null
    if (Test-Path $ProxyFpFile) {
        $fp = (Get-Content $ProxyFpFile -Raw -ErrorAction SilentlyContinue).Trim()
    }
    if (-not $fp -or $fp -ne $expected) {
        return $false
    }

    $recordedPid = $null
    if (Test-Path $ProxyPidFile) {
        $raw = (Get-Content $ProxyPidFile -Raw -ErrorAction SilentlyContinue).Trim()
        $tmp = 0
        if ([int]::TryParse($raw, [ref]$tmp)) { $recordedPid = $tmp }
    }

    $ownerPids = [System.Collections.Generic.List[int]]::new()
    foreach ($op in @(Get-ListenOwnerPids $Port)) {
        if (-not $ownerPids.Contains($op)) { [void]$ownerPids.Add($op) }
    }
    if ($null -ne $recordedPid -and (Get-Process -Id $recordedPid -ErrorAction SilentlyContinue)) {
        if (-not $ownerPids.Contains([int]$recordedPid)) {
            $ownerPids.Insert(0, [int]$recordedPid)
        }
    }

    if ($ownerPids.Count -eq 0) { return $false }

    # recordedPid is a hint only. A leftover/reused PID file must not reject
    # a live Headroom listener — adopt the verified owner and rewrite the file.
    $ordered = [System.Collections.Generic.List[int]]::new()
    if ($null -ne $recordedPid -and $ownerPids.Contains([int]$recordedPid)) {
        [void]$ordered.Add([int]$recordedPid)
    }
    foreach ($op in $ownerPids) {
        if (-not $ordered.Contains($op)) { [void]$ordered.Add($op) }
    }
    foreach ($op in $ordered) {
        if (-not (Test-ProxyProcessOk $op)) { continue }
        Set-Content -Path $ProxyPidFile -Value $op -Encoding ascii -NoNewline
        return $true
    }

    # Listeners exist but none are our Headroom PID + argv.
    Clear-StaleProxyFingerprint
    return $false
}

function Test-KeeperCommandLineForThisPort([string]$cl) {
    if (-not $cl -or $cl -notmatch 'keep-headroom-proxy') { return $false }
    if ($cl -match ("-Port\s+$Port(?!\d)")) { return $true }
    if ($Port -eq 8787 -and $cl -notmatch '-Port\s+\d+') { return $true }
    return $false
}

function Test-HeadroomKeeperRunning {
    if (-not (Test-Path -LiteralPath $KeeperPidFile)) { return $false }
    $raw = (Get-Content $KeeperPidFile -Raw -ErrorAction SilentlyContinue).Trim()
    $kid = 0
    if (-not [int]::TryParse($raw, [ref]$kid) -or $kid -le 0) { return $false }
    $proc = Get-Process -Id $kid -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    return (Test-KeeperCommandLineForThisPort (Get-ProcessCommandLine $kid))
}

function Stop-HeadroomKeeper {
    # Never disable or kill the other port's keeper (chat :8787 vs gate :8788).
    if ($Port -eq 8787) {
        try {
            Disable-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }
    if (Test-Path -LiteralPath $KeeperPidFile) {
        $raw = (Get-Content $KeeperPidFile -Raw -ErrorAction SilentlyContinue).Trim()
        $kid = 0
        if ([int]::TryParse($raw, [ref]$kid) -and $kid -gt 0) {
            if (Test-KeeperCommandLineForThisPort (Get-ProcessCommandLine $kid)) {
                Write-Info "Stopping Headroom keeper PID $kid (port $Port) ..."
                Stop-Process -Id $kid -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item $KeeperPidFile -Force -ErrorAction SilentlyContinue
    }
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { Test-KeeperCommandLineForThisPort $_.CommandLine } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Register-HeadroomKeeperTask {
    # Chat proxy only. A logon task for :8788 would fight the chat keeper and clobber nothing useful.
    if ($NoLogonKeeper -or $Port -ne 8787) { return }
    if (-not (Test-Path -LiteralPath $KeepPs1)) { return }
    try {
        $arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Port {1}' -f $KeepPs1, $Port
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $existing = Get-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue
        if ($existing) {
            Set-ScheduledTask -TaskName $KeeperTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
            try { Enable-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue | Out-Null } catch {}
        } else {
            Register-ScheduledTask -TaskName $KeeperTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
        }
    } catch {
        Write-Warn ("keeper scheduled task: {0}" -f $_.Exception.Message)
    }
}

function Start-HeadroomKeeper {
    if (-not (Test-Path -LiteralPath $KeepPs1)) {
        Write-Warn "keep-headroom-proxy.ps1 missing — proxy will not auto-restart"
        return
    }
    Register-HeadroomKeeperTask
    if (Test-HeadroomKeeperRunning) {
        Write-Ok "Headroom keeper already running."
        return
    }
    Write-Info "Starting Headroom keeper (auto-restart on death)..."
    $null = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $KeepPs1, '-Port', "$Port") `
        -WorkingDirectory $TokenRoot `
        -WindowStyle Hidden `
        -PassThru
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if (Test-HeadroomKeeperRunning) {
            Write-Ok "Headroom keeper up (pid $(Get-Content $KeeperPidFile -Raw -ErrorAction SilentlyContinue))"
            return
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Warn "Headroom keeper did not publish a pid in 8s (proxy still started)."
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
    foreach ($op in @(Get-ListenOwnerPids $Port)) {
        if ($proxyPid -and $op -eq [int]$proxyPid) { continue }
        # Loose Headroom argv — never kill a random python. Flag generation may be stale.
        $cl = Get-ProcessCommandLine $op
        if (Test-ProxyCommandLineIsHeadroom $cl) {
            Stop-Process -Id $op -Force -ErrorAction SilentlyContinue
            $stopped = $true
        }
    }
    Remove-Item $ProxyPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item $ProxyFpFile -Force -ErrorAction SilentlyContinue
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
    $fpOk = $false
    if ($listening) { $fpOk = Test-ProxyMatchesStack }
    $fpRaw = if (Test-Path $ProxyFpFile) { (Get-Content $ProxyFpFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '-' }
    Write-Host "proxy port:   $Port listening=$(if ($listening) { 'yes' } else { 'no' }) pid=$(if ($proxyPid) { $proxyPid } else { '-' }) stack_match=$(if ($fpOk) { 'yes' } else { 'no' })"
    Write-Host "proxy fp:     $fpRaw"
    Write-Host "proxy expect: $(Get-ExpectedProxyFingerprint)"
    Write-Host "proxy log:    $ProxyLog"
    $cfgPath = Join-Path $GrokHome 'config.toml'
    $cfgLine = 'config.toml missing (plain grok; run start-grok to repair or re-install)'
    if ((Test-Path -LiteralPath $cfgPath) -and (Test-GrokTomlHelperLoaded)) {
        $cfgCheck = Test-VibeToml -Raw (Read-Utf8NoBomFile -Path $cfgPath)
        if ($cfgCheck.Ok) {
            $cfgLine = 'ok (quoted grok-4.6 + grok-gate alias -> :8787, no duplicate tables)'
        } else {
            $cfgLine = ('INVALID: {0}' -f ($cfgCheck.Errors -join '; '))
        }
    } elseif (Test-Path -LiteralPath $cfgPath) {
        $cfgLine = 'present (GrokToml.ps1 missing; cannot validate)'
    }
    Write-Host "config.toml:  $cfgLine"
    Write-Host "MCP:          configured in ~/.grok/config.toml (Grok starts mcp serve)"
    $modelHint = if ($Port -eq 8787) { 'grok-4.6 (chat Headroom)' } else { 'grok-gate (review Headroom)' }
    Write-Host "model:        $modelHint -> http://127.0.0.1:$Port/v1"
    Write-Host "upstream:     $(Resolve-HeadroomUpstream)"
    Write-Host "proxy flags:  token + lossless + code-aware + ratio 0.35 + no-http2 + no-rate-limit"
    Write-Host "keeper:       $(if (Test-HeadroomKeeperRunning) { 'up (auto-restart)' } else { 'DOWN — start-grok -ProxyOnly' })"
    Write-Host "context tool: rtk (auto-enforce hook + HEADROOM_CONTEXT_TOOL=rtk)"
    Write-Host "XAI_API_KEY:  $(if ($env:XAI_API_KEY) { 'set (api.x.ai)' } else { 'not set — session auth via cli-chat-proxy.grok.com' })"
    Write-Host ""
}

function Start-HeadroomProxyIfNeeded {
    Ensure-Dirs
    Ensure-Path

    if (-not (Test-Path $HeadroomExe)) {
        throw "headroom.exe not found at $HeadroomExe"
    }

    if (Test-PortListening $Port) {
        if (Test-ProxyMatchesStack) {
            $proxyPid = Get-ProxyPid
            if (Test-PortListening $Port) {
                Write-Ok "Headroom proxy already up on port $Port$(if ($proxyPid) { " (pid $proxyPid)" }) [fingerprint ok]."
                return
            }
            # Busy SSE makes /readyz block. Killing this process is what hung the gate.
            Write-Warn "Port $Port matches stack but /readyz failed — leaving live proxy (busy SSE must not be killed)."
            return
        } else {
            Write-Warn "Port $Port is up but fingerprint/process does not match this stack — restarting proxy."
        }
        Stop-HeadroomProxy
        Start-Sleep -Milliseconds 500
        if (Test-PortListening $Port) {
            throw "Port $Port still in use after stop; free it or pass -Port <other>."
        }
    }

    $XaiUpstream = Resolve-HeadroomUpstream
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
    # --read-maturation is beta in Headroom 0.36 stable and aborts proxy start.
    # Old start-grok left HEADROOM_READ_MATURATION=1 in the parent env; that
    # still trips the gate. Clear unless the user opted into beta.
    if ($env:HEADROOM_ROLLOUT_CHANNEL -notmatch '^(beta|dev)$' -and $env:HEADROOM_UNSAFE_ALLOW_UNSTABLE_FEATURES -ne '1') {
        Remove-Item Env:HEADROOM_READ_MATURATION -ErrorAction SilentlyContinue
    }

    foreach ($f in @($ProxyLog, $ProxyErrLog)) {
        if ((Test-Path $f) -and ((Get-Item $f).Length -gt 5MB)) {
            Move-Item $f ("{0}.bak" -f $f) -Force -ErrorAction SilentlyContinue
        }
    }

    # --memory / --learn off: re-injection loops with caveman.
    # --lossless + code-aware: keep code fidelity while crushing bulk.
    # --target-ratio 0.35: keep ~35% of crushable prose (was 0.55).
    # --no-ccr-proactive-expansion: do not re-inflate compressed history.
    $argList = @(
        'proxy',
        '--host', '127.0.0.1',
        '--port', "$Port",
        '--openai-api-url', $XaiUpstream,
        '--mode', 'token',
        '--lossless',
        '--code-aware',
        '--target-ratio', '0.35',
        '--no-ccr-proactive-expansion',
        '--no-http2',
        '--no-rate-limit'
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
            Remove-Item $ProxyPidFile -Force -ErrorAction SilentlyContinue
            Remove-Item $ProxyFpFile -Force -ErrorAction SilentlyContinue
            $err = Get-Content $ProxyErrLog -ErrorAction SilentlyContinue | Select-Object -Last 30
            $out = Get-Content $ProxyLog -ErrorAction SilentlyContinue | Select-Object -Last 15
            throw "Headroom proxy exited early (code $($proc.ExitCode)).`n--- stderr ---`n$($err -join "`n")`n--- stdout ---`n$($out -join "`n")"
        }
        if (Test-PortListening $Port) {
            # pip's headroom.exe is a launcher: python child (or grandchild) bind()s
            # :8787. Start-Process PID is the wrapper - never require it == TCP owner.
            $owners = @(Get-ListenOwnerPids $Port)
            $adopted = $null
            if ($owners.Count -eq 0) {
                # Empty Listen / no OwningProcess / cmdlet-missing / race is not a mismatch.
                if (-not $proc.HasExited -and (Test-ProxyProcessOk $proc.Id)) {
                    $adopted = [int]$proc.Id
                }
            } else {
                foreach ($op in $owners) {
                    if ($op -eq [int]$proc.Id -and (Test-ProxyProcessOk $proc.Id)) {
                        $adopted = $op
                        break
                    }
                }
                if ($null -eq $adopted) {
                    foreach ($op in $owners) {
                        if (-not (Test-IsDescendantOf -AncestorId ([int]$proc.Id) -ProcId $op)) { continue }
                        if (Test-ProxyProcessOk $op) {
                            $adopted = $op
                            break
                        }
                    }
                }
            }
            if ($null -eq $adopted) {
                foreach ($op in $owners) {
                    $cl = Get-ProcessCommandLine $op
                    if (-not (Test-ProxyCommandLineIsHeadroom $cl)) { continue }
                    if (Test-PortListening $Port) {
                        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                        $adopted = $op
                        break
                    }
                }
            }
            if ($null -eq $adopted) {
                # CIM parent lag / leftover listener: wait, do not kill the new process yet.
                Start-Sleep -Milliseconds 400
                continue
            }
            Set-Content -Path $ProxyPidFile -Value $adopted -Encoding ascii -NoNewline
            if (Test-PortListening $Port) {
                Save-ProxyFingerprint
                Write-Ok "Headroom proxy ready on http://127.0.0.1:$Port (pid $adopted)"
                return
            }
            # Bound and owned, but /readyz not up yet — keep waiting.
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

function Test-GrokTomlHelperLoaded {
    return [bool](Get-Command Test-VibeToml -ErrorAction SilentlyContinue)
}

function Assert-GrokConfig {
    $cfg = Join-Path $GrokHome 'config.toml'
    if (-not (Test-GrokTomlHelperLoaded)) {
        Write-Warn "GrokToml.ps1 missing — launching grok anyway (Headroom model may be unwired). Re-run Install-GrokVibeStack.ps1."
        return
    }
    $raw = ''
    try {
        if (Test-Path -LiteralPath $cfg) {
            $raw = Read-Utf8NoBomFile -Path $cfg
        }
    } catch {
        Write-Warn ("config.toml read failed: {0}" -f $_.Exception.Message)
        $raw = ''
    }
    $check = if ($raw) { Test-VibeToml -Raw $raw } else {
        @{ Ok = $false; Errors = @('config.toml missing'); Duplicates = @(); HasHeadroomOverride = $false }
    }
    # Ok already requires HasHeadroomOverride + no dups. Check Headroom
    # explicitly so a parse-valid stub never skips Repair (bak prefer).
    if ($check.HasHeadroomOverride -and $check.Ok) { return }

    Write-Warn ("config.toml needs repair: {0}" -f ($check.Errors -join '; '))
    $snippet = Get-VibeConfigSnippetPath -TokenRoot $TokenRoot
    $hr = Join-Path $TokenRoot 'scripts\headroom-mcp-serve.cmd'
    $serena = Join-Path $env:USERPROFILE '.local\bin\serena.exe'
    $serenaOn = Test-Path -LiteralPath $serena
    if (-not $snippet) {
        Write-Warn "config-snippet.toml missing — launching grok anyway. Re-run Install-GrokVibeStack.ps1."
        return
    }
    try {
        $result = Repair-GrokConfigFile -ConfigPath $cfg -SnippetPath $snippet -HeadroomCmd $hr -SerenaExe $serena -SerenaEnabled $serenaOn -BackupSuffix ("startgrok-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        if ($result.Quarantined) {
            Write-Ok ("Repaired ~/.grok/config.toml (source {0}). Sidecar moved to {1}" -f $result.SourcePath, $result.Quarantined)
        } else {
            Write-Ok "Repaired ~/.grok/config.toml (Headroom override restored, user settings kept). Backup under ~/.grok/relocations/"
        }
        return
    } catch {
        Write-Warn ("config repair failed: {0}" -f $_.Exception.Message)
    }
    try {
        $snipText = Get-VibeManagedSnippet -SnippetPath $snippet -HeadroomCmd $hr -SerenaExe $serena -SerenaEnabled $serenaOn
        $fallback = Repair-TomlUnsafeCommandPaths -Raw (Merge-VibeToml -Raw '' -Snippet $snipText)
        if (Test-Path -LiteralPath $cfg) {
            $null = Backup-VibeConfigFile -ConfigPath $cfg -BackupSuffix ("startgrok-fallback-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        }
        $dir = Split-Path -Parent $cfg
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Write-Utf8NoBomFile -Path $cfg -Content $fallback
        Write-Ok "Wrote fallback config.toml (snippet only) so grok can start"
    } catch {
        Write-Warn ("fallback config write failed: {0} — launching grok anyway (delete config.toml if grok refuses to start)" -f $_.Exception.Message)
    }
}

# --- main ---
Ensure-Dirs
Ensure-Path
$cavemanLevel = Ensure-Caveman
$rtkVer = Ensure-Rtk
# Headroom proxy labels/metrics for the CLI context tool
$env:HEADROOM_CONTEXT_TOOL = if ($env:HEADROOM_CONTEXT_TOOL) { $env:HEADROOM_CONTEXT_TOOL } else { 'rtk' }

# Repair before Status so `start-grok -Status` is truthful after a Grok rewrite.
if (-not $StopProxy) {
    Assert-GrokConfig
}

if ($Status) { Show-Status; exit 0 }
if ($StopProxy) { Stop-HeadroomKeeper; Stop-HeadroomProxy; exit 0 }

Write-Info "Caveman level: $cavemanLevel (rules + skills auto-load)"
Write-Info "RTK:           $(if ($rtkVer) { $rtkVer } else { 'not found — shell compression limited' })"
Write-Info "Token rules:   ~/.grok/rules/token-efficiency.md + rtk.md"
Write-Info "Headroom MCP:  on by default in config (optional off: [mcp_servers.headroom] enabled = false)"

if (-not $NoProxy) {
    Start-HeadroomProxyIfNeeded
    Start-HeadroomKeeper
} else {
    Write-Warn "Skipping Headroom proxy (-NoProxy). Caveman + rtk + MCP still apply when Grok starts."
}

if ($ProxyOnly) {
    if (-not $Quiet) {
        Show-Status
        Write-Ok "Proxy-only done. Run: start-grok   (or grok -m grok-4.6)"
    }
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
        $launch.Add('-m'); $launch.Add('grok-4.6')
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
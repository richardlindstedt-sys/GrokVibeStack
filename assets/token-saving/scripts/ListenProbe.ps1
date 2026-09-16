# Shared listen + owner helpers for doctor / start-grok.
# Never call Get-NetTCPConnection (can block for minutes).

function Test-VibePortListening {
    param([int]$Port)
    if ($Port -le 0) { return $false }
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($e in $listeners) {
            if ($e.Port -eq $Port) { return $true }
        }
    } catch {}
    return $false
}

function Get-VibeListenSocketPids {
    param([int]$Port)
    $ids = New-Object 'System.Collections.Generic.List[int]'
    if ($Port -le 0) { return $ids }
    try {
        if (-not ('VibeListenTable3' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class VibeListenTable3 {
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool sort, int ipVersion, int tableClass, uint reserved);
    const int AF_INET = 2;
    const int AF_INET6 = 23;
    const int TCP_TABLE_OWNER_PID_LISTENER = 3;
    const int TCP_TABLE_OWNER_PID_ALL = 5;
    const uint ERROR_INSUFFICIENT_BUFFER = 122;
    static void Collect(int port, int ipVersion, int tableClass, int rowSize, int portOffset, int pidOffset, List<int> found) {
        int len = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref len, false, ipVersion, tableClass, 0);
        if (len <= 0) return;
        for (int attempt = 0; attempt < 4; attempt++) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                uint rc = GetExtendedTcpTable(buf, ref len, false, ipVersion, tableClass, 0);
                if (rc == ERROR_INSUFFICIENT_BUFFER) continue;
                if (rc != 0) return;
                int count = Marshal.ReadInt32(buf);
                IntPtr row = IntPtr.Add(buf, 4);
                for (int i = 0; i < count; i++) {
                    IntPtr r = IntPtr.Add(row, i * rowSize);
                    uint localPort = unchecked((uint)Marshal.ReadInt32(r, portOffset));
                    int lp = (int)(((localPort & 0xFF) << 8) | ((localPort >> 8) & 0xFF));
                    int pid = Marshal.ReadInt32(r, pidOffset);
                    if (lp == port && pid > 0 && !found.Contains(pid)) found.Add(pid);
                }
                return;
            } finally { Marshal.FreeHGlobal(buf); }
        }
    }
    public static int[] PidsOnPort(int port) {
        var found = new List<int>();
        if (port <= 0 || port > 65535) return found.ToArray();
        Collect(port, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 24, 8, 20, found);
        Collect(port, AF_INET, TCP_TABLE_OWNER_PID_ALL, 24, 8, 20, found);
        Collect(port, AF_INET6, TCP_TABLE_OWNER_PID_LISTENER, 56, 20, 52, found);
        Collect(port, AF_INET6, TCP_TABLE_OWNER_PID_ALL, 56, 20, 52, found);
        return found.ToArray();
    }
}
'@
        }
        foreach ($id in @([VibeListenTable3]::PidsOnPort($Port))) {
            if ($id -gt 0 -and -not $ids.Contains([int]$id)) { [void]$ids.Add([int]$id) }
        }
    } catch {
        # P/Invoke or Add-Type failed: fall through to netstat.
    }
    if ($ids.Count -eq 0) {
        foreach ($id in @(Get-VibeListenSocketPidsViaNetstat -Port $Port)) {
            if ($id -gt 0 -and -not $ids.Contains([int]$id)) { [void]$ids.Add([int]$id) }
        }
    }
    return $ids
}

function Get-VibeListenSocketPidsViaNetstat {
    param([int]$Port)
    $found = New-Object 'System.Collections.Generic.List[int]'
    if ($Port -le 0) { return $found }
    $raw = $null
    try {
        $raw = & netstat.exe -ano -p tcp 2>$null
    } catch { return $found }
    $rx = [regex]('(?i)^\s*TCP\s+\S+[:.]' + [regex]::Escape([string]$Port) + '\s+\S+\s+LISTENING\s+(\d+)\s*$')
    foreach ($line in @($raw)) {
        $m = $rx.Match([string]$line)
        if (-not $m.Success) { continue }
        $sockPid = 0
        if ([int]::TryParse($m.Groups[1].Value, [ref]$sockPid) -and $sockPid -gt 0 -and -not $found.Contains($sockPid)) {
            [void]$found.Add($sockPid)
        }
    }
    return $found
}

function Test-VibeHeadroomOwnerCandidate {
    param(
        [string]$CommandLine,
        [string]$Name,
        [string]$ExecutablePath,
        [int]$Port,
        [bool]$SocketOwnsPort
    )
    $isHeadroomBin = ($Name -match '(?i)^headroom(\.exe)?$') -or ($ExecutablePath -match '(?i)[\\/]headroom(\.exe)?$')
    $isPy = ($Name -match '(?i)^python(w)?(\.exe)?$') -or ($ExecutablePath -match '(?i)[\\/]python(w)?(\.exe)?$')
    $isProxyProc = $isHeadroomBin -or $isPy
    $cl = [string]$CommandLine
    $clEmpty = [string]::IsNullOrWhiteSpace($cl)
    $hasPort = ($Port -gt 0) -and ($cl -match ("(?i)--port(\s|=)+{0}(\s|$)" -f $Port))
    $hasHeadroom = $cl -match '(?i)headroom'
    $hasProxy = $cl -match '(?i)(\s|^)proxy(\s|$)'
    $hasAnyPortFlag = $cl -match '(?i)--port(\s|=)+\d+'
    # Socket + python/headroom.bin only for empty CIM or truncated Headroom argv
    # (no --port, and headroom.exe or word "proxy"). A complete python CL whose
    # path merely contains "headroom" is not the proxy.
    if ($SocketOwnsPort -and $isProxyProc) {
        if ($clEmpty) { return $true }
        if (-not $hasAnyPortFlag -and ($isHeadroomBin -or $hasProxy)) { return $true }
    }
    if ($clEmpty) { return $false }
    if (-not $hasHeadroom) { return $false }
    if ($hasProxy -and $hasPort) { return $true }
    return $false
}

function Test-VibeProxyStackUp {
    param([int]$Port)
    if (-not (Test-VibePortListening -Port $Port)) { return $false }
    $owners = @(Get-VibeListenOwnerPids -Port $Port)
    return ($owners.Count -gt 0)
}

function Get-VibeListenOwnerPids {
    param([int]$Port)
    $owners = New-Object 'System.Collections.Generic.List[int]'
    if ($Port -le 0) { return $owners }
    $sockSet = @{}
    foreach ($s in @(Get-VibeListenSocketPids -Port $Port)) {
        $sockSet[[int]$s] = $true
    }
    try {
        $filter = "Name = 'headroom.exe' OR Name = 'python.exe' OR Name = 'pythonw.exe'"
        $procs = @(Get-CimInstance Win32_Process -Filter $filter -OperationTimeoutSec 3 -ErrorAction SilentlyContinue)
        foreach ($w in $procs) {
            $id = 0
            try { $id = [int]$w.ProcessId } catch { continue }
            if ($id -le 0) { continue }
            $ownsSock = [bool]$sockSet.ContainsKey($id)
            if (-not (Test-VibeHeadroomOwnerCandidate -CommandLine ([string]$w.CommandLine) -Name ([string]$w.Name) -ExecutablePath ([string]$w.ExecutablePath) -Port $Port -SocketOwnsPort $ownsSock)) {
                continue
            }
            if (-not $owners.Contains($id)) { [void]$owners.Add($id) }
        }
    } catch {}
    return $owners
}

function Test-VibeKeeperAlive {
    param(
        [int]$Port,
        [string]$PidFile
    )
    if ($Port -le 0 -or [string]::IsNullOrWhiteSpace($PidFile)) { return $false }
    if (-not (Test-Path -LiteralPath $PidFile)) { return $false }
    $kr = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue)
    if (-not $kr) { return $false }
    $kr = $kr.Trim()
    $kid = 0
    if (-not [int]::TryParse($kr, [ref]$kid) -or $kid -le 0) { return $false }
    $kp = Get-Process -Id $kid -ErrorAction SilentlyContinue
    if (-not $kp) { return $false }
    $kcl = ''
    try {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$kid" -OperationTimeoutSec 3 -ErrorAction SilentlyContinue
        if ($wmi -and $wmi.CommandLine) { $kcl = [string]$wmi.CommandLine }
    } catch {}
    if (-not ($kcl -and $kcl -match 'keep-headroom-proxy')) { return $false }
    if ($kcl -match ("-Port\s+$Port(?!\d)")) { return $true }
    if ($Port -eq 8787 -and $kcl -notmatch '-Port\s+\d+') { return $true }
    return $false
}

function Resolve-VibeProxyAdoptPid {
    <#
      Empty owner list: only a socket PID that is the wrapper or a descendant AND in OkPids.
      Never adopt the wrapper just because the port is up.
      Missing/non-int PIDs are skipped (fail closed).
    #>
    param(
        [int]$WrapperPid,
        [int[]]$SocketPids,
        [int[]]$OwnerPids,
        [int[]]$OkPids,
        [int[]]$DescendantPids
    )
    if ($WrapperPid -le 0) { return $null }
    $ok = @{}
    foreach ($x in @($OkPids)) {
        $n = 0
        try { $n = [int]$x } catch { continue }
        if ($n -gt 0) { $ok[$n] = $true }
    }
    $desc = @{}
    foreach ($x in @($DescendantPids)) {
        $n = 0
        try { $n = [int]$x } catch { continue }
        if ($n -gt 0) { $desc[$n] = $true }
    }
    $socks = New-Object 'System.Collections.Generic.List[int]'
    foreach ($x in @($SocketPids)) {
        $n = 0
        try { $n = [int]$x } catch { continue }
        if ($n -gt 0 -and -not $socks.Contains($n)) { [void]$socks.Add($n) }
    }
    $owners = New-Object 'System.Collections.Generic.List[int]'
    foreach ($x in @($OwnerPids)) {
        $n = 0
        try { $n = [int]$x } catch { continue }
        if ($n -gt 0 -and -not $owners.Contains($n)) { [void]$owners.Add($n) }
    }
    $consider = {
        param([int]$id)
        if ($id -le 0) { return $false }
        if (-not $ok.ContainsKey($id)) { return $false }
        if ($id -eq $WrapperPid) { return $true }
        if ($desc.ContainsKey($id)) { return $true }
        return $false
    }
    if ($owners.Count -eq 0) {
        foreach ($sid in $socks) {
            if (& $consider $sid) { return $sid }
        }
        return $null
    }
    foreach ($op in $owners) {
        if ($op -eq $WrapperPid -and $ok.ContainsKey($op)) { return $op }
    }
    foreach ($op in $owners) {
        if ($desc.ContainsKey($op) -and $ok.ContainsKey($op)) { return $op }
    }
    return $null
}

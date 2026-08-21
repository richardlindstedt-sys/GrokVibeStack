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
        if (-not ('VibeListenTable2' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class VibeListenTable2 {
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool sort, int ipVersion, int tableClass, uint reserved);
    const int AF_INET = 2;
    const int AF_INET6 = 23;
    const int TCP_TABLE_OWNER_PID_LISTENER = 3;
    const uint ERROR_INSUFFICIENT_BUFFER = 122;
    static void Collect(int port, int ipVersion, int rowSize, int portOffset, int pidOffset, List<int> found) {
        int len = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref len, false, ipVersion, TCP_TABLE_OWNER_PID_LISTENER, 0);
        if (len <= 0) return;
        for (int attempt = 0; attempt < 4; attempt++) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                uint rc = GetExtendedTcpTable(buf, ref len, false, ipVersion, TCP_TABLE_OWNER_PID_LISTENER, 0);
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
        Collect(port, AF_INET, 24, 8, 20, found);
        Collect(port, AF_INET6, 56, 20, 52, found);
        return found.ToArray();
    }
}
'@
        }
        foreach ($id in @([VibeListenTable2]::PidsOnPort($Port))) {
            if ($id -gt 0 -and -not $ids.Contains([int]$id)) { [void]$ids.Add([int]$id) }
        }
    } catch {
        # P/Invoke or Add-Type failed: no socket PIDs (fail closed for owner/adopt).
    }
    return $ids
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
    # Socket + headroom/python only when CIM is empty or truncated (no --port at all).
    # A complete non-headroom CL (python -m http.server) is not the proxy.
    if ($SocketOwnsPort -and $isProxyProc) {
        if ($clEmpty) { return $true }
        if ($hasHeadroom -and -not $hasAnyPortFlag) { return $true }
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

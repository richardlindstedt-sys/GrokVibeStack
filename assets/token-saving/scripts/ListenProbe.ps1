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
        if (-not ('VibeListenTable' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class VibeListenTable {
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool sort, int ipVersion, int tableClass, uint reserved);
    [StructLayout(LayoutKind.Sequential)]
    struct Row {
        public uint state;
        public uint localAddr;
        public uint localPort;
        public uint remoteAddr;
        public uint remotePort;
        public uint owningPid;
    }
    public static int[] PidsOnPort(int port) {
        var found = new List<int>();
        if (port <= 0 || port > 65535) return found.ToArray();
        int len = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref len, false, 2, 3, 0);
        if (len <= 0) return found.ToArray();
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            if (GetExtendedTcpTable(buf, ref len, false, 2, 3, 0) != 0) return found.ToArray();
            int count = Marshal.ReadInt32(buf);
            int rowSize = Marshal.SizeOf(typeof(Row));
            IntPtr row = IntPtr.Add(buf, 4);
            for (int i = 0; i < count; i++) {
                var r = (Row)Marshal.PtrToStructure(IntPtr.Add(row, i * rowSize), typeof(Row));
                int lp = (int)(((r.localPort & 0xFF) << 8) | ((r.localPort >> 8) & 0xFF));
                if (lp == port && r.owningPid > 0 && !found.Contains((int)r.owningPid))
                    found.Add((int)r.owningPid);
            }
        } finally { Marshal.FreeHGlobal(buf); }
        return found.ToArray();
    }
}
'@
        }
        foreach ($id in @([VibeListenTable]::PidsOnPort($Port))) {
            if ($id -gt 0 -and -not $ids.Contains([int]$id)) { [void]$ids.Add([int]$id) }
        }
    } catch {}
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
    $isPy = $Name -match '(?i)^python(w)?(\.exe)?$'
    $isProxyProc = $isHeadroomBin -or $isPy
    # Socket owner on $Port + headroom/python is enough (empty or truncated CIM cmdline).
    if ($SocketOwnsPort -and $isProxyProc) { return $true }
    $cl = [string]$CommandLine
    if ([string]::IsNullOrWhiteSpace($cl)) { return $false }
    if ($cl -notmatch '(?i)headroom') { return $false }
    $hasProxy = $cl -match '(?i)(\s|^)proxy(\s|$)'
    $hasPort = ($Port -gt 0) -and ($cl -match ("(?i)--port(\s|=)+{0}(\s|$)" -f $Port))
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

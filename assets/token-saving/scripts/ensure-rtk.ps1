#Requires -Version 5.1
<#
.SYNOPSIS
  Ensure RTK (Rust Token Killer) is installed and on PATH for the token-saving stack.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$GrokHome    = Join-Path $env:USERPROFILE '.grok'
$GrokBin     = Join-Path $GrokHome 'bin'
$HeadroomBin = Join-Path $env:USERPROFILE '.headroom\bin'
$VenvPy      = Join-Path $GrokHome 'token-saving\venv\Scripts\python.exe'
$RtkName     = 'rtk.exe'

function Write-Msg([string]$msg, [string]$color = 'Cyan') {
    if (-not $Quiet) { Write-Host "[ensure-rtk] $msg" -ForegroundColor $color }
}

function Find-Rtk {
    foreach ($dir in @($GrokBin, $HeadroomBin)) {
        $p = Join-Path $dir $RtkName
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command rtk -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

New-Item -ItemType Directory -Force -Path $GrokBin, $HeadroomBin | Out-Null

$rtk = Find-Rtk
if (-not $rtk) {
    if (-not (Test-Path $VenvPy)) {
        Write-Msg "headroom venv python missing; cannot auto-install rtk" 'Yellow'
        exit 1
    }
    Write-Msg "Downloading rtk via headroom installer..."
    & $VenvPy -c "from headroom.rtk.installer import ensure_rtk; p=ensure_rtk(); print(p or '')"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $rtk = Find-Rtk
}

if (-not $rtk) {
    Write-Msg "rtk install failed" 'Red'
    exit 1
}

# Keep a copy on the Grok PATH shim dir.
$grokRtk = Join-Path $GrokBin $RtkName
if ($rtk -ne $grokRtk) {
    try {
        Copy-Item -Path $rtk -Destination $grokRtk -Force
        $rtk = $grokRtk
    } catch {
        Write-Msg "Could not copy rtk to $grokRtk ($_); using $rtk" 'Yellow'
    }
}

# Prepend managed bins for this process (and any child started after).
foreach ($p in @($GrokBin, $HeadroomBin)) {
    if ($env:PATH -notlike "*$p*") {
        $env:PATH = "$p;$env:PATH"
    }
}

$ver = & $rtk --version 2>&1
Write-Msg "ok: $ver ($rtk)" 'Green'
if ($Quiet) { Write-Output $rtk }
exit 0

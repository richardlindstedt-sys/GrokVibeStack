#Requires -Version 5.1
<#
.SYNOPSIS
  Fail-soft wrapper for serena-hooks.exe under Grok hooks.

.DESCRIPTION
  Always prints a single-line JSON decision to stdout for PreToolUse so Grok
  does not count the hook as failed. Uses [Console]::Out only (no Write-Host).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('remind', 'cleanup', 'activate', 'auto-approve')]
    [string]$Action,

    [string]$Client = 'grok'
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Emit([string]$json) {
    [Console]::Out.Write($json)
    if (-not $json.EndsWith("`n")) { [Console]::Out.Write("`n") }
    [Console]::Out.Flush()
}

function Emit-Allow { Emit '{"decision":"allow"}'; exit 0 }
function Emit-OkStop { exit 0 }

# Read stdin fully (Grok hook event JSON)
$raw = ''
try {
    $raw = [Console]::In.ReadToEnd()
} catch {}

if ([string]::IsNullOrWhiteSpace($raw)) {
    if ($Action -eq 'cleanup') { Emit-OkStop }
    Emit-Allow
}

$exe = $null
foreach ($c in @(
        (Join-Path $env:USERPROFILE '.local\bin\serena-hooks.exe')
        (Join-Path $env:USERPROFILE '.local\bin\serena-hooks.cmd')
    )) {
    if (Test-Path -LiteralPath $c) { $exe = $c; break }
}
if (-not $exe) {
    $cmd = Get-Command serena-hooks -ErrorAction SilentlyContinue
    if ($cmd) { $exe = $cmd.Source }
}
if (-not $exe) {
    if ($Action -eq 'cleanup') { Emit-OkStop }
    Emit-Allow
}

try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "$Action --client=$Client"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $p.StandardInput.Write($raw)
    $p.StandardInput.Close()
    $stdout = $p.StandardOutput.ReadToEnd()
    $null = $p.StandardError.ReadToEnd()
    if (-not $p.WaitForExit(12000)) {
        try { $p.Kill() } catch {}
        if ($Action -eq 'cleanup') { Emit-OkStop }
        Emit-Allow
    }

    $out = if ($null -eq $stdout) { '' } else { $stdout.Trim() }
    if ($Action -eq 'cleanup') {
        # Stop hooks: empty success is fine; never dump noise
        Emit-OkStop
    }

    if ($out -match '^\s*\{') {
        # Pass through first JSON object line-ish
        Emit $out
        exit 0
    }

    Emit-Allow
} catch {
    if ($Action -eq 'cleanup') { Emit-OkStop }
    Emit-Allow
}

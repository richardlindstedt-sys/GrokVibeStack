#Requires -Version 5.1
<#
.SYNOPSIS
  Opt-in: install Serena remind/cleanup Grok hooks (OFF by default).

.DESCRIPTION
  Default stack does NOT install these. Serena MCP still works without them.
  The remind PreToolUse fires on every read_file/grep and historically caused
  Grok UI "hooks: N failed" noise when allow is silent.

  This installer uses run-serena-hook.ps1 (always emits decision JSON).
  After running: in Grok TUI  /hooks  then  r
#>
[CmdletBinding()]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$hooksDir = Join-Path $env:USERPROFILE '.grok\hooks'
$wrap = Join-Path $env:USERPROFILE '.grok\token-saving\scripts\run-serena-hook.ps1'
$out = Join-Path $hooksDir 'serena-hooks.json'
$exe = Join-Path $env:USERPROFILE '.local\bin\serena-hooks.exe'

if ($Remove) {
    if (Test-Path -LiteralPath $out) {
        Remove-Item -LiteralPath $out -Force
        Write-Host "Removed $out"
    } else {
        Write-Host "No serena-hooks.json present"
    }
    Write-Host "Reload: /hooks then r"
    exit 0
}

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Error "serena-hooks.exe not found at $exe"
}
if (-not (Test-Path -LiteralPath $wrap)) {
    Write-Error "wrapper missing: $wrap — re-run Install-GrokVibeStack.ps1"
}

New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
$remind = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrap`" -Action remind -Client grok"
$cleanup = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrap`" -Action cleanup -Client grok"
$obj = @{
    hooks = @{
        PreToolUse = @(@{
                matcher = 'grep|read_file|run_terminal_command'
                hooks   = @(@{
                        type    = 'command'
                        command = $remind
                        timeout = 15
                    })
            })
        Stop       = @(@{
                hooks = @(@{
                        type    = 'command'
                        command = $cleanup
                        timeout = 10
                    })
            })
    }
}
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($out, ($obj | ConvertTo-Json -Depth 12), $utf8)
Write-Host "Wrote $out"
Write-Host "REQUIRED: in Grok TUI run  /hooks  then press  r"
exit 0

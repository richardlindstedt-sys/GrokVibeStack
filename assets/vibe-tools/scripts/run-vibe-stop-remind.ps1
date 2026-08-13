#Requires -Version 5.1
<#
.SYNOPSIS
  Stop-hook reminder: only nag if code was edited this session (or VIBE_STOP_REMIND=1).
.DESCRIPTION
  Reads flag file written by run-vibe-on-edit.ps1. If present, prints a short reminder
  and clears the flag. Otherwise exits quietly. Fail-open always.
#>
$ErrorActionPreference = 'SilentlyContinue'

if ($env:VIBE_STOP_REMIND -eq '1' -or $env:VIBE_STOP_REMIND -eq 'always') {
    [Console]::Error.WriteLine('[vibe] Turn end - edits this session: confirm scans/review (vibe-review) before calling done.')
    exit 0
}

$flag = Join-Path $env:USERPROFILE '.grok\vibe-tools\state\edited-this-session.flag'
if (Test-Path -LiteralPath $flag) {
    [Console]::Error.WriteLine('[vibe] Turn end - you edited code: confirm on-edit clean / vibe-review before done.')
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
}
exit 0

#Requires -Version 5.1
<#
.SYNOPSIS
  Restore personal MCP connectors (mail/calendar/drive/tasks) disabled by the coding profile.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$StatePath = '',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
& (Join-Path $here 'Set-GrokMcpProfile.ps1') -Profile personal -ConfigPath $ConfigPath -StatePath $StatePath -DryRun:$DryRun
exit $LASTEXITCODE

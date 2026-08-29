#Requires -Version 5.1
<#
.SYNOPSIS
  Lean MCP for coding: Serena + Headroom only (disable mail/calendar/drive/tasks).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$StatePath = '',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
& (Join-Path $here 'Set-GrokMcpProfile.ps1') -Profile coding -ConfigPath $ConfigPath -StatePath $StatePath -DryRun:$DryRun
exit $LASTEXITCODE

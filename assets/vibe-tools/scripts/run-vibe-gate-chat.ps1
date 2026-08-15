#Requires -Version 5.1
<#
.SYNOPSIS
    PreToolUse: while a gate is live, clamp long waits so the agent cannot
    sit silent on a 2–5 minute get_command_or_subagent_output.
.DESCRIPTION
    Rewrites timeout_ms to 15000 when gate-now.txt is not GATE DONE.
    Fail-open. Does not deny the call.
#>
$ErrorActionPreference = 'SilentlyContinue'

function Write-Allow {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw) -and $input) { $raw = ($input | Out-String) }
if ([string]::IsNullOrWhiteSpace($raw)) { Write-Allow }

try { $evt = $raw | ConvertFrom-Json } catch { Write-Allow }

$tool = [string]($evt.toolName)
if (-not $tool) { $tool = [string]($evt.tool_name) }
if ($tool -notmatch 'get_command_or_subagent_output') { Write-Allow }

$nowFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt'
if (-not (Test-Path -LiteralPath $nowFile)) { Write-Allow }
$nowLine = @(Get-Content -LiteralPath $nowFile -TotalCount 8) | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1
if (-not $nowLine -or $nowLine -match 'GATE DONE') { Write-Allow }

$ti = $evt.toolInput
if (-not $ti) { $ti = $evt.tool_input }
if (-not $ti) { Write-Allow }

$ms = $null
try { $ms = [int]$ti.timeout_ms } catch { $ms = $null }
if ($null -eq $ms -or $ms -le 15000) { Write-Allow }

# PS 5.1 ConvertTo-Json unwraps one-element arrays (task_ids: ["id"] -> "id").
# Emit only timeout_ms; host merges updatedInput. Do not copy toolInput.
Write-Output '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"timeout_ms":15000}}}'
exit 0

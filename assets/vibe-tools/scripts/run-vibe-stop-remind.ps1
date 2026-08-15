#Requires -Version 5.1
<#
.SYNOPSIS
  Stop hook: keep the turn alive while a gate is live, and nag after edits.
.DESCRIPTION
  If gate-now.txt is not GATE DONE and this is a real end_turn, block (or
  keep-working) so the agent must post RUN/NOW/ELAPSED instead of going idle.
  Then the existing edit-session reminder. Fail-open.
#>
$ErrorActionPreference = 'SilentlyContinue'

function Write-Json([hashtable]$Obj) {
    Write-Output (($Obj | ConvertTo-Json -Compress -Depth 6))
}

function Invoke-EditRemind {
    if ($env:VIBE_STOP_REMIND -eq '1' -or $env:VIBE_STOP_REMIND -eq 'always') {
        [Console]::Error.WriteLine('[vibe] Turn end - edits this session: confirm scans/review (vibe-review) before calling done.')
        return
    }
    $flag = Join-Path $env:USERPROFILE '.grok\vibe-tools\state\edited-this-session.flag'
    $findingsFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\state\on-edit-findings.json'
    $hadFindings = Test-Path -LiteralPath $findingsFile
    if (Test-Path -LiteralPath $flag) {
        if ($hadFindings) {
            [Console]::Error.WriteLine('[vibe] Turn end - on-edit findings pending; next prompt will inject them. Fix before commit.')
        } else {
            [Console]::Error.WriteLine('[vibe] Turn end - you edited code: confirm on-edit clean / vibe-review before done.')
        }
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
}

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw) -and $input) { $raw = ($input | Out-String) }
$evt = $null
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try { $evt = $raw | ConvertFrom-Json } catch { $evt = $null }
}

$reason = ''
if ($evt) {
    $reason = [string]$evt.reason
    if (-not $reason) { $reason = [string]$evt.hookEventName }
}
# Session teardown / cancel: never block.
if ($reason -and $reason -ne 'end_turn' -and $reason -notmatch 'Stop$') {
    Invoke-EditRemind
    exit 0
}

$nowFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt'
if (($env:VIBE_GATE_STOP -ne '0') -and (Test-Path -LiteralPath $nowFile)) {
    $head = @(Get-Content -LiteralPath $nowFile -TotalCount 8)
    $run = ($head | Where-Object { $_ -match '^RUN:\s+\S+' } | Select-Object -First 1)
    $now = ($head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
    $elapsed = ($head | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
    $pidLine = ($head | Where-Object { $_ -match '^PID:\s+(\d+)' } | Select-Object -First 1)
    $gatePid = 0
    if ($pidLine -and $pidLine -match '^PID:\s+(\d+)') { $gatePid = [int]$Matches[1] }
    elseif ($run -and $run -match '^RUN:\s+(\d+)-') { $gatePid = [int]$Matches[1] }
    $gateAlive = $false
    if ($gatePid -gt 0) { $gateAlive = $null -ne (Get-Process -Id $gatePid -ErrorAction SilentlyContinue) }
    if ($run -and $now -and $now -notmatch 'GATE DONE' -and $gateAlive) {
        $last = ''
        if ($evt) {
            $last = [string]$evt.lastAssistantMessage
            if (-not $last) { $last = [string]$evt.last_assistant_message }
        }
        $runId = ''
        if ($run -match '^RUN:\s+(\S+)') { $runId = $Matches[1] }
        $nowVal = $now -replace '^NOW:\s+', ''
        $spoke = ($runId -and $last.Contains($runId)) -or ($nowVal -and $last.Contains($nowVal))
        $snap = @"
GATE LIVE — do not go silent. Post this in chat, then poll gate-now (timeout_ms=15000):
$run
$now
$elapsed
Optional: start monitor on ~/.grok/vibe-tools/scripts/watch-gate-now.ps1 -Monitor
"@
        if (-not $spoke) {
            Write-Json @{
                decision = 'block'
                reason   = $snap
            }
            exit 0
        }
        Write-Json @{
            hookSpecificOutput = @{
                hookEventName     = 'Stop'
                additionalContext = $snap
            }
        }
        exit 0
    }
}

Invoke-EditRemind
exit 0

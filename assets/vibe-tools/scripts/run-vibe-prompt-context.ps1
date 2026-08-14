#Requires -Version 5.1
<#
.SYNOPSIS
    UserPromptSubmit: inject pending on-edit findings as additionalContext.
.DESCRIPTION
    PostToolUse stdout is ignored by Grok. On-edit writes a findings file;
    this hook feeds it back to the model on the next user prompt (Claude-style
    hookSpecificOutput.additionalContext). Does not block. Fail-open.
    Findings stay until on-edit reports clean (or file is older than 2h).
#>
$ErrorActionPreference = 'SilentlyContinue'

$findingsFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\state\on-edit-findings.json'
if (-not (Test-Path -LiteralPath $findingsFile)) { exit 0 }

try {
    $doc = Get-Content -LiteralPath $findingsFile -Raw | ConvertFrom-Json
} catch {
    exit 0
}

if (-not $doc -or [int]$doc.count -le 0) { exit 0 }

$when = $null
try { $when = [datetime]::Parse([string]$doc.at) } catch {}
if ($when -and ((Get-Date) - $when).TotalHours -gt 2) {
    Remove-Item -LiteralPath $findingsFile -Force -ErrorAction SilentlyContinue
    exit 0
}

$lines = @($doc.lines)
if ($lines.Count -eq 0) { exit 0 }

$body = ($lines | Select-Object -First 40) -join "`n"
if ($body.Length -gt 4000) { $body = $body.Substring(0, 4000) + "`n..." }

$msg = @"
ON-EDIT FINDINGS (advisory, edit was not blocked). Fix before commit:
$body
"@

$payload = @{
    hookSpecificOutput = @{
        hookEventName     = 'UserPromptSubmit'
        additionalContext = $msg
    }
} | ConvertTo-Json -Compress -Depth 6

[Console]::Out.WriteLine($payload)
exit 0

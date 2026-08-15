#Requires -Version 5.1
<#
.SYNOPSIS
    UserPromptSubmit: inject on-edit findings + live gate snapshot as additionalContext.
.DESCRIPTION
    PostToolUse stdout is ignored by Grok. This hook is the only reliable
    chat-side inject. Fail-open. Does not block.
#>
$ErrorActionPreference = 'SilentlyContinue'

$chunks = [System.Collections.Generic.List[string]]::new()

$nowFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-now.txt'
if (Test-Path -LiteralPath $nowFile) {
    $head = @(Get-Content -LiteralPath $nowFile -TotalCount 8)
    $run = ($head | Where-Object { $_ -match '^RUN:\s+\S+' } | Select-Object -First 1)
    $now = ($head | Where-Object { $_ -match '^NOW:\s+' } | Select-Object -First 1)
    $elapsed = ($head | Where-Object { $_ -match '^ELAPSED:' } | Select-Object -First 1)
    if ($run -and $now -and $now -notmatch 'GATE DONE') {
        [void]$chunks.Add(@"
GATE LIVE (do not stay silent — report this NOW line in chat, then poll again in ~15s):
$run
$now
$elapsed
"@)
    }
}

$findingsFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\state\on-edit-findings.json'
if (Test-Path -LiteralPath $findingsFile) {
    try {
        $doc = Get-Content -LiteralPath $findingsFile -Raw | ConvertFrom-Json
        $when = $null
        try { $when = [datetime]::Parse([string]$doc.at) } catch {}
        $fresh = (-not $when) -or (((Get-Date) - $when).TotalHours -le 2)
        if ($fresh -and $doc -and [int]$doc.count -gt 0) {
            $lines = @($doc.lines)
            if ($lines.Count -gt 0) {
                $body = ($lines | Select-Object -First 40) -join "`n"
                if ($body.Length -gt 4000) { $body = $body.Substring(0, 4000) + "`n..." }
                [void]$chunks.Add("ON-EDIT FINDINGS (advisory, edit was not blocked). Fix before commit:`n$body")
            }
        } elseif ($when -and ((Get-Date) - $when).TotalHours -gt 2) {
            Remove-Item -LiteralPath $findingsFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

if ($chunks.Count -eq 0) { exit 0 }

$msg = $chunks -join "`n`n"
$payload = @{
    hookSpecificOutput = @{
        hookEventName     = 'UserPromptSubmit'
        additionalContext = $msg
    }
} | ConvertTo-Json -Compress -Depth 6

[Console]::Out.WriteLine($payload)
exit 0

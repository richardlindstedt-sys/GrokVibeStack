# PostToolUse for shell: log large command outputs for local metrics.
$ErrorActionPreference = 'SilentlyContinue'

$logDir = Join-Path $env:USERPROFILE '.grok\token-saving\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'shell-post.jsonl'

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try { $evt = $raw | ConvertFrom-Json } catch { exit 0 }

$tool = $evt.toolName
$inputObj = $evt.toolInput
$cmd = if ($inputObj -and $inputObj.command) { [string]$inputObj.command } else { $null }

$resultLen = 0
foreach ($key in @('toolOutput', 'toolResult', 'output', 'result', 'response')) {
    if ($evt.PSObject.Properties.Name -contains $key -and $evt.$key) {
        $resultLen = ([string]$evt.$key).Length; break
    }
}

$entry = [ordered]@{
    ts        = (Get-Date -Format 'o')
    sessionId = $env:GROK_SESSION_ID
    tool      = $tool
    cmd       = if ($cmd -and $cmd.Length -gt 200) { $cmd.Substring(0, 200) + '...' } else { $cmd }
    resultLen = $resultLen
    large     = ($resultLen -gt 8000)
}

Add-Content -Path $logFile -Value ($entry | ConvertTo-Json -Compress)
exit 0
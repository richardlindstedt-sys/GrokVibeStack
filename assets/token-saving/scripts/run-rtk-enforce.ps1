#Requires -Version 5.1
<#
.SYNOPSIS
  PreToolUse gate: force rtk prefix on noisy shell commands (max token savings).
.DESCRIPTION
  Denies run_terminal_command / Bash when the command looks noisy and is not
  already wrapped with rtk. Fail-open on parse errors.
#>
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) {
    # Some hosts pass via pipeline variable
    if ($input) { $raw = ($input | Out-String) }
}
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Output '{"decision":"allow"}'
    exit 0
}

try {
    $evt = $raw | ConvertFrom-Json
} catch {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$tool = [string]($evt.toolName)
if (-not $tool) { $tool = [string]($evt.tool_name) }
if ($tool -notmatch '^(run_terminal_command|Bash|bash|shell)$') {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$cmd = $null
$ti = $evt.toolInput
if (-not $ti) { $ti = $evt.tool_input }
if ($ti -and $ti.command) { $cmd = [string]$ti.command }
if (-not $cmd) {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$trimmed = $cmd.Trim()

# Already using rtk / explicit bypass
if ($trimmed -match '(?i)(^|[;&|(\s])rtk(\.exe)?(\s|$)|RTK_BYPASS|NO_RTK') {
    Write-Output '{"decision":"allow"}'
    exit 0
}

# Always-allow tiny interactive commands (not noisy families)
if ($trimmed -match '(?i)^(cd|pwd|echo|cls|clear|whoami|hostname|exit|true|false)\b') {
    Write-Output '{"decision":"allow"}'
    exit 0
}

# Noisy families - must use rtk (even short commands like "git status")
$noisy = @(
    '(?i)\bgit\b',
    '(?i)\b(cargo|npm|pnpm|yarn|bun)\b',
    '(?i)\b(pytest|go\s+test|mvn|gradle|dotnet)\b',
    '(?i)\b(docker|podman|kubectl|helm|compose)\b',
    '(?i)\b(gh|glab)\b',
    '(?i)\b(rg|grep|findstr|find|fd|ag)\b',
    '(?i)\b(Get-ChildItem|gci|Get-Content|gc|ls|dir|tree|find\.exe)\b',
    '(?i)\b(trivy|gitleaks|semgrep|ruff|mypy|bandit|biome|eslint|jscpd|checkov|shellcheck|hadolint|vulture)\b',
    '(?i)\b(pip|pip3|uv)\b',
    '(?i)\b(headroom|vibe-review|run-vibe-scans|grok-ai-review)\b',
    '(?i)\b(tsc|prettier|markdownlint|eslint)\b',
    '(?i)\b(pytest|unittest|nosetests)\b',
    '(?i)\b(curl|wget|Invoke-WebRequest|Invoke-RestMethod)\b'
)

$hit = $false
foreach ($rx in $noisy) {
    if ($trimmed -match $rx) { $hit = $true; break }
}

if (-not $hit) {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$example = if ($trimmed.Length -gt 120) { $trimmed.Substring(0, 120) + '...' } else { $trimmed }
$reason = 'Token-save gate: prefix noisy shell with rtk. Example: rtk ' + $example + ' | bypass: RTK_BYPASS=1'
$reason = $reason.Replace('\', '\\').Replace('"', '\"')
$out = '{"decision":"deny","reason":"' + $reason + '"}'
Write-Output $out
exit 2

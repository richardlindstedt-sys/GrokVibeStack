#Requires -Version 5.1
<#
.SYNOPSIS
  PreToolUse gate: force rtk prefix on noisy shell commands (max token savings).
.DESCRIPTION
  Denies run_terminal_command / Bash when any shell segment looks noisy and is not
  already wrapped with rtk. Chains (&& || ; newline, bare &) are checked per segment so
  `rtk git status && git log -p` is denied. Fail-open on parse errors.
#>
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) {
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

# Env bypass for whole invocation
if ($env:RTK_BYPASS -eq '1' -or $env:NO_RTK -eq '1') {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$trimmed = $cmd.Trim()
if ($trimmed -match '(?i)\bRTK_BYPASS\b|\bNO_RTK\b') {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$noisy = @(
    '(?i)\bgit\b',
    '(?i)\b(cargo|npm|pnpm|yarn|bun)\b',
    '(?i)\b(pytest|go\s+test|mvn|gradle|dotnet)\b',
    '(?i)\b(docker|podman|kubectl|helm|compose)\b',
    '(?i)\b(gh|glab)\b',
    # search tools (no bare \bfind\b — false-positive on Find-*/path words)
    '(?i)\b(rg|grep|findstr|fd|ag)\b',
    '(?i)\bfind\.exe\b',
    '(?i)(?:^|[;&|(\s])find(?:\s|$)',
    '(?i)\b(Get-ChildItem|gci|Get-Content|gc|ls|dir|tree)\b',
    # code intel / size tools (token-efficiency prefers these — still compress output)
    '(?i)\b(sg|ast-grep|difft|tokei|scc|jq)\b',
    '(?i)\b(trivy|gitleaks|semgrep|ruff|mypy|bandit|biome|eslint|jscpd|checkov|shellcheck|hadolint|vulture)\b',
    '(?i)\b(pip|pip3|uv)\b',
    '(?i)\b(headroom|vibe-review|run-vibe-scans|grok-ai-review)\b',
    '(?i)\b(tsc|prettier|markdownlint|eslint)\b',
    '(?i)\b(pytest|unittest|nosetests)\b',
    '(?i)\b(curl|wget|Invoke-WebRequest|Invoke-RestMethod)\b'
)

function Test-IsTinyAllow([string]$seg) {
    return [bool]($seg -match '(?i)^(cd|pwd|echo|cls|clear|whoami|hostname|exit|true|false)\b')
}

function Test-IsNoisy([string]$seg) {
    foreach ($rx in $noisy) {
        if ($seg -match $rx) { return $true }
    }
    return $false
}

function Test-HasRtkPrefix([string]$seg) {
    # Allow leading env assignments (FOO=1) and common wrappers, then require rtk
    # before the noisy tool. Still rejects rtk only mid-pipeline after the tool.
    $s = $seg.Trim()
    # Leading call operator is not a splitter: "& rtk git status"
    if ($s -match '^&\s+\S') { $s = $s.Substring(1).TrimStart() }
    # Strip leading VAR=value / VAR='...' / VAR="..." (and export VAR=...)
    $guard = 0
    while ($guard -lt 32) {
        $guard++
        $m = [regex]::Match($s, '(?i)^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(?:''[^'']*''|"[^"]*"|\S+)\s+')
        if (-not $m.Success) { break }
        $s = $s.Substring($m.Length).TrimStart()
    }
    # Common soft wrappers that still invoke rtk as the real command
    $guard = 0
    while ($guard -lt 16 -and $s -match '(?i)^(command|env|nice|nohup|stdbuf|time|timeout)\b') {
        $guard++
        $before = $s
        # Consume wrapper + optional short flags; require progress or break (no hang)
        $m = [regex]::Match($s, '(?i)^(command|env|nice|nohup|stdbuf|time|timeout)(?:\s+-\S+)*(?:\s+|$)')
        if ($m.Success -and $m.Length -gt 0) {
            $s = $s.Substring($m.Length).TrimStart()
        } else {
            break
        }
        # env FOO=1 BAR=2 rtk ... — strip more assignments after env
        $inner = 0
        while ($inner -lt 32) {
            $inner++
            $em = [regex]::Match($s, '(?i)^([A-Za-z_][A-Za-z0-9_]*)=(?:''[^'']*''|"[^"]*"|\S+)\s+')
            if (-not $em.Success) { break }
            $s = $s.Substring($em.Length).TrimStart()
        }
        if ($s.Length -ge $before.Length) { break }
    }
    return [bool]($s -match '(?i)^rtk(\.exe)?(\s|$)')
}

function Split-ShellSegments([string]$command) {
    # Split on && || ; newline, and bare & (statement sep) outside quotes.
    # Residual: | pipelines, 2>&1 / >& / &> redirects, leading call-operator &,
    # backtick continuation, heredocs — not a full shell parse.
    $segments = [System.Collections.Generic.List[string]]::new()
    $sb = New-Object System.Text.StringBuilder
    $inSingle = $false
    $inDouble = $false
    $i = 0
    $len = $command.Length
    while ($i -lt $len) {
        $ch = $command[$i]
        $next = if ($i + 1 -lt $len) { $command[$i + 1] } else { [char]0 }
        $prev = if ($i -gt 0) { $command[$i - 1] } else { [char]0 }

        if ($ch -eq [char]39 -and -not $inDouble) { # '
            $inSingle = -not $inSingle
            [void]$sb.Append($ch)
            $i++; continue
        }
        if ($ch -eq [char]34 -and -not $inSingle) { # "
            $inDouble = -not $inDouble
            [void]$sb.Append($ch)
            $i++; continue
        }

        if (-not $inSingle -and -not $inDouble) {
            if ($ch -eq [char]13 -or $ch -eq [char]10) {
                $seg = $sb.ToString().Trim()
                if ($seg) { [void]$segments.Add($seg) }
                [void]$sb.Clear()
                if ($ch -eq [char]13 -and $next -eq [char]10) { $i += 2 } else { $i++ }
                continue
            }
            if ($ch -eq ';' ) {
                $seg = $sb.ToString().Trim()
                if ($seg) { [void]$segments.Add($seg) }
                [void]$sb.Clear()
                $i++; continue
            }
            if ($ch -eq '&' -and $next -eq '&') {
                $seg = $sb.ToString().Trim()
                if ($seg) { [void]$segments.Add($seg) }
                [void]$sb.Clear()
                $i += 2; continue
            }
            if ($ch -eq '|' -and $next -eq '|') {
                $seg = $sb.ToString().Trim()
                if ($seg) { [void]$segments.Add($seg) }
                [void]$sb.Clear()
                $i += 2; continue
            }
            if ($ch -eq '&') {
                $isRedirect = ($prev -eq '>') -or ($next -eq '>')
                $soFar = $sb.ToString()
                $isCallOp = [string]::IsNullOrWhiteSpace($soFar)
                if (-not $isRedirect -and -not $isCallOp) {
                    $seg = $soFar.Trim()
                    if ($seg) { [void]$segments.Add($seg) }
                    [void]$sb.Clear()
                    $i++; continue
                }
            }
        }

        [void]$sb.Append($ch)
        $i++
    }
    $tail = $sb.ToString().Trim()
    if ($tail) { [void]$segments.Add($tail) }
    if ($segments.Count -eq 0 -and $command.Trim()) {
        [void]$segments.Add($command.Trim())
    }
    return @($segments)
}

$badSeg = $null
foreach ($seg in @(Split-ShellSegments $trimmed)) {
    if (-not $seg) { continue }
    if (Test-IsTinyAllow $seg) { continue }
    if (Test-HasRtkPrefix $seg) { continue }
    if (Test-IsNoisy $seg) {
        $badSeg = $seg
        break
    }
}

if (-not $badSeg) {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$example = if ($badSeg.Length -gt 100) { $badSeg.Substring(0, 100) + '...' } else { $badSeg }
$reason = 'Token-save gate: each shell segment needs rtk if noisy. Bad segment: rtk ' + $example + ' | bypass: RTK_BYPASS=1'
$reason = $reason.Replace('\', '\\').Replace('"', '\"')
$out = '{"decision":"deny","reason":"' + $reason + '"}'
Write-Output $out
exit 2

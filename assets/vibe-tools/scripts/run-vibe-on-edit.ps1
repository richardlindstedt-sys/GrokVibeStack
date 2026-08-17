<#
.SYNOPSIS
    Fast post-edit gate for Grok PostToolUse (search_replace / write / Serena).
.DESCRIPTION
    Reads Grok hook JSON from stdin, finds the edited path, runs cheap checks:
    secret patterns, gitleaks on the file (if available), and language-aware linters
    when the file type matches. Never blocks the edit tool (fail-open for hooks);
    prints findings so the agent/user sees them in scrollback.
    Exit 0 always unless the script itself crashes hard.
    Findings merge per path so a clean edit of B does not drop a finding on A.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

foreach ($p in @(
    (Join-Path $env:USERPROFILE '.grok\vibe-tools\venv\Scripts'),
    (Join-Path $env:USERPROFILE '.local\bin'),
    (Join-Path $env:USERPROFILE '.grok\bin')
)) {
    if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
        $env:PATH = "$p;$env:PATH"
    }
}

$gateChatLib = Join-Path $PSScriptRoot 'gate-chat-lib.ps1'
if (Test-Path -LiteralPath $gateChatLib) { . $gateChatLib }

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }

try {
    $evt = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    exit 0
}

function Get-EditedPaths($inputObj) {
    $paths = [System.Collections.Generic.List[string]]::new()
    if (-not $inputObj) { return $paths }

    if ($inputObj -is [string]) {
        $s = $inputObj.Trim()
        if ($s.StartsWith('{') -or $s.StartsWith('[')) {
            try { $inputObj = $s | ConvertFrom-Json -ErrorAction Stop } catch { return $paths }
        } else {
            return $paths
        }
    }

    foreach ($key in @('path', 'file_path', 'target_file', 'filePath', 'file', 'relative_path')) {
        $v = $inputObj.$key
        if ($v -is [string] -and $v.Trim()) { [void]$paths.Add($v.Trim()) }
    }

    foreach ($arrKey in @('paths', 'edits')) {
        $arr = $inputObj.$arrKey
        if (-not $arr) { continue }
        foreach ($item in @($arr)) {
            if ($item -is [string] -and $item.Trim()) {
                [void]$paths.Add($item.Trim())
                continue
            }
            foreach ($k in @('path', 'file_path', 'target_file', 'filePath', 'file', 'relative_path')) {
                $v = $item.$k
                if ($v -is [string] -and $v.Trim()) { [void]$paths.Add($v.Trim()) }
            }
        }
    }

    $inner = $inputObj.tool_input
    if (-not $inner) { $inner = $inputObj.toolInput }
    if ($inner -and $inner -ne $inputObj) {
        foreach ($p in @(Get-EditedPaths $inner)) { [void]$paths.Add($p) }
    }

    $paths | Select-Object -Unique
}

function Protect-FindingLine([string]$Line) {
    if ([string]::IsNullOrEmpty($Line)) { return $Line }
    $s = $Line
    $s = $s -replace 'AKIA[0-9A-Z]{16}', 'AKIA[REDACTED]'
    $s = $s -replace 'ghp_[A-Za-z0-9]{20,}', 'ghp_[REDACTED]'
    $s = $s -replace 'github_pat_[A-Za-z0-9_]{20,}', 'github_pat_[REDACTED]'
    $s = $s -replace 'xox[baprs]-[A-Za-z0-9-]{10,}', 'xox[REDACTED]'
    $s = $s -replace '(?i)\bsk-[A-Za-z0-9]{20,}', 'sk-[REDACTED]'
    $s = $s -replace '(?i)\bxai-[A-Za-z0-9]{20,}', 'xai-[REDACTED]'
    $s = $s -replace '(?i)(api[_-]?key|secret|password|token)\s*[:=]\s*[''"][^''"]{8,}', '$1=[REDACTED]'
    $s = $s -replace '-----BEGIN [A-Z ]*PRIVATE KEY-----', '-----BEGIN [REDACTED] PRIVATE KEY-----'
    return $s
}

if (-not (Get-Command Get-VibeStateDir -ErrorAction SilentlyContinue)) {
    function Get-VibeStateDir {
        if (-not [string]::IsNullOrWhiteSpace($env:VIBE_STATE_DIR)) {
            return $env:VIBE_STATE_DIR.Trim()
        }
        return (Join-Path $env:USERPROFILE '.grok\vibe-tools\state')
    }
}

$toolName = [string]$evt.toolName
if (-not $toolName) { $toolName = [string]$evt.tool_name }
$toolInput = $evt.toolInput
if (-not $toolInput) { $toolInput = $evt.tool_input }

# use_tool fires for every MCP call — only scan Serena write tools.
if ($toolName -match '(?i)^use_tool$') {
    $innerName = [string]$toolInput.tool_name
    if (-not $innerName) { $innerName = [string]$toolInput.toolName }
    if ($innerName -notmatch '(?i)serena.*(replace|insert|write)') { exit 0 }
}

$edited = @(Get-EditedPaths $toolInput)
if ($edited.Count -eq 0) { exit 0 }

try {
    $stateDir = Get-VibeStateDir
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    }
    $flag = Join-Path $stateDir 'edited-this-session.flag'
    Set-Content -Path $flag -Value ((Get-Date -Format 'o') + "`n" + ($edited -join "`n")) -Encoding utf8
} catch {}

$root = if ($evt.workspaceRoot) { $evt.workspaceRoot } elseif ($evt.cwd) { $evt.cwd } else { (Get-Location).Path }
Push-Location $root

$findings = 0
$byFileNew = @{}
Write-Host ""
Write-Host "=== VIBE ON-EDIT (fast checks) ===" -ForegroundColor Cyan

foreach ($rel in $edited) {
    $fileHits = [System.Collections.Generic.List[string]]::new()
    $full = $rel
    if (-not [System.IO.Path]::IsPathRooted($rel)) {
        $full = Join-Path $root $rel
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Write-Host "  skip (missing): $rel" -ForegroundColor DarkGray
        $byFileNew[$rel] = @()
        continue
    }

    Write-Host "  file: $rel" -ForegroundColor Yellow
    $text = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) { $text = '' }

    $secretPatterns = @(
        @{ Name = 'AWS key';                 Rx = 'AKIA[0-9A-Z]{16}' },
        @{ Name = 'Private key';             Rx = '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----' },
        @{ Name = 'Generic token';           Rx = '(?i)(api[_-]?key|secret|password|token)\s*[:=]\s*[''"][^''"]{12,}' },
        @{ Name = 'GitHub PAT';              Rx = 'ghp_[A-Za-z0-9]{20,}' },
        @{ Name = 'GitHub fine-grained PAT'; Rx = 'github_pat_[A-Za-z0-9_]{20,}' },
        @{ Name = 'OpenAI/xAI key';          Rx = '(?i)\b(sk-|xai-)[A-Za-z0-9]{20,}' },
        @{ Name = 'Slack token';             Rx = 'xox[baprs]-[A-Za-z0-9-]{10,}' }
    )
    if ($text.Length -gt 0) {
        foreach ($sp in $secretPatterns) {
            if ($text -match $sp.Rx) {
                $msg = "[SECRET?] $($sp.Name) pattern in $rel"
                Write-Host "  $msg" -ForegroundColor Red
                [void]$fileHits.Add($msg)
                $findings++
            }
        }
    }

    if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
        $tmp = Join-Path $env:TEMP ("vibe-edit-{0}" -f [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            Copy-Item -LiteralPath $full -Destination (Join-Path $tmp (Split-Path $full -Leaf))
            $glReport = Join-Path $tmp 'gitleaks-report.json'
            & gitleaks detect --source $tmp --no-git --report-format json --report-path $glReport 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [gitleaks] finding(s) in $rel" -ForegroundColor Red
                [void]$fileHits.Add("[gitleaks] finding(s) in $rel")
                if (Test-Path -LiteralPath $glReport) {
                    try {
                        $hits = Get-Content -LiteralPath $glReport -Raw -ErrorAction Stop | ConvertFrom-Json
                        foreach ($h in @($hits) | Select-Object -First 8) {
                            $rule = $h.RuleID
                            if (-not $rule) { $rule = $h.rule }
                            if (-not $rule) { $rule = 'unknown' }
                            $ln = $h.StartLine
                            if (-not $ln) { $ln = $h.startLine }
                            if (-not $ln) { $ln = '?' }
                            $gmsg = "[gitleaks] rule=$rule line=$ln path=$rel"
                            Write-Host "    $gmsg" -ForegroundColor Red
                            [void]$fileHits.Add($gmsg)
                        }
                    } catch {}
                }
                $findings++
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()

    if ($ext -in @('.py') -and (Get-Command ruff -ErrorAction SilentlyContinue)) {
        & ruff check $full 2>&1 | ForEach-Object {
            Write-Host "  [ruff] $_"
            [void]$fileHits.Add("[ruff] $_")
        }
        if ($LASTEXITCODE -ne 0) { $findings++ }
    }

    if ($ext -in @('.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs', '.json') -and (Get-Command biome -ErrorAction SilentlyContinue)) {
        & biome check $full 2>&1 | ForEach-Object {
            Write-Host "  [biome] $_"
            [void]$fileHits.Add("[biome] $_")
        }
        if ($LASTEXITCODE -ne 0) { $findings++ }
    }

    if ($ext -eq '.ps1' -and (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
        $r = Invoke-ScriptAnalyzer -Path $full -Severity Error -ErrorAction SilentlyContinue
        if ($r) {
            $r | ForEach-Object {
                $msg = "[PSSA] $($_.RuleName):$($_.Line) $($_.Message)"
                Write-Host "  $msg" -ForegroundColor Yellow
                [void]$fileHits.Add($msg)
            }
            $findings++
        }
    }

    if ($ext -in @('.sh', '.bash') -and (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
        & shellcheck $full 2>&1 | ForEach-Object {
            Write-Host "  [shellcheck] $_"
            [void]$fileHits.Add("[shellcheck] $_")
        }
        if ($LASTEXITCODE -ne 0) { $findings++ }
    }

    $byFileNew[$rel] = @($fileHits)
}

if ($findings -gt 0) {
    Write-Host "ON-EDIT: $findings issue group(s). Fix before commit." -ForegroundColor Yellow
} else {
    Write-Host "ON-EDIT: clean (this file set)." -ForegroundColor Green
}
Write-Host ""

$stateDir = Get-VibeStateDir
$findingsFile = Join-Path $stateDir 'on-edit-findings.json'
try {
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    }
    $merged = @{}
    if (Test-Path -LiteralPath $findingsFile) {
        try {
            $prev = Get-Content -LiteralPath $findingsFile -Raw | ConvertFrom-Json
            if ($prev.byFile) {
                foreach ($p in $prev.byFile.PSObject.Properties) {
                    $merged[$p.Name] = @($p.Value)
                }
            } elseif ($prev.lines) {
                $merged['_prior'] = @($prev.lines)
            }
        } catch {}
    }
    foreach ($k in $byFileNew.Keys) {
        $merged[$k] = @($byFileNew[$k])
    }
    $allLines = [System.Collections.Generic.List[string]]::new()
    $keepFiles = [System.Collections.Generic.List[string]]::new()
    $outByFile = [ordered]@{}
    foreach ($k in $merged.Keys) {
        $safe = @($merged[$k] | ForEach-Object { Protect-FindingLine $_ } | Where-Object { $_ })
        if ($safe.Count -eq 0) { continue }
        $outByFile[$k] = $safe
        [void]$keepFiles.Add($k)
        foreach ($ln in $safe) { [void]$allLines.Add($ln) }
    }
    $safeLines = @($allLines | Select-Object -First 40)
    if ($safeLines.Count -gt 0) {
        $doc = [ordered]@{
            at     = (Get-Date -Format 'o')
            count  = $safeLines.Count
            files  = @($keepFiles)
            lines  = $safeLines
            byFile = $outByFile
        }
        ($doc | ConvertTo-Json -Compress -Depth 6) | Set-Content -Path $findingsFile -Encoding utf8
        $ctx = ("ON-EDIT FINDINGS (advisory):`n" + (($safeLines | Select-Object -First 20) -join "`n"))
        if ($ctx.Length -gt 3000) { $ctx = $ctx.Substring(0, 3000) }
        $payload = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $ctx } } | ConvertTo-Json -Compress -Depth 5
        [Console]::Out.WriteLine($payload)
    } else {
        if (Test-Path -LiteralPath $findingsFile) {
            Remove-Item -LiteralPath $findingsFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

Pop-Location
# PostToolUse is non-blocking; always allow the tool result through.
exit 0

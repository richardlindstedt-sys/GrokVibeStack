# Quick health check for the token-saving + vibe stack
$ErrorActionPreference = 'Continue'
$scripts = Join-Path $env:USERPROFILE '.grok\token-saving\venv\Scripts'
$grokBin = Join-Path $env:USERPROFILE '.grok\bin'
$grokHome = Join-Path $env:USERPROFILE '.grok'
$headroomBin = Join-Path $env:USERPROFILE '.headroom\bin'
$ensureRtk = Join-Path $env:USERPROFILE '.grok\token-saving\scripts\ensure-rtk.ps1'
$vibeRoot = Join-Path $grokHome 'vibe-tools'
$vibeScripts = Join-Path $vibeRoot 'scripts'
$reportsRoot = Join-Path $vibeRoot 'reports'
$cacheFile = Join-Path $vibeRoot 'cache\gate-pass-cache.json'
$env:PATH = "$grokBin;$headroomBin;$scripts;$env:PATH"
$headroom = Join-Path $scripts 'headroom.exe'
$cfg = Join-Path $grokHome 'config.toml'
$hooksDir = Join-Path $grokHome 'hooks'

if (Test-Path $ensureRtk) {
    & $ensureRtk -Quiet 2>$null | Out-Null
}

function Test-Port([int]$p) {
    try {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        return $null -ne $c
    } catch { return $false }
}

function Get-StatusColor([bool]$ok) {
    if ($ok) { 'Green' } else { 'Yellow' }
}

Write-Host "=== Token-saving / vibe doctor ===" -ForegroundColor Cyan
Write-Host "headroom: $(if (Test-Path $headroom) { & $headroom -v 2>&1 } else { 'MISSING' })"
Write-Host "ast-grep: $(if (Test-Path (Join-Path $scripts 'ast-grep.exe')) { & (Join-Path $scripts 'ast-grep.exe') --version 2>&1 } else { 'MISSING' })"
Write-Host "sg:       $(if (Test-Path (Join-Path $scripts 'sg.exe')) { & (Join-Path $scripts 'sg.exe') --version 2>&1 } else { 'MISSING' })"
$rtkCmd = Get-Command rtk -ErrorAction SilentlyContinue
if ($rtkCmd) {
    Write-Host "rtk:      $(& $rtkCmd.Source --version 2>&1) @ $($rtkCmd.Source)"
} elseif (Test-Path (Join-Path $grokBin 'rtk.exe')) {
    Write-Host "rtk:      $(& (Join-Path $grokBin 'rtk.exe') --version 2>&1) @ $grokBin\rtk.exe"
} else {
    Write-Host "rtk:      MISSING"
}
Write-Host "caveman:  $(Get-Content (Join-Path $grokHome '.caveman-active') -ErrorAction SilentlyContinue)"
Write-Host "HEADROOM_CONTEXT_TOOL: $(if ($env:HEADROOM_CONTEXT_TOOL) { $env:HEADROOM_CONTEXT_TOOL } else { 'rtk (default)' })"

# --- Proxy ---
Write-Host ""
Write-Host "--- Proxy (Headroom :8787) ---" -ForegroundColor Cyan
$proxyUp = Test-Port 8787
if ($proxyUp) {
    Write-Host "  status: LISTENING" -ForegroundColor Green
    Write-Host "  tip:    start-grok keeps proxy + PATH; stop with stop-grok-proxy" -ForegroundColor DarkGray
} else {
    Write-Host "  status: DOWN" -ForegroundColor Yellow
    Write-Host "  fix:    start-grok   (or start-headroom-proxy.ps1)" -ForegroundColor Yellow
    Write-Host "  note:   default model grok-via-headroom needs proxy up" -ForegroundColor DarkGray
}

# --- Session hooks ---
Write-Host ""
Write-Host "--- Session hooks (~/.grok/hooks) ---" -ForegroundColor Cyan
Write-Host "  load:   new Grok sessions pick these up automatically" -ForegroundColor DarkGray
Write-Host "  reload: only after install/hook edits in an already-open session:" -ForegroundColor DarkGray
Write-Host "          /hooks then r  - or restart Grok" -ForegroundColor DarkGray
foreach ($hf in @('token-saving.json', 'vibe-coding.json', 'serena-hooks.json')) {
    $p = Join-Path $hooksDir $hf
    if (Test-Path -LiteralPath $p) {
        $ok = $true
        try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json | Out-Null } catch { $ok = $false }
        $extra = ''
        $raw = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
        if ($hf -eq 'token-saving.json') {
            $hasRtk = $raw -match 'run-rtk-enforce'
            $extra = if ($hasRtk) { ' + rtk-enforce' } else { ' MISSING rtk-enforce' }
        }
        if ($hf -eq 'serena-hooks.json') {
            $extra = ' (opt-in; empty allow-list broke Read hooks historically)'
        }
        $label = if ($ok) { 'valid JSON' } else { 'INVALID JSON' }
        Write-Host "  $hf : $label$extra" -ForegroundColor (Get-StatusColor $ok)
    } else {
        $missColor = if ($hf -eq 'serena-hooks.json') { 'DarkGray' } else { 'Yellow' }
        $hint = if ($hf -eq 'serena-hooks.json') { ' (ok - off by default; Enable-SerenaRemindHooks.ps1)' } else { '' }
        Write-Host "  $hf : missing$hint" -ForegroundColor $missColor
    }
}

# --- Gate profiles / scripts ---
Write-Host ""
Write-Host "--- Vibe gate ---" -ForegroundColor Cyan
$reviewPs1 = Join-Path $vibeScripts 'grok-ai-review.ps1'
$hooksInstall = Join-Path $vibeScripts 'install-vibe-hooks.ps1'
Write-Host "  scripts: $(if (Test-Path $reviewPs1) { 'ok' } else { 'MISSING grok-ai-review.ps1' })" -ForegroundColor (Get-StatusColor (Test-Path $reviewPs1))
Write-Host '  profiles: fast | standard | strict  (env VIBE_GATE_PROFILE overrides default)'
$envProf = if ($env:VIBE_GATE_PROFILE) { $env:VIBE_GATE_PROFILE } else { '(unset -> standard)' }
Write-Host "  VIBE_GATE_PROFILE: $envProf"
Write-Host '  commit hook: Profile=standard (3 reviewers + fix loop)'
Write-Host '  push hook:   Profile=fast (1 correctness reviewer, no fix)'
$cacheMsg = if (Test-Path $cacheFile) { $cacheFile } else { 'none yet (pass cache after first APPROVE)' }
Write-Host "  cache:       $cacheMsg" -ForegroundColor DarkGray
if ($env:VIBE_GATE_NO_CACHE -eq '1') {
    Write-Host '  VIBE_GATE_NO_CACHE=1 (pass cache disabled)' -ForegroundColor Yellow
}

# --- Latest report ---
Write-Host ""
Write-Host "--- Latest gate report ---" -ForegroundColor Cyan
$latestMd = Join-Path $reportsRoot 'latest.md'
$latestJson = Join-Path $reportsRoot 'latest.json'
if (Test-Path -LiteralPath $latestJson) {
    try {
        $rep = Get-Content -LiteralPath $latestJson -Raw | ConvertFrom-Json
        $pass = [bool]$rep.passed
        $ver = if ($rep.verdict) { $rep.verdict } else { 'n/a' }
        Write-Host ("  verdict: {0}  passed={1}  profile={2}" -f $ver, $pass, $rep.profile) -ForegroundColor (Get-StatusColor $pass)
        if ($rep.elapsedSec) { Write-Host ("  elapsed: {0}s" -f $rep.elapsedSec) -ForegroundColor DarkGray }
        if ($rep.failReason) { Write-Host ("  fail:    {0}" -f $rep.failReason) -ForegroundColor Yellow }
        if ($rep.cacheHit) { Write-Host "  cache:   HIT" -ForegroundColor DarkCyan }
        if ($rep.reportDir) { Write-Host "  dir:     $($rep.reportDir)" -ForegroundColor DarkGray }
    } catch {
        Write-Host "  latest.json present but unreadable: $_" -ForegroundColor Yellow
    }
    Write-Host "  md:      $latestMd"
    Write-Host "  html:    $(Join-Path $reportsRoot 'latest.html')"
} else {
    Write-Host "  none yet - run vibe-review or a commit gate once" -ForegroundColor DarkGray
    Write-Host "  path:    $reportsRoot" -ForegroundColor DarkGray
}

# --- Repo hooks (cwd) ---
Write-Host ""
Write-Host "--- Repo git hooks (cwd) ---" -ForegroundColor Cyan
$cwd = (Get-Location).Path
$gitDir = Join-Path $cwd '.git'
if (Test-Path $gitDir) {
    if (Test-Path $gitDir -PathType Leaf) {
        $gitFile = Get-Content $gitDir -Raw
        if ($gitFile -match 'gitdir:\s*(.+)') {
            $gd = $Matches[1].Trim()
            if (-not [System.IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $cwd $gd }
            $gitDir = $gd
        }
    }
    $preCommit = Join-Path $gitDir 'hooks\pre-commit'
    $prePush = Join-Path $gitDir 'hooks\pre-push'
    $pcOk = Test-Path $preCommit
    $ppOk = Test-Path $prePush
    Write-Host "  repo: $cwd"
    if ($pcOk) {
        $pcTxt = Get-Content $preCommit -Raw -ErrorAction SilentlyContinue
        $prof = if ($pcTxt -match 'Profile standard') { 'standard' } elseif ($pcTxt -match 'Profile fast') { 'fast' } else { 'legacy/unspecified' }
        Write-Host "  pre-commit: present (profile hint: $prof)" -ForegroundColor Green
    } else {
        Write-Host "  pre-commit: MISSING - run install-vibe-hooks.ps1 ." -ForegroundColor Yellow
    }
    if ($ppOk) {
        $ppTxt = Get-Content $prePush -Raw -ErrorAction SilentlyContinue
        $prof = if ($ppTxt -match 'profile=fast' -or $ppTxt -match 'Profile fast') { 'fast' } else { 'present' }
        Write-Host "  pre-push:   present (profile hint: $prof)" -ForegroundColor Green
    } else {
        Write-Host "  pre-push:   MISSING - run install-vibe-hooks.ps1 ." -ForegroundColor Yellow
    }
    if (-not $pcOk -and (Test-Path $hooksInstall)) {
        Write-Host ('  fix: run install-vibe-hooks.ps1 on this repo: {0}' -f $hooksInstall) -ForegroundColor Yellow
    }
} else {
    Write-Host "  no .git in cwd - per-repo gates N/A here" -ForegroundColor DarkGray
}

if (Test-Path -LiteralPath $cfg) {
    Write-Host ""
    Write-Host "--- config.toml ---" -ForegroundColor Cyan
    $cfgTxt = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
    if ($cfgTxt -match 'permission_mode\s*=\s*"always-approve"') {
        Write-Host '  WARN: permission_mode=always-approve (tools auto-run without prompts).' -ForegroundColor Yellow
        Write-Host '        Not set by vibe stack. Change via /settings if undesired.' -ForegroundColor Yellow
    }
    if ($cfgTxt -match 'grok-via-headroom' -and -not $proxyUp) {
        Write-Host '  WARN: default model uses Headroom but proxy is down. Use start-grok.' -ForegroundColor Yellow
    }
    $mcpCap = [regex]::Match([string]$cfgTxt, 'max_output_bytes\s*=\s*(\d+)')
    if ($mcpCap.Success) {
        Write-Host ("  mcp max_output_bytes: {0}" -f $mcpCap.Groups[1].Value)
    }
    $effort = [regex]::Match([string]$cfgTxt, "default_reasoning_effort\s*=\s*`"([^`"]+)`"")
    if ($effort.Success) {
        Write-Host ("  default_reasoning_effort: {0}" -f $effort.Groups[1].Value)
    }
}

Write-Host ""
if (Test-Path $headroom) {
    # Bound headroom doctor so smoke/CI cannot hang
    try {
        $hdJob = Start-Job -ScriptBlock {
            param($exe)
            & $exe doctor 2>&1
        } -ArgumentList $headroom
        $null = Wait-Job -Job $hdJob -Timeout 45
        if ($hdJob.State -eq 'Completed') {
            Receive-Job -Job $hdJob | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host "headroom doctor: timed out after 45s (skipped)" -ForegroundColor Yellow
            Stop-Job -Job $hdJob -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $hdJob -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "headroom doctor: $_" -ForegroundColor DarkYellow
    }
}
Write-Host ""
Write-Host "Max stack:"
Write-Host '  caveman: ultra (chat output)'
Write-Host '  rtk:     prefix noisy shell (git/test/build/docker/gh/...)'
Write-Host '  proxy:   mode=token lossless code-aware intercept target-ratio=0.35 read-maturation no-ccr'
Write-Host '  mcp:     max_output_bytes=20000 (config)'
Write-Host '  compact: 55% + two-pass'
Write-Host '  gates:   profiles fast|standard|strict; AI fail-closed; reports under vibe-tools/reports'
Write-Host ""
Write-Host 'Skills: caveman + token-save under ~/.grok/skills'
Write-Host 'Rules:  caveman.md + token-efficiency.md + rtk.md under ~/.grok/rules'
Write-Host 'RTK.md: ~/.grok/RTK.md'
Write-Host 'MCP:    mcp_servers.headroom in ~/.grok/config.toml'
Write-Host 'Launch: start-grok (or start-grok -Status)'
Write-Host 'Hooks:  new sessions auto-load; reload only if Grok was open during install (/hooks r)'
Write-Host 'Smoke:  Invoke-VibeStackSmoke.ps1 (no AI spend)'

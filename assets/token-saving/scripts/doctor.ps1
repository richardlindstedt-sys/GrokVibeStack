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

$listenProbe = Join-Path $grokHome 'token-saving\scripts\ListenProbe.ps1'
if (-not (Test-Path -LiteralPath $listenProbe)) { $listenProbe = Join-Path $PSScriptRoot 'ListenProbe.ps1' }
if (Test-Path -LiteralPath $listenProbe) { . $listenProbe }

function Test-Port([int]$p) {
    if (Get-Command Test-VibePortListening -ErrorAction SilentlyContinue) {
        return [bool](Test-VibePortListening -Port $p)
    }
    return $false
}

function Get-ListenOwnerPids([int]$p) {
    if (Get-Command Get-VibeListenOwnerPids -ErrorAction SilentlyContinue) {
        return @(Get-VibeListenOwnerPids -Port $p)
    }
    return @()
}

function Get-StatusColor([bool]$ok) {
    if ($ok) { 'Green' } else { 'Yellow' }
}

function Get-ProcessCommandLine([int]$procId) {
    try {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -OperationTimeoutSec 3 -ErrorAction SilentlyContinue
        if ($wmi -and $wmi.CommandLine) { return [string]$wmi.CommandLine }
    } catch {}
    return $null
}

function Test-ProxyCommandLineMatchesStack([string]$cmdLine, [int]$port) {
    # Keep needles in sync with start-grok.ps1 Test-ProxyCommandLineMatchesStack
    if ([string]::IsNullOrWhiteSpace($cmdLine)) { return $false }
    if ($cmdLine -notmatch '(?i)headroom') { return $false }
    if ($cmdLine -notmatch '(?i)(\s|^)proxy(\s|$)') { return $false }
    if ($cmdLine -notmatch '(?i)--mode(\s+|=)token(\s|$)') { return $false }
    $needles = @(
        '--lossless',
        '--code-aware',
        '--target-ratio',
        '0.35',
        '--no-ccr-proactive-expansion',
        '--no-http2',
        '--no-rate-limit',
        '--openai-api-url'
    )
    foreach ($n in $needles) {
        if ($cmdLine -notlike "*$n*") { return $false }
    }
    if ($cmdLine -notmatch ("(?i)--port(\s|=)+{0}(\s|$)" -f $port)) { return $false }
    return $true
}

Write-Host "=== Token-saving / vibe doctor ===" -ForegroundColor Cyan
$stackVer = $null
foreach ($vf in @((Join-Path $grokHome 'VERSION'), (Join-Path $PSScriptRoot '..\..\..\VERSION'))) {
    if (Test-Path -LiteralPath $vf) {
        $stackVer = (Get-Content -LiteralPath $vf -TotalCount 1).Trim()
        break
    }
}
Write-Host "stack:    $(if ($stackVer) { $stackVer } else { 'unknown' })"
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
$serenaCmd = Get-Command serena -ErrorAction SilentlyContinue
$serenaExe = $null
foreach ($p in @(
        (Join-Path $env:USERPROFILE '.local\bin\serena.exe'),
        (Join-Path $grokBin 'serena.exe')
    )) {
    if (Test-Path -LiteralPath $p) { $serenaExe = $p; break }
}
if (-not $serenaExe -and $serenaCmd) { $serenaExe = $serenaCmd.Source }
if ($serenaExe) {
    $sv = & $serenaExe --version 2>&1
    Write-Host "serena:   $sv @ $serenaExe"
} else {
    Write-Host "serena:   MISSING - run ensure-serena.ps1" -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $cfg) {
    $cfgRaw = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
    if ($cfgRaw -match "(?m)\[mcp_servers\.serena\][\s\S]{0,400}?command\s*=\s*'([^']+)'") {
        $cfgSerena = $Matches[1]
        $cfgOn = $cfgRaw -match '(?s)\[mcp_servers\.serena\].*?enabled\s*=\s*true'
        $cfgOk = Test-Path -LiteralPath $cfgSerena
        Write-Host "  config: $cfgSerena enabled=$cfgOn exists=$cfgOk" -ForegroundColor (Get-StatusColor ($cfgOk -and $cfgOn))
    }
}
$projYml = Join-Path (Get-Location) '.serena\project.yml'
if (Test-Path -LiteralPath $projYml) {
    $pyRaw = Get-Content -LiteralPath $projYml -Raw
    $emptyLs = ($pyRaw -match '(?m)^language_servers:\s*\[\s*\]') -or ($pyRaw -notmatch '(?m)^language_servers:\s*\r?\n-')
    if ($emptyLs) {
        Write-Host "  project: language_servers EMPTY - symbol tools fail. Fix: ensure-serena.ps1 -RepoPath ." -ForegroundColor Yellow
    } else {
        $ls = [regex]::Matches($pyRaw, '(?m)^-\s+(\S+)') | ForEach-Object { $_.Groups[1].Value }
        Write-Host "  project: language_servers = $($ls -join ', ')"
    }
} else {
    Write-Host "  project: no .serena/project.yml in cwd (ok until you open a repo)" -ForegroundColor DarkGray
}
Write-Host "caveman:  $(Get-Content (Join-Path $grokHome '.caveman-active') -ErrorAction SilentlyContinue)"
Write-Host "HEADROOM_CONTEXT_TOOL: $(if ($env:HEADROOM_CONTEXT_TOOL) { $env:HEADROOM_CONTEXT_TOOL } else { 'rtk (default)' })"

# --- Proxy ---
Write-Host ""
Write-Host "--- Proxy (Headroom :8787) ---" -ForegroundColor Cyan
function Get-HeadroomCliVersion([string]$exe) {
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return 'unknown' }
    try {
        $raw = & $exe -v 2>&1 | Out-String
        if ($raw -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    } catch {}
    return 'unknown'
}

$proxyPort = 8787
$proxyUp = Test-Port $proxyPort
$proxyPidFile = Join-Path $grokHome 'token-saving\state\headroom-proxy.pid'
$proxyFpFile = Join-Path $grokHome 'token-saving\state\headroom-proxy.fingerprint'
$hrVer = Get-HeadroomCliVersion $headroom
$upHost = 'cli-chat-proxy.grok.com'
$rawUp = $env:OPENAI_TARGET_API_URL
if ($rawUp) { $rawUp = $rawUp.Trim().TrimEnd('/') }
$staleXai = $rawUp -and ($rawUp -match '(?i)api\.x\.ai') -and -not $env:XAI_API_KEY
if ($rawUp -and -not $staleXai) {
    try { $upHost = ([Uri]$rawUp).Host } catch { $upHost = 'unknown' }
} elseif ($env:XAI_API_KEY) {
    $upHost = 'api.x.ai'
}
$expectedFp = ('v3|hr={0}|mode=token|ratio=0.35|lossless|code-aware|no-ccr|no-http2|no-rl|up={1}|port=8787' -f $hrVer, $upHost)
if ($hrVer -match '^0\.(\d+)\.') {
    $hrMinor = [int]$Matches[1]
    if ($hrMinor -lt 36) {
        Write-Host "  WARN: headroom $hrVer 502s Grok /v1/responses SSE (TUI Retrying). Need >= 0.36.0" -ForegroundColor Yellow
    }
}
$fpOnDisk = $null
if (Test-Path -LiteralPath $proxyFpFile) {
    $fpOnDisk = (Get-Content -LiteralPath $proxyFpFile -Raw -ErrorAction SilentlyContinue).Trim()
}
$fpOk = ($fpOnDisk -eq $expectedFp)
$liveCmd = $null
$livePid = $null
$cmdOk = $false
if ($proxyUp) {
    $ownerPids = [System.Collections.Generic.List[int]]::new()
    if (Test-Path -LiteralPath $proxyPidFile) {
        $rawPid = (Get-Content -LiteralPath $proxyPidFile -Raw -ErrorAction SilentlyContinue).Trim()
        $parsedPid = 0
        if ([int]::TryParse($rawPid, [ref]$parsedPid) -and $parsedPid -gt 0) {
            [void]$ownerPids.Add($parsedPid)
        }
    }
    foreach ($op in @(Get-ListenOwnerPids $proxyPort)) {
        if (-not $ownerPids.Contains($op)) { [void]$ownerPids.Add($op) }
    }
    foreach ($pidCand in $ownerPids) {
        $cl = Get-ProcessCommandLine $pidCand
        if (Test-ProxyCommandLineMatchesStack $cl $proxyPort) {
            $livePid = $pidCand
            $liveCmd = $cl
            $cmdOk = $true
            break
        }
        if (-not $liveCmd -and $cl) {
            $livePid = $pidCand
            $liveCmd = $cl
        }
    }
}
$stackOk = $proxyUp -and $cmdOk -and $fpOk
if ($proxyUp) {
    if ($stackOk) {
        Write-Host "  status: LISTENING (stack match)" -ForegroundColor Green
    } else {
        Write-Host "  status: LISTENING (wrong or unverified stack)" -ForegroundColor Yellow
    }
    if ($livePid) { Write-Host ("  pid:    {0}" -f $livePid) }
    if ($liveCmd) {
        $shown = if ($liveCmd.Length -gt 180) { $liveCmd.Substring(0, 177) + '...' } else { $liveCmd }
        Write-Host ("  cmdline:{0}{1}" -f " ", $shown)
    } else {
        Write-Host "  cmdline: (unavailable)" -ForegroundColor DarkGray
    }
    Write-Host ("  live argv: {0}" -f $(if ($cmdOk) { 'MATCH' } else { 'MISMATCH' })) -ForegroundColor (Get-StatusColor $cmdOk)
    Write-Host ("  fingerprint file: {0}" -f $(if ($fpOk) { 'ok' } elseif ($fpOnDisk) { 'stale/other' } else { 'missing' })) -ForegroundColor (Get-StatusColor $fpOk)
    if (-not $stackOk) {
        Write-Host "  fix:    start-grok   (restarts mismatched proxy)" -ForegroundColor Yellow
    } else {
        Write-Host "  tip:    start-grok keeps proxy + PATH; stop with stop-grok-proxy" -ForegroundColor DarkGray
    }
    # /readyz blocks during SSE. PS 5.1 Invoke-WebRequest -TimeoutSec can hang minutes. Listen only.
    Write-Host "  http:    skipped (/readyz blocks on busy SSE; listen table is liveness)" -ForegroundColor DarkGray
} else {
    Write-Host "  status: DOWN" -ForegroundColor Yellow
    Write-Host ("  fingerprint file: {0}" -f $(if ($fpOk) { 'ok (stale while down)' } elseif ($fpOnDisk) { 'stale/other' } else { 'missing' })) -ForegroundColor DarkGray
    Write-Host "  fix:    start-grok   (or start-headroom-proxy.ps1)" -ForegroundColor Yellow
    Write-Host "  note:   default grok-4.6 is overridden to Headroom; needs proxy up" -ForegroundColor DarkGray
}
$keepPidFile = Join-Path $grokHome 'token-saving\state\headroom-keeper.pid'
$keepUp = $false
if (Test-Path -LiteralPath $keepPidFile) {
    $kr = (Get-Content -LiteralPath $keepPidFile -Raw -ErrorAction SilentlyContinue).Trim()
    $kid = 0
    if ([int]::TryParse($kr, [ref]$kid) -and $kid -gt 0) {
        $kp = Get-Process -Id $kid -ErrorAction SilentlyContinue
        $kcl = Get-ProcessCommandLine $kid
        $keepUp = [bool]($kp -and $kcl -and $kcl -match 'keep-headroom-proxy')
    }
}
Write-Host ("  keeper: {0}" -f $(if ($keepUp) { 'up (auto-restart)' } else { 'DOWN — start-grok -ProxyOnly' })) -ForegroundColor (Get-StatusColor $keepUp)

Write-Host ""
Write-Host "--- Leftover gate proxy (:8788; grok-gate is :8787 alias) ---" -ForegroundColor Cyan
$gatePort = 8788
$gateUp = Test-Port $gatePort
$gatePidFile = Join-Path $grokHome 'token-saving\state\headroom-proxy-8788.pid'
$gateKeepFile = Join-Path $grokHome 'token-saving\state\headroom-keeper-8788.pid'
$gatePid = '-'
if (Test-Path -LiteralPath $gatePidFile) {
    $gp = (Get-Content -LiteralPath $gatePidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($gp) { $gatePid = $gp }
}
$gateKeepUp = $false
if (Test-Path -LiteralPath $gateKeepFile) {
    $gkr = (Get-Content -LiteralPath $gateKeepFile -Raw -ErrorAction SilentlyContinue).Trim()
    $gkid = 0
    if ([int]::TryParse($gkr, [ref]$gkid) -and $gkid -gt 0) {
        $gkp = Get-Process -Id $gkid -ErrorAction SilentlyContinue
        $gkcl = Get-ProcessCommandLine $gkid
        $gateKeepUp = [bool]($gkp -and $gkcl -and $gkcl -match 'keep-headroom-proxy')
    }
}
if ($gateUp) {
    Write-Host "  status: LISTENING (leftover dual proxy - stop it)" -ForegroundColor Yellow
    Write-Host ("  pid:    {0}" -f $gatePid)
    Write-Host '  fix:    start-grok -StopProxy -Port 8788' -ForegroundColor Yellow
} else {
    Write-Host "  status: DOWN (expected; grok-gate shares :8787)" -ForegroundColor Green
}
if ($gateKeepUp) {
    Write-Host '  keeper: up (leftover :8788 session keeper - stop with -StopProxy -Port 8788)' -ForegroundColor Yellow
} else {
    Write-Host "  keeper: DOWN (expected)" -ForegroundColor Green
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
$insideGit = $false
try { $insideGit = ((git -C $cwd rev-parse --is-inside-work-tree 2>$null | Select-Object -First 1) -eq 'true') } catch {}
if ($insideGit) {
    $hooksDirRepo = $null
    try { $hooksDirRepo = (git -C $cwd rev-parse --git-path hooks 2>$null | Select-Object -First 1) } catch {}
    if ([string]::IsNullOrWhiteSpace($hooksDirRepo)) {
        $hooksDirRepo = Join-Path $cwd '.git\hooks'
    }
    if (-not [System.IO.Path]::IsPathRooted($hooksDirRepo)) {
        $hooksDirRepo = Join-Path $cwd $hooksDirRepo
    }
    $preCommit = Join-Path $hooksDirRepo 'pre-commit'
    $prePush = Join-Path $hooksDirRepo 'pre-push'
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
    $cfgTxt = $null
    $tomlHelper = Join-Path $grokHome 'token-saving\scripts\GrokToml.ps1'
    if (Test-Path -LiteralPath $tomlHelper) {
        try {
            . $tomlHelper
            $cfgTxt = Read-Utf8NoBomFile -Path $cfg
            $cfgCheck = Test-VibeToml -Raw ([string]$cfgTxt)
            if ($cfgCheck.Ok) {
                Write-Host '  parse: ok (Headroom grok-4.6 + grok-gate alias :8787, no duplicate keys/tables)' -ForegroundColor Green
            } else {
                Write-Host ('  ERROR: {0}' -f ($cfgCheck.Errors -join '; ')) -ForegroundColor Red
                Write-Host '        start-grok auto-repairs this; or re-run Install-GrokVibeStack.ps1' -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  WARN: config check failed: $_" -ForegroundColor Yellow
        }
    }
    if (-not $cfgTxt) {
        $cfgTxt = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
    }
    if ($cfgTxt -match 'permission_mode\s*=\s*"always-approve"') {
        Write-Host '  WARN: permission_mode=always-approve (tools auto-run without prompts).' -ForegroundColor Yellow
        Write-Host '        Not set by vibe stack. Change via /settings if undesired.' -ForegroundColor Yellow
    }
    if ($cfgTxt -match '127\.0\.0\.1:8787|grok-via-headroom' -and -not $proxyUp) {
        Write-Host '  WARN: default grok-4.6 uses Headroom but proxy is down. Use start-grok.' -ForegroundColor Yellow
    }
    if ($cfgTxt -match '127\.0\.0\.1:8788') {
        Write-Host '  WARN: config still points at :8788 (dual-proxy leftover). start-grok repairs to :8787; start-grok -StopProxy -Port 8788' -ForegroundColor Yellow
    }
    if ($cfgTxt -match '(?m)^\s*\[model\."grok-4\.6"\]' -and $cfgTxt -notmatch '(?m)^\s*\[model\."grok-gate"\]') {
        Write-Host '  WARN: missing [model."grok-gate"] (:8787 alias). Re-run installer or start-grok to repair.' -ForegroundColor Yellow
    }
    if ($cfgTxt -match '(?m)^\s*\[model\.grok-4\.6(?:-direct)?\]\s*$') {
        Write-Host '  WARN: unquoted [model.grok-4.6*] is ignored by Grok 1.0.3 (nested table). Use [model."grok-4.6"] / [model."grok-4.6-direct"]. Re-run installer.' -ForegroundColor Yellow
    }
    $mcpCap = [regex]::Match([string]$cfgTxt, 'max_output_bytes\s*=\s*(\d+)')
    if ($mcpCap.Success) {
        Write-Host ("  mcp max_output_bytes: {0}" -f $mcpCap.Groups[1].Value)
    }
    $effort = [regex]::Match([string]$cfgTxt, "default_reasoning_effort\s*=\s*`"([^`"]+)`"")
    if ($effort.Success) {
        Write-Host ("  default_reasoning_effort: {0} (interactive chat; gates force high)" -f $effort.Groups[1].Value)
    }
    if ($cfgTxt -match '(?s)\[model\."grok-4\.6"\].{0,400}env_key') {
        Write-Host '  WARN: [model."grok-4.6"] still has env_key. Unset XAI_API_KEY => TUI waits forever. Re-run installer or start-grok repair.' -ForegroundColor Yellow
    }
    if ($cfgTxt -match '(?m)^\s*default\s*=\s*"grok-4\.6-direct"') {
        Write-Host '  WARN: [models].default is grok-4.6-direct (proxy bypassed). Switch to grok-4.6 after start-grok.' -ForegroundColor Yellow
    }
    $hrMcp = [regex]::Match([string]$cfgTxt, '(?s)\[mcp_servers\.headroom\].*?enabled\s*=\s*(true|false)')
    if ($hrMcp.Success) {
        $on = $hrMcp.Groups[1].Value -eq 'true'
        Write-Host ("  Headroom MCP: {0} (default on; set enabled = false to opt out)" -f $(if ($on) { 'enabled' } else { 'disabled' }))
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
Write-Host '  proxy:   mode=token lossless code-aware target-ratio=0.35 no-ccr'
Write-Host '  mcp:     max_output_bytes=20000 (config)'
Write-Host '  compact: 55% + two-pass'
Write-Host '  gates:   profiles fast|standard|strict; AI fail-closed; reports under vibe-tools/reports'
Write-Host ""
Write-Host 'Skills: caveman + token-save under ~/.grok/skills'
Write-Host 'Rules:  caveman.md + token-efficiency.md + rtk.md under ~/.grok/rules'
Write-Host 'RTK.md: ~/.grok/RTK.md'
Write-Host 'MCP:    mcp_servers.headroom enabled=true by default; optional off in ~/.grok/config.toml'
$ledgerPath = Join-Path $reportsRoot 'gate-open-advisories.json'
if (Test-Path -LiteralPath $ledgerPath) {
    try {
        $led = Get-Content -LiteralPath $ledgerPath -Raw -Encoding utf8 | ConvertFrom-Json
        $open = @($led.items | Where-Object { $_ -and [string]$_.status -ne 'resolved' })
        $nextN = @($open | Where-Object {
                $b = [string]$_.bucket
                if (-not $b) { $b = [string]$_.severity }
                $b -eq 'next' -or $b -eq 'advisory' -or -not $b
            }).Count
        $laterN = @($open | Where-Object { [string]$_.bucket -eq 'later' }).Count
        Write-Host ("Ledger:  {0} next (must-fix next commit), {1} later (backlog)  {2}" -f $nextN, $laterN, $ledgerPath)
        foreach ($row in @($open | Select-Object -First 8)) {
            $bk = [string]$row.bucket
            if (-not $bk) { $bk = 'next' }
            Write-Host ("         [{0}] {1}  {2}" -f $bk, $row.id, $row.title)
        }
    } catch {
        Write-Host "Ledger:  unreadable $ledgerPath" -ForegroundColor Yellow
    }
} else {
    Write-Host 'Ledger:  (none)'
}
Write-Host 'Launch: start-grok (or start-grok -Status)'
Write-Host 'Hooks:  new sessions auto-load; reload only if Grok was open during install (/hooks r)'
Write-Host 'Smoke:  Invoke-VibeStackSmoke.ps1 (no AI spend)'

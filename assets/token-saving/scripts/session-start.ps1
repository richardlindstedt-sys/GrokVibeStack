# SessionStart: mark caveman active, ensure rtk on PATH, token-saving dirs exist.
$ErrorActionPreference = 'SilentlyContinue'

$grok = Join-Path $env:USERPROFILE '.grok'
$flag = Join-Path $grok '.caveman-active'
$logDir = Join-Path $grok 'token-saving\logs'
$stateDir = Join-Path $grok 'token-saving\state'
$grokBin = Join-Path $grok 'bin'
$headroomBin = Join-Path $env:USERPROFILE '.headroom\bin'
$uvToolsBin = Join-Path $env:USERPROFILE '.local\bin'
$vibeScripts = Join-Path $grok 'vibe-tools\venv\Scripts'
$tokenScripts = Join-Path $grok 'token-saving\venv\Scripts'
$ghDir = 'C:\Program Files\GitHub CLI'
$ensureRtk = Join-Path $grok 'token-saving\scripts\ensure-rtk.ps1'

New-Item -ItemType Directory -Force -Path $logDir, $stateDir, $grokBin | Out-Null

if (-not (Test-Path $flag)) {
    Set-Content -Path $flag -Value 'ultra' -Encoding utf8 -NoNewline
}

# Prefer managed bins for this session's child tools (rtk, serena, vibe scanners).
foreach ($p in @($grokBin, $headroomBin, $uvToolsBin, $vibeScripts, $tokenScripts, $ghDir)) {
    if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
        $env:PATH = "$p;$env:PATH"
    }
}

$rtkOk = $false
$rtkVer = $null
if (Test-Path $ensureRtk) {
    try {
        & $ensureRtk -Quiet 2>$null | Out-Null
    } catch {}
}
$rtkCmd = Get-Command rtk -ErrorAction SilentlyContinue
if ($rtkCmd) {
    $rtkOk = $true
    try { $rtkVer = (& $rtkCmd.Source --version 2>&1 | Select-Object -First 1) } catch { $rtkVer = $rtkCmd.Source }
} elseif (Test-Path (Join-Path $grokBin 'rtk.exe')) {
    $rtkOk = $true
    try { $rtkVer = (& (Join-Path $grokBin 'rtk.exe') --version 2>&1 | Select-Object -First 1) } catch {}
}

if (-not $env:HEADROOM_CONTEXT_TOOL) { $env:HEADROOM_CONTEXT_TOOL = 'rtk' }

$sid = if ($env:GROK_SESSION_ID) { $env:GROK_SESSION_ID } else { 'unknown' }
$stamp = Get-Date -Format 'o'
$hookToken = Join-Path $grok 'hooks\token-saving.json'
$rtkHook = $false
if (Test-Path -LiteralPath $hookToken) {
    try {
        $hj = Get-Content -LiteralPath $hookToken -Raw
        $rtkHook = $hj -match 'run-rtk-enforce'
    } catch {}
}
Add-Content -Path (Join-Path $logDir 'sessions.jsonl') -Value (@{
    ts        = $stamp
    sessionId = $sid
    cwd       = $env:GROK_WORKSPACE_ROOT
    caveman   = (Get-Content -Path $flag -Raw).Trim()
    rtk       = $rtkOk
    rtkVer    = "$rtkVer"
    rtkHook   = $rtkHook
} | ConvertTo-Json -Compress)

# One-line stderr nudge if RTK enforce hook file missing (session may still need /hooks r)
if (-not $rtkHook) {
    [Console]::Error.WriteLine('[token-saving] hooks/token-saving.json missing rtk-enforce — re-run installer; then /hooks + r')
}

exit 0

<#
.SYNOPSIS
    Install working vibe git hooks (pre-commit + pre-push) and remove sample stubs.
.DESCRIPTION
    - Deletes *.sample hooks (noise; they never run)
    - Installs pre-commit: full static scans + Grok AI review of staged diff
    - Installs pre-push: full static scans + Grok AI review of push range
    - Ensures global Grok on-edit hook exists (~/.grok/hooks/vibe-coding.json)

    Also available as the older name install-pre-commit-hook.ps1 (wrapper).
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$RepoPath = '.'
)

$ErrorActionPreference = 'Stop'

$repo = Resolve-Path $RepoPath
$gitDir = Join-Path $repo '.git'
if (-not (Test-Path $gitDir)) {
    Write-Error "Not a git repository: $repo"
    exit 1
}

# Worktree / gitdir file support
if (Test-Path $gitDir -PathType Leaf) {
    $gitFile = Get-Content $gitDir -Raw
    if ($gitFile -match 'gitdir:\s*(.+)') {
        $gd = $Matches[1].Trim()
        if (-not [System.IO.Path]::IsPathRooted($gd)) {
            $gd = Join-Path $repo $gd
        }
        $gitDir = $gd
    }
}

$hooksDir = Join-Path $gitDir 'hooks'
New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null

# Remove sample noise
Get-ChildItem -Path $hooksDir -Filter '*.sample' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
    Write-Host "Removed sample: $($_.Name)" -ForegroundColor DarkGray
}

function Write-UnixHook([string]$Path, [string]$Content) {
    # LF-only so sh on Windows Git Bash accepts the shebang script
    $lf = ($Content -replace "`r`n", "`n" -replace "`r", "`n")
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $lf, $utf8NoBom)
}

$preCommit = @'
#!/bin/sh
# Vibe pre-commit hook - scans + Grok AI review of staged changes
# Installed by install-vibe-hooks.ps1

echo ""
echo "+================================================================+"
echo "|   VIBE PRE-COMMIT HOOK  [AutoProfile base=standard]            |"
echo "|   Staged-first scans + path-aware AI panel + fix loop          |"
echo "+================================================================+"
echo ""

VIBE_SCRIPTS="$HOME/.grok/vibe-tools/scripts"
# Default require trivy+gitleaks (script also defaults on; 0 = soft-warn only)
export VIBE_REQUIRE_SCANNERS="${VIBE_REQUIRE_SCANNERS:-1}"

echo ">>> STEP 1/2 : STATIC SCANS"
echo "    trivy, gitleaks, pssa, pester, jscpd, biome, markdownlint,"
echo "    semgrep, ruff/mypy/bandit, yamllint/checkov, shellcheck, hadolint"
echo ""

# Auto = staged-first when index non-empty
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$VIBE_SCRIPTS/run-vibe-scans.ps1" -Scope Auto
SCAN_EXIT=$?

if [ $SCAN_EXIT -ne 0 ]; then
    echo ""
    echo "PRE-COMMIT BLOCKED: critical static findings."
    echo "Fix issues above, or emergency only: git commit --no-verify"
    exit 1
fi

echo ""
echo ">>> STEP 2/2 : MULTI-REVIEWER LOOP (staged diff, AutoProfile)"
echo "    base=standard; docs-only may drop to fast; path-aware roles"
echo "    reports: ~/.grok/vibe-tools/reports/latest.md"
echo "    live:    ~/.grok/vibe-tools/reports/live-gate.log"
echo ""

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$VIBE_SCRIPTS/grok-ai-review.ps1" -NoScans -Profile standard -AutoProfile
REVIEW_EXIT=$?

if [ $REVIEW_EXIT -ne 0 ]; then
    echo ""
    echo "PRE-COMMIT BLOCKED: multi-reviewer loop did not reach APPROVE."
    echo "See ~/.grok/vibe-tools/reports/latest.md (or workdir above)."
    echo "Fix remaining blockers, or emergency: git commit --no-verify"
    exit 1
fi

echo ""
echo "PRE-COMMIT OK - scans + multi-reviewer loop clean. Commit proceeds."
exit 0
'@

$prePush = @'
#!/bin/sh
# Vibe pre-push hook - scans + fast profile AI review of push range
# Installed by install-vibe-hooks.ps1

echo ""
echo "+================================================================+"
echo "|   VIBE PRE-PUSH HOOK  [profile=fast]                           |"
echo "|   Scans + 1-reviewer (correctness) on push range               |"
echo "+================================================================+"
echo "live: ~/.grok/vibe-tools/reports/live-gate.log"
echo ""

VIBE_SCRIPTS="$HOME/.grok/vibe-tools/scripts"

# Forward git's stdin (ref lines) into the PowerShell gate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$VIBE_SCRIPTS/run-vibe-pre-push.ps1" <&0
PUSH_EXIT=$?

if [ $PUSH_EXIT -ne 0 ]; then
    echo ""
    echo "PRE-PUSH BLOCKED."
    echo "See ~/.grok/vibe-tools/reports/latest.md"
    echo "Fix issues, or emergency only: git push --no-verify"
    exit 1
fi

exit 0
'@

$preCommitPath = Join-Path $hooksDir 'pre-commit'
$prePushPath = Join-Path $hooksDir 'pre-push'
Write-UnixHook -Path $preCommitPath -Content $preCommit
Write-UnixHook -Path $prePushPath -Content $prePush

# Best-effort executable bit (Git for Windows often ignores; content still runs)
foreach ($h in @($preCommitPath, $prePushPath)) {
    try { & git update-index --chmod=+x -- $h 2>$null } catch {}
    if (Get-Command chmod -ErrorAction SilentlyContinue) {
        & chmod +x $h 2>$null
    }
}

Write-Host ""
Write-Host "Installed vibe git hooks in: $hooksDir" -ForegroundColor Green
Write-Host "  pre-commit  -> scans -Scope Auto + grok-ai-review -Profile standard -AutoProfile" -ForegroundColor Yellow
Write-Host "  pre-push    -> scans Full/cache + grok-ai-review -Profile fast -AutoProfile" -ForegroundColor Yellow
Write-Host "  reports     -> ~/.grok/vibe-tools/reports/latest.md" -ForegroundColor DarkGray

# Global Grok on-edit hook — materialize from assets/hooks/vibe-coding.json
# (same source as Install-GrokVibeStack). Do not embed the hook tree here.
$grokHome = Join-Path $env:USERPROFILE '.grok'
$grokHooksDir = Join-Path $grokHome 'hooks'
New-Item -ItemType Directory -Force -Path $grokHooksDir | Out-Null
$vibeHookJson = Join-Path $grokHooksDir 'vibe-coding.json'

$tplCandidates = @(
    (Join-Path $PSScriptRoot '..\..\hooks\vibe-coding.json')
)
$manifestPath = Join-Path $grokHome 'vibe-stack-manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $man = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($man.scriptRoot) {
            $tplCandidates += (Join-Path $man.scriptRoot 'assets\hooks\vibe-coding.json')
        }
    } catch {}
}

$tpl = $null
$raw = $null
foreach ($c in $tplCandidates) {
    $full = [System.IO.Path]::GetFullPath($c)
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $probe = Get-Content -LiteralPath $full -Raw
    if ($probe.Contains('__GROK_HOME__')) {
        $tpl = $full
        $raw = $probe
        break
    }
}
if (-not $tpl) {
    Write-Error "Missing hook template vibe-coding.json (assets/hooks) with __GROK_HOME__"
    exit 1
}

$homeJson = $grokHome.Replace('\', '\\')
$hookText = $raw.Replace('__GROK_HOME__', $homeJson)
if ($hookText.Contains('__GROK_HOME__')) {
    Write-Error "Unsubstituted placeholder in vibe-coding.json"
    exit 1
}
if ($hookText -notmatch 'run-vibe-stop-remind\.ps1') {
    Write-Error "refusing to write vibe-coding.json without run-vibe-stop-remind.ps1"
    exit 1
}
$null = $hookText | ConvertFrom-Json
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($vibeHookJson, $hookText, $utf8NoBom)
Write-Host ""
Write-Host "Installed Grok session hook: $vibeHookJson" -ForegroundColor Green
Write-Host "  PostToolUse (edits) -> run-vibe-on-edit.ps1 (secrets + linters + session flag)" -ForegroundColor Yellow
Write-Host "  Stop                -> remind only if edited this session (or VIBE_STOP_REMIND=1)" -ForegroundColor Yellow
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host " If Grok is already open: reload hooks once (/hooks then r)" -ForegroundColor Yellow
Write-Host " or restart Grok. New sessions load hooks automatically." -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host "Bypass (emergency only): git commit|push --no-verify" -ForegroundColor DarkGray
Write-Host "AI review gate is fail-closed (missing grok/proxy/verdict blocks)." -ForegroundColor DarkGray
Write-Host ""

$ensureSerena = Join-Path $grokHome 'token-saving\scripts\ensure-serena.ps1'
if (Test-Path -LiteralPath $ensureSerena) {
    Write-Host "Ensuring Serena project language servers in $repo ..." -ForegroundColor DarkGray
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $ensureSerena -RepoPath $repo.Path
    } catch {
        Write-Host "WARN ensure-serena: $_" -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $prev
    }
}
Write-Host "Done. Edit -> fast checks. Commit -> standard gate. Push -> fast gate." -ForegroundColor Green

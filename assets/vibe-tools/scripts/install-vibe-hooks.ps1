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
echo "|   VIBE PRE-COMMIT HOOK  [profile=standard]                     |"
echo "|   Scans + 3-reviewer panel + arbiter + fix/re-review loop      |"
echo "+================================================================+"
echo ""

VIBE_SCRIPTS="$HOME/.grok/vibe-tools/scripts"
# Default require trivy+gitleaks (script also defaults on; 0 = soft-warn only)
export VIBE_REQUIRE_SCANNERS="${VIBE_REQUIRE_SCANNERS:-1}"

echo ">>> STEP 1/2 : STATIC SCANS"
echo "    trivy, gitleaks, pssa, pester, jscpd, biome, markdownlint,"
echo "    semgrep, ruff/mypy/bandit, yamllint/checkov, shellcheck, hadolint"
echo ""

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$VIBE_SCRIPTS/run-vibe-scans.ps1"
SCAN_EXIT=$?

if [ $SCAN_EXIT -ne 0 ]; then
    echo ""
    echo "PRE-COMMIT BLOCKED: critical static findings."
    echo "Fix issues above, or emergency only: git commit --no-verify"
    exit 1
fi

echo ""
echo ">>> STEP 2/2 : MULTI-REVIEWER LOOP (staged diff, profile=standard)"
echo "    correctness + security + simplicity -> arbiter -> fix -> re-review"
echo "    reports: ~/.grok/vibe-tools/reports/latest.md"
echo ""

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$VIBE_SCRIPTS/grok-ai-review.ps1" -NoScans -Profile standard
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
Write-Host "  pre-commit  -> scans + grok-ai-review -Profile standard (staged)" -ForegroundColor Yellow
Write-Host "  pre-push    -> scans + grok-ai-review -Profile fast (push range)" -ForegroundColor Yellow
Write-Host "  reports     -> ~/.grok/vibe-tools/reports/latest.md" -ForegroundColor DarkGray

# Global Grok on-edit hook (session lifecycle) — vibe-coding only; do not touch token-saving.json
$grokHooksDir = Join-Path $env:USERPROFILE '.grok\hooks'
New-Item -ItemType Directory -Force -Path $grokHooksDir | Out-Null
$vibeHookJson = Join-Path $grokHooksDir 'vibe-coding.json'

$onEditPs1 = Join-Path $env:USERPROFILE '.grok\vibe-tools\scripts\run-vibe-on-edit.ps1'
$onEditCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $onEditPs1 + '"'

$hookObj = [ordered]@{
    hooks = [ordered]@{
        PostToolUse = @(
            [ordered]@{
                matcher = 'search_replace|Write|Edit|MultiEdit|write'
                hooks   = @(
                    [ordered]@{
                        type    = 'command'
                        command = $onEditCmd
                        timeout = 60
                    }
                )
            }
        )
        Stop        = @(
            [ordered]@{
                hooks = @(
                    [ordered]@{
                        type    = 'command'
                        command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''[vibe] Turn end - if you edited code, confirm scans/review ran (vibe-review) before calling done.'' -ForegroundColor Cyan"'
                        timeout = 5
                    }
                )
            }
        )
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($vibeHookJson, ($hookObj | ConvertTo-Json -Depth 8), $utf8NoBom)
Write-Host ""
Write-Host "Installed Grok session hook: $vibeHookJson" -ForegroundColor Green
Write-Host "  PostToolUse (edits) -> run-vibe-on-edit.ps1 (secrets + linters)" -ForegroundColor Yellow
Write-Host "  Stop                -> reminder to finish vibe-review if code changed" -ForegroundColor Yellow
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host " If Grok is already open: reload hooks once (/hooks then r)" -ForegroundColor Yellow
Write-Host " or restart Grok. New sessions load hooks automatically." -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host "Bypass (emergency only): git commit|push --no-verify" -ForegroundColor DarkGray
Write-Host "AI review gate is fail-closed (missing grok/proxy/verdict blocks)." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Done. Edit -> fast checks. Commit -> standard gate. Push -> fast gate." -ForegroundColor Green

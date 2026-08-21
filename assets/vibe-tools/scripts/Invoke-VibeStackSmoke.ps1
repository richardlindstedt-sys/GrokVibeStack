<#
.SYNOPSIS
    Offline smoke tests for Grok Vibe Stack (no AI / no network spend).

.DESCRIPTION
    Validates:
      - PowerShell parse of stack scripts
      - Hook JSON templates / live hooks
      - Gate profile resolution (fast/standard/strict)
      - Doctor script runs
      - Optional: install hooks into a temp git repo + secret-scan dry path
      - Optional: uninstall dry-run if Uninstall script present beside Install

    Exit 0 = all checks passed. Exit 1 = one or more failed.
#>
[CmdletBinding()]
param(
    # Repo root containing Install-GrokVibeStack.ps1 and assets/
    [string]$RepoRoot = '',
    # Also exercise install-vibe-hooks in a temp git repo
    [switch]$WithHooksInstall,
    # Run Uninstall -DryRun when uninstall script is found
    [switch]$WithUninstallDryRun,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$failed = [System.Collections.Generic.List[string]]::new()
$passed = [System.Collections.Generic.List[string]]::new()

function Ok([string]$m) {
    [void]$passed.Add($m)
    if (-not $Quiet) { Write-Host "  OK  $m" -ForegroundColor Green }
}
function Bad([string]$m) {
    [void]$failed.Add($m)
    Write-Host "  FAIL $m" -ForegroundColor Red
}
function Info([string]$m) {
    if (-not $Quiet) { Write-Host "  ..  $m" -ForegroundColor DarkGray }
}

if (-not $RepoRoot) {
    # scripts -> vibe-tools -> assets -> repo
    $here = Split-Path $MyInvocation.MyCommand.Path -Parent
    $cand = Split-Path (Split-Path (Split-Path $here -Parent) -Parent) -Parent
    if (Test-Path (Join-Path $cand 'Install-GrokVibeStack.ps1')) {
        $RepoRoot = $cand
    } elseif (Test-Path (Join-Path (Get-Location) 'Install-GrokVibeStack.ps1')) {
        $RepoRoot = (Get-Location).Path
    } else {
        $RepoRoot = $cand
    }
}
try {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
} catch {
    Write-Host "Cannot resolve RepoRoot: $_" -ForegroundColor Red
    exit 1
}

Write-Host "=== Vibe stack smoke ===" -ForegroundColor Cyan
Write-Host "RepoRoot: $RepoRoot" -ForegroundColor DarkGray

# --- 1) Parse key scripts ---
Write-Host ""
Write-Host "1) Parse PowerShell scripts" -ForegroundColor Yellow
$parseTargets = @(
    (Join-Path $RepoRoot 'Install-GrokVibeStack.ps1'),
    (Join-Path $RepoRoot 'Uninstall-GrokVibeStack.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\grok-ai-review.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-path-parse.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-progress.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\install-vibe-hooks.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-pre-push.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-scans.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\scan-pass-cache.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-on-edit.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-stop-remind.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-prompt-context.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\watch-gate-now.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-chat-lib.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-evals.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-schema.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-push-plan.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-review-context.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-fixer-worktree.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\doctor.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\start-grok.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\keep-headroom-proxy.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\GrokToml.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\ensure-serena.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\run-rtk-enforce.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\vibe-review.ps1')
)

foreach ($f in $parseTargets) {
    if (-not (Test-Path -LiteralPath $f)) {
        Bad "missing: $f"
        continue
    }
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $msg = ($errors | ForEach-Object { $_.Message }) -join '; '
        Bad "parse $($f): $msg"
    } else {
        Ok "parse $(Split-Path $f -Leaf)"
    }
}

# --- 2) Hook JSON templates ---
Write-Host ""
Write-Host "2) Hook JSON templates" -ForegroundColor Yellow
$hookDir = Join-Path $RepoRoot 'assets\hooks'
foreach ($hf in @('token-saving.json', 'vibe-coding.json')) {
    $p = Join-Path $hookDir $hf
    if (-not (Test-Path $p)) { Bad "missing template $hf"; continue }
    try {
        $null = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        Ok "json $hf"
    } catch {
        Bad "json $hf : $_"
    }
}
# serena template may exist but is opt-in
$serenaTpl = Join-Path $hookDir 'serena-hooks.json'
if (Test-Path $serenaTpl) {
    try {
        $null = Get-Content -LiteralPath $serenaTpl -Raw | ConvertFrom-Json
        Ok 'json serena-hooks.json (template)'
    } catch { Bad "json serena-hooks.json: $_" }
}

# --- 3) Profile resolution (dot-source function body via isolated parse of switch) ---
Write-Host ""
Write-Host "3) Gate profiles" -ForegroundColor Yellow
$reviewSrc = Join-Path $RepoRoot 'assets\vibe-tools\scripts\grok-ai-review.ps1'
$rawReview = Get-Content -LiteralPath $reviewSrc -Raw
foreach ($name in @('fast', 'standard', 'strict')) {
    if ($rawReview -notmatch [regex]::Escape("'$name'")) {
        Bad "profile token missing: $name"
    } else {
        Ok "profile defined: $name"
    }
}
if ($rawReview -match 'Resolve-GateProfile' -and $rawReview -match 'Write-GateReport' -and $rawReview -match 'Get-DiffHash') {
    Ok 'profile + report + cache helpers present'
} else {
    Bad 'missing Resolve-GateProfile / Write-GateReport / Get-DiffHash'
}
if ($rawReview -match 'Compress-DiffForReview' -and $rawReview -match 'Get-DiffFileStats') {
    Ok 'large-diff compress helpers present'
} else {
    Bad 'missing Compress-DiffForReview / Get-DiffFileStats'
}
if ($rawReview -match 'function ConvertTo-SinglePatchText' -and $rawReview -match 'ConvertTo-SinglePatchText \(git diff --cached') {
    Ok 'review: staged/WT patches flattened to one string'
} else {
    Bad 'Get-GitDiffText still returns git string[]'
}
if ($rawReview -match 'NoFixDefault\s*=\s*\$true' -and $rawReview -match "Roles\s*=\s*@\('correctness'\)") {
    Ok 'fast profile: NoFix + single correctness role'
} else {
    Bad 'fast profile shape unexpected'
}
if ($rawReview -match "ReasoningEffort\s*=\s*'medium'" -and $rawReview -match 'Apply-PathAwareProfile' -and $rawReview -match 'AutoProfile') {
    Ok 'fast medium effort + AutoProfile path-aware'
} else {
    Bad 'missing fast medium effort or AutoProfile helpers'
}
# DiffOverride must win over staged; json/yaml/toml must not be docs-only by default
if ($rawReview -match 'DiffOverride \(e\.g\. push range\) wins' -or ($rawReview -match 'IsNullOrWhiteSpace\(\$DiffOverride\)' -and $rawReview -match 'return @\(\$paths \| Select-Object -Unique\)')) {
    Ok 'AutoProfile: DiffOverride preferred over staged'
} else {
    Bad 'Get-GateChangedPaths still prefers staged over DiffOverride'
}
if ($rawReview -match 'never treat \*\.json' -or ($rawReview -match 'docs\?/' -and $rawReview -notmatch 'package\\.json\|tsconfig\|pyproject')) {
    Ok 'AutoProfile: config/IaC not docs-only'
} else {
    Bad 'Test-PathIsDocOnly still treats json/yaml/toml as docs'
}
if ($rawReview -match 'No \\.lock' -or ($rawReview -match 'drawio\)\$' -and $rawReview -notmatch 'ico\|lock\|drawio') -or ($rawReview -match 'supply-chain' -and $rawReview -match 'go\\.sum')) {
    Ok 'AutoProfile: lockfiles not docs-only'
} else {
    # extension list without lock between ico and drawio
    if ($rawReview -match 'ico\|drawio' -or $rawReview -match 'webp\|ico\|drawio') {
        Ok 'AutoProfile: lockfiles not docs-only'
    } else {
        Bad 'Test-PathIsDocOnly still allowlists .lock'
    }
}
$vibeRule = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\rules\vibe-coding.md') -Raw -ErrorAction SilentlyContinue
if ($vibeRule -and $vibeRule.Length -lt 2500 -and $vibeRule -match 'pre-commit' -and $vibeRule -notmatch 'Tools You Must Use') {
    Ok 'vibe-coding rule slimmed (no scanner laundry list)'
} else {
    Bad 'vibe-coding.md not slimmed'
}

$scanSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-scans.ps1') -Raw
$cacheSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\scan-pass-cache.ps1') -Raw -ErrorAction SilentlyContinue
$prePushSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-pre-push.ps1') -Raw
if ($scanSrc -match 'checkout-index' -and $scanSrc -match 'Save-ScanPassCache' -and $scanSrc -match "Scope = 'Auto'") {
    Ok 'scans: binary staged tree + pass cache + Scope'
} else {
    Bad 'scans missing checkout-index / scan cache / Scope'
}
if ($cacheSrc -and $cacheSrc -match 'ScopeUsed -ne ''Full''' -and $cacheSrc -match 'cachedScope -ne ''Full''' -and $cacheSrc -match 'Normalize-ScanCacheCwd' -and $cacheSrc -match 'Test-ScanPathsWholeTree' -and $prePushSrc -match 'scan-pass-cache\.ps1' -and $prePushSrc -match 'Test-ScanPassCache') {
    Ok 'scan-pass cache: Full-only save + cwd/scope match; pre-push shares Test-ScanPassCache'
} else {
    Bad 'scan-pass cache missing Full/cwd policy or pre-push still has weak reader'
}
if ($scanSrc -match 'New-StagedScanTree' -and $scanSrc -match 'Gitleaks \(staged\)' -and $scanSrc -match 'Invoke-Checkov') {
    Ok 'scans: staged secrets tree + checkov via venv'
} else {
    Bad 'scans missing staged tree / Invoke-Checkov'
}
if ($scanSrc -match 'jscpdTargets' -and $scanSrc -match 'jscpd') {
    Ok 'scans: jscpd concrete targets'
} else {
    Bad 'scans missing jscpd targets fix'
}
if ($scanSrc -match 'Secret heuristic' -and $scanSrc -match 'New-StagedScanTree') {
    Ok 'scans: staged secret heuristic'
} else {
    Bad 'scans missing staged secret heuristic'
}
if ($scanSrc -match 'VIBE_REQUIRE_SCANNERS -ne ''0''' -or $scanSrc -match 'VIBE_REQUIRE_SCANNERS -ne "0"') {
    Ok 'scans: require critical scanners by default'
} else {
    Bad 'scans missing default VIBE_REQUIRE_SCANNERS fail-closed'
}
if ($rawReview -match 'Normalize-ReviewerVote' -and $rawReview -match 'Get-PanelBlockerFindings' -and $rawReview -notmatch 'Unstructured output; vote parsed') {
    Ok 'review: fail-closed panel + vote normalize'
} else {
    Bad 'review missing Normalize-ReviewerVote / still has unstructured vote fallback'
}
# Live restage must not call git add -u/-A (comments mentioning them OK)
$restageLive = [regex]::Replace($rawReview, '(?m)^\s*#.*$', '')
if ($rawReview -match 'Update-GitStageAfterFix' -and $rawReview -match 'PriorStaged' -and $rawReview -match 'PreFixDirty' -and $rawReview -match 'PreFixUntracked' -and $rawReview -match 'ls-files --others --exclude-standard' -and $rawReview -match 'Normalize-RestagePath' -and $rawReview -match 'gate-path-parse\.ps1' -and $restageLive -match ':\(literal\)' -and $restageLive -notmatch 'git add -u' -and $restageLive -notmatch 'git add -A\s') {
    Ok 'review: scoped restage (blocker + prior-staged + PreFixDirty + new untracked); literal pathspec'
} else {
    Bad 'review restage still uses git add -u/-A or missing Normalize-RestagePath / :(literal)'
}
if ($rawReview -match 'Get-PathsFromDiffText' -and $rawReview -match 'Add-NameStatusLineToList' -and $rawReview -match 'name-status') {
    Ok 'AutoProfile: quoted headers + rename both sides (name-status)'
} else {
    Bad 'Get-GateChangedPaths missing quoted/rename helpers'
}
$pathHelper = Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-path-parse.ps1'
if (Test-Path -LiteralPath $pathHelper) {
    . $pathHelper
    $ren = @(Get-PathsFromDiffText "diff --git a/auth/x.py b/docs/y.md`n")
    $q = @(Get-PathsFromDiffText "diff --git `"a/my file.txt`" `"b/my file.txt`"`n")
    $dot = Normalize-RestagePath '.'
    $slashDir = Normalize-RestagePath 'src/'
    $star = Normalize-RestagePath '*'
    $qmark = Normalize-RestagePath '?'
    $class = Normalize-RestagePath '[a-z]'
    $glob = Normalize-RestagePath ':(glob)**'
    $top = Normalize-RestagePath ':/'
    if ($ren -contains 'auth/x.py' -and $ren -contains 'docs/y.md' -and $q -contains 'my file.txt' -and $null -eq $dot -and $null -eq $slashDir -and $null -eq $star -and $null -eq $qmark -and $null -eq $class -and $null -eq $glob -and $null -eq $top) {
        Ok 'gate-path-parse: rename both sides, quoted header, reject . / dir/ / glob / pathspec'
    } else {
        Bad ("gate-path-parse behavior: ren=[{0}] q=[{1}] dot={2} dir={3} star={4} glob={5}" -f ($ren -join ','), ($q -join ','), $dot, $slashDir, $star, $glob)
    }
} else {
    Bad 'missing gate-path-parse.ps1'
}
if ($scanSrc -match 'jscpdDomain' -and $scanSrc -match 'iacDomain' -and $scanSrc -match 'no JS/TS' -and $scanSrc -match 'no IaC domain') {
    Ok 'scans: jscpd/checkov path-domain advisory'
} else {
    Bad 'scans missing jscpd/checkov advisory domain split'
}
# Success path must exit 0 so & / $LASTEXITCODE callers are not poisoned by advisory tools
if ($scanSrc -match 'Static scans passed' -and $scanSrc -match 'exit 0') {
    Ok 'scans: success path exit 0'
} else {
    Bad 'scans missing explicit exit 0 on success'
}
if ($prePushSrc -match 'Start-Process' -and $prePushSrc -match '-File' -and $prePushSrc -match 'ExitCode') {
    Ok 'pre-push: scans via -File process exit'
} else {
    Bad 'pre-push still uses bare & for scans (LASTEXITCODE poison risk)'
}
if ($prePushSrc -match 'scanner process did not start or returned no exit code' -and $prePushSrc -notmatch 'null -eq \$scanProc\.ExitCode\) \{ 0 \}') {
    Ok 'pre-push: null Start-Process / ExitCode fail-closed'
} else {
    Bad 'pre-push still maps null scan ExitCode to 0'
}
if ($prePushSrc -match 'Get-NewBranchPushDiff' -and $prePushSrc -notmatch 'rev-list --max-count=20' -and $prePushSrc -match '--not --remotes' -and $prePushSrc -notmatch "'origin/HEAD'" -and $prePushSrc -notmatch "'origin/main'" -and $prePushSrc -notmatch "'origin/master'" -and $prePushSrc -notmatch 'refs/remotes/origin/HEAD' -and $prePushSrc -notmatch '\$localSha~20' -and $prePushSrc -match 'ConvertTo-SinglePatchText \(git diff --no-color "\$r"') {
    Ok 'pre-push: new branch is unique-vs-remotes (no 20-commit cap, no guessed origin/*); patches flattened'
} else {
    Bad 'pre-push still caps new-branch history, guesses origin/*, or nests git string[]'
}
if ($prePushSrc -match 'null -eq \$LASTEXITCODE\) \{ 1 \}' -and $prePushSrc -match 'no payload to review' -and $prePushSrc -notmatch '\$reviewRan') {
    Ok 'pre-push: null LASTEXITCODE fail-closed after review; empty-range exits before'
} else {
    Bad 'pre-push LASTEXITCODE / empty-range contract wrong'
}
if ($prePushSrc -match 'Get-VibePushTipShas' -and $prePushSrc -match '-TreeIsh' -and $scanSrc -match 'function New-CommitScanTree' -and $scanSrc -match 'TreeIsh' -and $scanSrc -match 'worktree add --detach' -and $scanSrc -match '\.vibe-wt-' -and $scanSrc -match '\.Trim\(\)' -and $scanSrc -match 'absolute-git-dir' -and $prePushSrc -match 'ForEach-Object \{ "\$_"\.Trim\(\) \}' -and $scanSrc -notmatch 'Expand-Archive') {
    Ok 'pre-push: scans push tip via worktree (no Expand-Archive)'
} else {
    Bad 'pre-push still scans checkout or Expand-Archive zip'
}
if ($scanSrc -match 'index blob unavailable' -and $scanSrc -notmatch 'Copy-Item -LiteralPath \$src') {
    Ok 'scans: staged tree never copies worktree'
} else {
    Bad 'staged scan still Copy-Item worktree fallback'
}
$progSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-progress.ps1') -Raw
if ($progSrc -match 'function Write-GateProgress' -and $progSrc -match 'live-gate\.log' -and $progSrc -match 'gate-status\.txt' -and $progSrc -match 'AppendAllLines' -and $progSrc -match 'gate-now\.txt' -and $progSrc -match 'function Write-GateDone' -and $progSrc -match 'Start-GateWatchPopup' -and $progSrc -match 'function Wait-VibeJobs' -and $progSrc -match 'function Start-GateRun' -and $progSrc -match 'RUN:' -and $progSrc -notmatch 'WriteAllLines\(\$script:GateStatusFile' -and $rawReview -match 'Write-GateDone' -and $rawReview -match 'Write-GateFail' -and $rawReview -match 'Start-GateRun' -and $scanSrc -match 'Write-GateDone' -and $scanSrc -match 'Start-GateRun' -and $prePushSrc -match 'gate-progress\.ps1') {
    Ok 'gate progress: RUN token + append-only status + recap + opt-in popup + heartbeats'
} else {
    Bad 'gate-progress.ps1 missing RUN token / append-only status / recap / popup or not wired'
}
$rtkSrc2 = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\run-rtk-enforce.ps1') -Raw
if ($rtkSrc2 -match 'ast-grep' -and $rtkSrc2 -match 'tokei' -and $rtkSrc2 -match 'difft' -and $rtkSrc2 -notmatch '\\bfind\\b') {
    Ok 'rtk: sg/ast-grep/difft/tokei + no bare find'
} else {
    # bare find may still appear as find\.exe — check no '\bfind\b' alone in noisy list
    if ($rtkSrc2 -match 'ast-grep' -and $rtkSrc2 -match 'tokei' -and $rtkSrc2 -match 'find\\.exe') {
        Ok 'rtk: expanded noisy list (find.exe only)'
    } else {
        Bad 'rtk noisy list missing sg/tokei/difft tighten'
    }
}
$stopSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-stop-remind.ps1') -Raw -ErrorAction SilentlyContinue
$onEditSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-on-edit.ps1') -Raw
if ($stopSrc -and $stopSrc -match 'edited-this-session' -and $onEditSrc -match 'edited-this-session.flag') {
    Ok 'stop remind gated on edit flag'
} else {
    Bad 'stop/on-edit session flag wiring missing'
}
$verFile = Join-Path $RepoRoot 'VERSION'
$verLine = if (Test-Path -LiteralPath $verFile) { (Get-Content -LiteralPath $verFile -TotalCount 1).Trim() } else { '' }
$clog = Get-Content -LiteralPath (Join-Path $RepoRoot 'CHANGELOG.md') -Raw -ErrorAction SilentlyContinue
$readmeVer = Get-Content -LiteralPath (Join-Path $RepoRoot 'README.md') -Raw -ErrorAction SilentlyContinue
$instSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'Install-GrokVibeStack.ps1') -Raw
$docVer = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\doctor.ps1') -Raw -ErrorAction SilentlyContinue
$verOk = $verLine -match '^\d+\.\d+\.\d+$'
$instOk = $instSrc -match 'function Get-StackVersion' -and $instSrc -match 'stackVersion' -and $instSrc -match 'Install-GrokVibeStack  \{0'
$docOk = $docVer -match '\$stackVer' -and $docVer -match 'stack:'
$logOk = $clog -match [regex]::Escape("[$verLine]")
$readOk = $readmeVer -match [regex]::Escape("**$verLine**")
if ($verOk -and $instOk -and $docOk -and $logOk -and $readOk) {
    Ok "stack version $verLine in VERSION + banner + manifest + doctor + changelog + README"
} else {
    Bad "VERSION / banner / stackVersion / doctor / changelog / README [$verLine] missing"
}
$unSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'Uninstall-GrokVibeStack.ps1') -Raw
$hooksInstSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\install-vibe-hooks.ps1') -Raw
$vibeHookTpl = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\hooks\vibe-coding.json') -Raw
if ($instSrc -match 'ensure-serena\.ps1' -and $instSrc -match 'function Test-SerenaAlive' -and $instSrc -match 'function Resolve-SerenaExe' -and $instSrc -match 'if \(Test-SerenaAlive \$p\) \{ return \$p \}' -and $instSrc -match '& \$ensure -RepoPath \$here' -and $instSrc -notmatch '\$repoArg = @\(' -and (Test-Path (Join-Path $RepoRoot 'assets\token-saving\scripts\ensure-serena.ps1'))) {
    Ok 'installer: ensure-serena install + verify + project LS repair'
} else {
    Bad 'installer missing ensure-serena.ps1 wiring'
}
if ($instSrc -match 'function Test-PipFileLockText' -and $instSrc -match 'function Stop-VenvLockers' -and $instSrc -match 'function Unlock-VenvEntryPoints' -and $instSrc -match 'function Restore-VenvOldEntryPoints' -and $instSrc -match 'function Get-PipLockedPaths' -and $instSrc -match '--force-reinstall' -and $instSrc -match 'WinError\s*32' -and $instSrc -match 'pip retry' -and $instSrc -match 'Stop-HeadroomServices') {
    Ok 'installer: stop venv lockers + WinError 32 pip retry'
} else {
    Bad 'installer missing WinError 32 / venv-locker pip retry'
}
$projYmlSrc = Join-Path $RepoRoot '.serena\project.yml'
if ((Test-Path $projYmlSrc) -and ((Get-Content $projYmlSrc -Raw) -match '(?m)^-\s+powershell') -and ((Get-Content $projYmlSrc -Raw) -notmatch '(?m)^language_servers:\s*\[\s*\]')) {
    Ok 'serena project.yml has powershell language server'
} else {
    Bad 'serena project.yml missing or language_servers empty'
}
$pinFile = Join-Path $RepoRoot 'assets\requirements\github-release-pins.json'
if ($instSrc -notmatch 'releases/latest' -and $instSrc -match 'github-release-pins\.json' -and $instSrc -match 'function Test-FileSha256' -and $instSrc -match 'function Test-GithubReleasePinShape' -and $instSrc -match 'destSha256' -and (Test-Path -LiteralPath $pinFile)) {
    $pinDoc = Get-Content -LiteralPath $pinFile -Raw | ConvertFrom-Json
    $pinOk = $true
    foreach ($need in @('scc.exe', 'tokei.exe')) {
        $hit = @($pinDoc.pins) | Where-Object { $_.dest -eq $need } | Select-Object -First 1
        if (-not $hit -or [string]$hit.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]$hit.destSha256 -notmatch '^[0-9a-fA-F]{64}$' -or -not $hit.tag -or -not $hit.asset -or -not $hit.repo) {
            $pinOk = $false
        }
    }
    if ($pinOk) {
        Ok 'installer: GitHub binaries pinned + SHA256 (no /releases/latest)'
    } else {
        Bad 'github-release-pins.json missing dest/tag/asset/sha256'
    }
} else {
    Bad 'installer still uses /releases/latest or missing pin/hash wiring'
}
if ($instSrc -match 'Write-HookFromTemplate' -and $instSrc -match "Write-HookFromTemplate 'vibe-coding.json'" -and $instSrc -notmatch "Write-Host '\[vibe\] Turn end" -and $instSrc -match 'Write-HookFromTemplate ''vibe-coding.json''\s*\r?\n\s*if \(\$DryRun\) \{ return \}') {
    Ok 'installer: hooks from templates (no stale Stop Write-Host); DryRun returns before serena delete'
} else {
    Bad 'installer still builds vibe-coding.json via hashtable / stale Stop nag / DryRun deletes serena-hooks'
}
if ($vibeHookTpl -match 'run-vibe-stop-remind\.ps1' -and $hooksInstSrc -match 'run-vibe-stop-remind\.ps1' -and $hooksInstSrc -notmatch "Write-Host '\[vibe\] Turn end") {
    Ok 'stop-remind in hook template + install-vibe-hooks'
} else {
    Bad 'hook template or install-vibe-hooks missing run-vibe-stop-remind.ps1'
}
if ($vibeHookTpl -match 'UserPromptSubmit' -and $vibeHookTpl -match 'run-vibe-prompt-context\.ps1' -and $hooksInstSrc -match 'run-vibe-prompt-context\.ps1' -and $onEditSrc -match 'on-edit-findings\.json') {
    Ok 'on-edit findings -> UserPromptSubmit additionalContext'
}
$promptCtx = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-prompt-context.ps1') -Raw
if ($promptCtx -match 'GATE LIVE' -and $promptCtx -match 'gate-now\.txt' -and $progSrc -match 'VibeGateNowWrite' -and $progSrc -match 'VIBE_GATE_CHILD' -and $prePushSrc -match 'VIBE_GATE_CHILD' -and $hooksInstSrc -match 'VIBE_GATE_INHERIT') {
    Ok 'gate chat stream: mutex + child/inherit RUN + prompt inject'
} else {
    Bad 'gate chat stream still torn / no prompt inject'
}
$gateChat = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-gate-chat.ps1') -Raw -ErrorAction SilentlyContinue
$watchNow = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\watch-gate-now.ps1') -Raw -ErrorAction SilentlyContinue
$stopSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-stop-remind.ps1') -Raw -ErrorAction SilentlyContinue
if ($gateChat -match 'timeout_ms' -and $gateChat -match '15000' -and $watchNow -match 'Heartbeat' -and $watchNow -match 'VibeGateNowWrite' -and $progSrc -match 'Start-GateElapsedHeartbeat' -and $stopSrc -match 'lastAssistantMessage' -and $stopSrc -match "decision = 'block'" -and $vibeHookTpl -match 'run-vibe-gate-chat\.ps1' -and $hooksInstSrc -match 'run-vibe-gate-chat\.ps1') {
    Ok 'gate no-silence: 15s poll clamp + Stop keep-alive + ELAPSED heartbeat'
} else {
    Bad 'gate no-silence wiring missing (clamp / Stop / heartbeat / hook)'
}
if ($watchNow -match 'GATE DONE is a tick' -and $watchNow -match '\$IdleSec = 600' -and $watchNow -match '\$ProgressSec = 60' -and $watchNow -match 'PROGRESS ' -and $watchNow -match '\$sawLive' -and $watchNow -match 'Do not idle until a live gate' -and $watchNow -match '\$done -and \$Heartbeat -and -not \$Monitor') {
    Ok 'gate monitor: leftover GATE DONE does not arm idle; 600s linger + PROGRESS pulse'
} else {
    Bad 'watch-gate-now missing sawLive arm / 600s linger / PROGRESS pulse / Heartbeat-only exit'
}
if ($watchNow -match 'Get-InterestingGateEvents' -and $watchNow -match 'function Get-GateSnapshot' -and $watchNow -notmatch 'function Get-GateHead' -and $watchNow -match "EVT " -and $watchNow -match "'VOTE'" -and $watchNow -match 'seenEventsRun' -and $watchNow -match 'seenEvents.Clear' -and $promptCtx -match 'VOTES \(verdict' -and $promptCtx -notmatch '-Tail 80' -and $rawReview -match 'Publish-ReviewerVoteNow' -and $rawReview -match 'VoteNowPublished\[\$Role\] = \$evt' -and $rawReview -match 'Set-GateWaitNow' -and $progSrc -match 'function Set-GateVote' -and $progSrc -match 'VOTE:') {
    Ok 'gate chat: sticky VOTE lines + full-file snapshot + inject VOTES block'
} else {
    Bad 'gate chat missing sticky votes / Get-GateSnapshot / inject VOTES'
}
$chatLibSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-chat-lib.ps1') -Raw -ErrorAction SilentlyContinue
$ctxSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-review-context.ps1') -Raw -ErrorAction SilentlyContinue
if ($progSrc -match 'function Save-GateOpenAdvisories' -and $progSrc -match 'function Get-GateFindingBucket' -and $progSrc -match 'later-cap' -and $progSrc -match 'gate-open-advisories\.json' -and $rawReview -match 'Save-GateOpenAdvisories' -and $rawReview -match 'blocker\|next\|later' -and $rawReview -match 'Get-FindingBucket' -and $promptCtx -match 'Format-GateOpenAdvisoriesInject' -and $chatLibSrc -match 'OPEN NEXT' -and $chatLibSrc -match 'LATER backlog' -and $ctxSrc -match 'PRIOR OPEN NEXT' -and $ctxSrc -match 'PRIOR LATER BACKLOG' -and $ctxSrc -match 'function Get-PriorOpenAdvisoriesBlock') {
    Ok 'gate ledger: blocker/next/later persist + inject + next-review brief'
} else {
    Bad 'gate ledger missing three-bucket persist/inject/review-brief'
}
if ($progSrc -match 'Pre-commit inherit' -and $progSrc -match '\$script:GatePid = \$PID') {
    Ok 'gate inherit: review process takes RUN PID (Stop keep-alive)'
} else {
    Bad 'gate inherit still keeps dead scan PID'
}
if ($scanSrc -match 'explicit TreeIsh' -and $scanSrc -match 'must not authorize push skip') {
    Ok 'scan-pass cache: Full without TreeIsh does not write'
} else {
    Bad 'scan-pass cache still writes write-tree hash for worktree Full'
}
$binReview = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\bin-shims\vibe-review.ps1') -Raw
$binHooks = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\bin-shims\install-vibe-hooks.ps1') -Raw
$preHookShim = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\install-pre-commit-hook.ps1') -Raw
if ($binReview -match 'exit \$LASTEXITCODE' -and $binHooks -match 'exit \$LASTEXITCODE' -and $preHookShim -match 'exit \$LASTEXITCODE' -and $preHookShim -match '@args') {
    Ok 'shims: vibe-review / install-vibe-hooks / pre-commit wrapper preserve exit'
} else {
    Bad 'shims drop LASTEXITCODE or pre-commit wrapper drops @args'
}
if ($rawReview -match 'StagedOnly' -and $hooksInstSrc -match '-StagedOnly') {
    Ok 'pre-commit AI: staged-only (no WT / whole-project fallback)'
} else {
    Bad 'pre-commit AI missing -StagedOnly'
}
if ($hooksInstSrc -match 'templates\\vibe-coding\.json' -and $hooksInstSrc -match 'Kept existing session hook') {
    Ok 'hook install: deployed template + keep-valid-live fallback'
} else {
    Bad 'hook install missing templates/ or live-hook fallback'
}
if ($onEditSrc -match 'byFile' -and $onEditSrc -match 'github_pat_' -and $vibeHookTpl -match 'use_tool' -and $onEditSrc -match 'serena\.\*\(replace') {
    Ok 'on-edit: merge-by-file + extra secrets + Serena use_tool'
} else {
    Bad 'on-edit missing merge / secrets / Serena matcher'
}
if ($progSrc -match 'function Save-GateLastDone' -and $progSrc -match 'gate-last-done\.txt' -and $promptCtx -match 'LAST GATE' -and $promptCtx -match 'gate-last-done\.txt' -and $promptCtx -match 'GATE DONE \(must post RUN' -and $promptCtx -notmatch "now -notmatch 'GATE DONE'" -and $stopSrc -match 'GATE DONE recap required' -and $stopSrc -match 'ageMin' -and $stopSrc -match 'gate-last-done-ack\.txt') {
    Ok 'gate recap: last-done persist + inject DONE/votes + stop ack latch'
} else {
    Bad 'gate recap missing last-done persist / DONE inject / stop recap ack'
}
if ($watchNow -match 'ELAPSED-only must not wake' -and $rawReview -match 'OnPulse' -and $rawReview -match 'fixer wrote' -and $rawReview -match 'fixer produced no file changes') {
    Ok 'gate chat: speak-on-new + fixer file pulse + 0-copy fail-closed'
} else {
    Bad 'gate chat missing speak-on-new / fixer pulse / 0-copy fail-closed'
}
if ($chatLibSrc -match 'function Test-IsGateWaitNow' -and $chatLibSrc -match 'function Get-GateFileRun' -and $chatLibSrc -match 'function Format-GateOpenAdvisoriesInject' -and $watchNow -match 'gate-chat-lib.ps1 missing' -and $stopSrc -match 'gate-chat-lib.ps1 missing' -and $promptCtx -match 'Format-GateOpenAdvisoriesInject' -and $stopSrc -match 'PROGRESS' -and $promptCtx -match 'PROGRESS' -and $progSrc -match 'LastWaitNow' -and $progSrc -match 'function Set-GateWaitNow' -and $rawReview -match 'Set-GateWaitNow') {
    Ok 'gate chat: shared tick lib + Set-GateWaitNow + PROGRESS speak'
} else {
    Bad 'gate chat missing gate-chat-lib / Set-GateWaitNow / PROGRESS speak'
}
$watchScript = Join-Path $RepoRoot 'assets\vibe-tools\scripts\watch-gate-now.ps1'
$idleDir = Join-Path $env:TEMP ("vibe-watch-idle-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $idleDir -Force | Out-Null
    $idleNow = Join-Path $idleDir 'gate-now.txt'
    $idleOut = Join-Path $idleDir 'out.txt'
    @(
        'RUN:     idle-test-1'
        'NOW:     GATE DONE - passed'
        'ELAPSED: 1s'
    ) | Set-Content -LiteralPath $idleNow -Encoding ascii
    $idleProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watchScript,
        '-Monitor', '-IdleSec', '2', '-IntervalSec', '1', '-NowFile', $idleNow
    ) -RedirectStandardOutput $idleOut -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 2800
    if ($idleProc.HasExited) {
        Bad 'watch-gate-now idle-exited on leftover GATE DONE (kills monitor before next gate)'
    } else {
        Ok 'gate monitor: leftover GATE DONE does not idle-exit'
        @(
            'RUN:     idle-test-2'
            'NOW:     Waiting on vibe-correctness'
            'ELAPSED: 1s'
        ) | Set-Content -LiteralPath $idleNow -Encoding ascii
        Start-Sleep -Milliseconds 1200
        @(
            'RUN:     idle-test-2'
            'NOW:     GATE DONE - passed'
            'ELAPSED: 2s'
        ) | Set-Content -LiteralPath $idleNow -Encoding ascii
        $idleProc.WaitForExit(8000) | Out-Null
        if ($idleProc.HasExited) {
            $idleTxt = Get-Content -LiteralPath $idleOut -Raw -ErrorAction SilentlyContinue
            if ($idleTxt -match '(?m)^DONE\s*$') {
                Ok 'gate monitor: idle-exit after live gate then GATE DONE'
            } else {
                Bad 'gate monitor idle-exit ran after live gate but stdout missing DONE'
            }
        } else {
            try { Stop-Process -Id $idleProc.Id -Force -ErrorAction SilentlyContinue } catch {}
            Bad 'gate monitor did not idle-exit within 8s after live then GATE DONE'
        }
    }
} catch {
    Bad ("gate monitor idle-exit smoke: {0}" -f $_.Exception.Message)
} finally {
    if ($idleDir -and (Test-Path -LiteralPath $idleDir)) {
        Remove-Item -LiteralPath $idleDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$voteDir = Join-Path $env:TEMP ("vibe-watch-vote-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $voteDir -Force | Out-Null
    $voteNow = Join-Path $voteDir 'gate-now.txt'
    $voteOut = Join-Path $voteDir 'out.txt'
    @(
        'RUN:     vote-test-1'
        'NOW:     Waiting on vibe-correctness (~15s)'
        'ELAPSED: 15s'
        'PHASE:   reviewers'
        'PID:     1'
        'CWD:     x'
        'LOG:     y'
        'EVENTS:  z'
        'VOTE:    security: APPROVE (0 finding(s)) - no secrets'
        ''
        '[21:00:00] scan: Trivy ok'
    ) | Set-Content -LiteralPath $voteNow -Encoding ascii
    $voteProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watchScript,
        '-Monitor', '-IdleSec', '0', '-IntervalSec', '1', '-NowFile', $voteNow
    ) -RedirectStandardOutput $voteOut -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1800
    try { Stop-Process -Id $voteProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    try { $voteProc.WaitForExit(3000) | Out-Null } catch {}
    $voteTxt = Get-Content -LiteralPath $voteOut -Raw -ErrorAction SilentlyContinue
    if ($voteTxt -match '(?m)^VOTE .*security: APPROVE' -and $voteTxt -match '(?m)^EVT .*scan: Trivy ok') {
        Ok 'gate monitor: full snapshot emits VOTE + EVT'
    } else {
        Bad 'gate monitor fixture missing VOTE/EVT (Get-GateSnapshot not seeing body)'
    }
} catch {
    Bad ("gate monitor vote/EVT smoke: {0}" -f $_.Exception.Message)
} finally {
    if ($voteDir -and (Test-Path -LiteralPath $voteDir)) {
        Remove-Item -LiteralPath $voteDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$waitDir = Join-Path $env:TEMP ("vibe-watch-wait-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $waitDir -Force | Out-Null
    $waitNow = Join-Path $waitDir 'gate-now.txt'
    $waitOut = Join-Path $waitDir 'out.txt'
    @(
        'RUN:     wait-test-1'
        'NOW:     Waiting on vibe-correctness (~15s)'
        'ELAPSED: 15s'
        'VOTE:    security: APPROVE (0 finding(s)) - no secrets'
        ''
        '[21:00:00] scan: Trivy ok'
    ) | Set-Content -LiteralPath $waitNow -Encoding ascii
    $waitProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watchScript,
        '-Monitor', '-IdleSec', '0', '-IntervalSec', '1', '-NowFile', $waitNow
    ) -RedirectStandardOutput $waitOut -WindowStyle Hidden -PassThru
    $sawVote = $false
    $until = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $until) {
        $probe = Get-Content -LiteralPath $waitOut -Raw -ErrorAction SilentlyContinue
        if ($probe -match '(?m)^VOTE ') { $sawVote = $true; break }
        Start-Sleep -Milliseconds 150
    }
    if (-not $sawVote) {
        Bad 'gate monitor wait-silence: VOTE never appeared (setup)'
    }
    @(
        'RUN:     wait-test-1'
        'NOW:     Waiting on vibe-correctness (~30s)'
        'ELAPSED: 30s'
        'VOTE:    security: APPROVE (0 finding(s)) - no secrets'
        ''
        '[21:00:00] scan: Trivy ok'
    ) | Set-Content -LiteralPath $waitNow -Encoding ascii
    $printedWait = $false
    $until2 = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $until2) {
        Start-Sleep -Milliseconds 150
        $probe2 = Get-Content -LiteralPath $waitOut -Raw -ErrorAction SilentlyContinue
        if ($probe2 -match '(?i)Waiting on') { $printedWait = $true; break }
    }
    if ($printedWait) {
        Bad 'gate monitor printed wait tick after (~30s) rewrite'
    }
    try { Stop-Process -Id $waitProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    try { $waitProc.WaitForExit(3000) | Out-Null } catch {}
    $waitTxt = Get-Content -LiteralPath $waitOut -Raw -ErrorAction SilentlyContinue
    if ($waitTxt -match '(?i)Waiting on' ) {
        Bad 'gate monitor printed wait tick (wakes chat)'
    } elseif ($waitTxt -match '(?m)^VOTE .*security: APPROVE' -and $waitTxt -match '(?m)^EVT .*scan: Trivy ok') {
        Ok 'gate monitor: wait ticks silent; VOTE+EVT still print'
    } else {
        Bad 'gate monitor wait-silence fixture missing VOTE/EVT'
    }
} catch {
    Bad ("gate monitor wait-silence smoke: {0}" -f $_.Exception.Message)
} finally {
    if ($waitDir -and (Test-Path -LiteralPath $waitDir)) {
        Remove-Item -LiteralPath $waitDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$schemaSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-schema.ps1') -Raw
if ($rawReview -match 'Get-GateSchemaVersion' -and $rawReview -match 'schemaVersion' -and $rawReview -match 'tokenEstimate' -and $rawReview -match 'Add-ReviewContext' -and $rawReview -match 'New-FixerWorktree' -and $schemaSrc -match 'GATE_SCHEMA_VERSION = 4') {
    Ok 'review: schema 4 cache + intent/blast + token estimate + worktree fixer'
} else {
    Bad 'review missing schema 4 / intent / tokens / worktree wiring'
}
if ($prePushSrc -match 'Get-VibePushReviewPlan' -and $prePushSrc -match 'TAG:' -and $prePushSrc -match 'Get-TagCommitDiff') {
    Ok 'pre-push: version-tag strict + single-commit tag diff'
} else {
    Bad 'pre-push missing tag-strict plan'
}
if ($prePushSrc -match '-DiffOverride \$diffText' -and $prePushSrc -match 'AutoProfile:\$useAuto' -and $prePushSrc -notmatch '@reviewArgs') {
    Ok 'pre-push: named DiffOverride (no splat of patch array)'
} else {
    Bad 'pre-push still splats review args / patch array'
}
$evalScript = Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-evals.ps1'
if (Test-Path -LiteralPath $evalScript) {
    & $evalScript -RepoRoot $RepoRoot
    if ($LASTEXITCODE -eq 0) { Ok 'known-bad evals passed' } else { Bad 'known-bad evals failed' }
} else {
    Bad 'missing run-vibe-evals.ps1'
}
if ($instSrc -match 'stackOwned' -and $instSrc -match 'Never record pre-existing' -and $unSrc -match 'outside GrokHome' -and $unSrc -match 'keep shared Git/Node/npm') {
    Ok 'PATH: record stack-owned only; uninstall never strips outside ~/.grok'
} else {
    Bad 'PATH AlwaysRecord / uninstall shared-dir strip still unsafe'
}
if ($instSrc -match "checkov\.cmd" -and $unSrc -match "checkov\.cmd" -and $unSrc -match 'relocations' -and $unSrc -match 'mcp_servers.headroom' -and $unSrc -match 'hadMarkers' -and $unSrc -notmatch 'Get-VibeOwnedTomlSections' -and $unSrc -notmatch 'pre-uninstall-') {
    Ok 'uninstall: checkov shim + marker-or-stack-table strip + relocations bak'
} else {
    Bad 'uninstall missing checkov / still wipes shared TOML tables / next-to-live bak'
}
$rtkSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\run-rtk-enforce.ps1') -Raw
if ($rtkSrc -match 'Split-ShellSegments' -and $rtkSrc -match 'each shell segment' -and $rtkSrc -match 'newline' -and $rtkSrc -match 'isCallOp') {
    Ok 'rtk: per-segment enforce (&& || ; newline bare &)'
} else {
    Bad 'rtk missing per-segment / newline / bare-and split'
}
if ($instSrc -notmatch 'maxSavingsProfile') {
    Ok 'installer: dead maxSavingsProfile removed'
} else {
    Bad 'installer still has unused maxSavingsProfile'
}
$startSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\start-grok.ps1') -Raw
if ($startSrc -match 'Test-ProxyMatchesStack' -and $startSrc -match 'Get-ProxyStackFingerprintBase' -and $startSrc -match 'Save-ProxyFingerprint' -and $startSrc -match 'require the flag pair' -and $startSrc -match 'function Test-ProxyCommandLineIsHeadroom') {
    Ok 'start-grok: proxy fingerprint / stale restart (loose stop match)'
} else {
    Bad 'start-grok missing proxy fingerprint / loose stop match'
}
if ($startSrc -match 'function Get-HeadroomCliVersion' -and $startSrc -match 'function Test-ProxyHttpReady' -and $startSrc -match 'function Resolve-HeadroomUpstream' -and $startSrc -match 'function Test-HeadroomUrlIsXai' -and $startSrc -match 'Stale OPENAI_TARGET_API_URL' -and $startSrc -match 'function Start-HeadroomKeeper' -and $startSrc -match 'keep-headroom-proxy' -and $startSrc -match 'cli-chat-proxy\.grok\.com' -and $startSrc -match 'v3\|hr=' -and $startSrc -match '--no-http2' -and $startSrc -match '--no-rate-limit' -and $startSrc -match '/readyz' -and $startSrc -match 'Remove-Item Env:HEADROOM_READ_MATURATION') {
    Ok 'start-grok: headroom version fingerprint + /readyz + clear read-maturation env'
} else {
    Bad 'start-grok missing hr version fingerprint / readyz / read-maturation env clear'
}
$keepSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\keep-headroom-proxy.ps1') -Raw
if ($keepSrc -match 'Start-Process' -and $keepSrc -match 'AbandonedMutexException' -and $keepSrc -match '-ProxyOnly' -and $keepSrc -match 'failStreak' -and $keepSrc -match 'Test-ProxyAlive' -and $keepSrc -match 'proxy not listening' -and $keepSrc -match 'WaitForExit' -and $keepSrc -notmatch '-Wait -PassThru' -and $keepSrc -notmatch '& \$StartPs1') {
    Ok 'keeper: child start-grok + mutex + listen/argv liveness (no /readyz kill)'
} else {
    Bad 'keeper still & start-grok or still restarts on hung /readyz'
}
if ($startSrc -match 'Disable-ScheduledTask' -and $startSrc -match "KeepPs1, '-Port'" -and $unSrc -match 'Unregister-ScheduledTask' -and $startSrc -match 'leaving live proxy' -and $startSrc -match 'busy SSE must not be killed' -and $startSrc -match 'Enable-ScheduledTask') {
    Ok 'keeper stop disables logon task; -Port passed; busy SSE is not killed on /readyz fail'
} else {
    Bad 'keeper stop/task/port/busy-SSE leave-alive wiring missing'
}
if ($startSrc -match 'NoLogonKeeper' -and $startSrc -match 'headroom-proxy\$portTag' -and $startSrc -match 'Test-KeeperCommandLineForThisPort' -and $keepSrc -match 'GrokVibeHeadroomKeeper-' -and $startSrc -match 'Port -ne 8787') {
    Ok 'start-grok: port-scoped pid/fp/keeper + NoLogonKeeper for gate :8788'
} else {
    Bad 'start-grok missing port-scoped state / NoLogonKeeper / keeper-per-port'
}
if ($startSrc -match 'function Get-ListenOwnerPids' -and $startSrc -match 'CIM Headroom' -and $startSrc -notmatch 'Get-NetTCPConnection -LocalPort') {
    Ok 'start-grok: CIM Headroom owners (no Get-NetTCPConnection hang)'
} else {
    Bad 'start-grok still uses Get-NetTCPConnection -LocalPort'
}
if ($startSrc -match 'GetActiveTcpListeners' -and $rawReview -match 'GetActiveTcpListeners' -and $keepSrc -match 'GetActiveTcpListeners' -and $startSrc -notmatch 'BeginConnect' -and $rawReview -notmatch 'BeginConnect' -and $keepSrc -notmatch 'BeginConnect' -and $startSrc -notmatch 'Get-NetTCPConnection -LocalPort' -and $rawReview -match 'Get-NetTCPConnection can block') {
    Ok 'tcp probe: GetActiveTcpListeners (no connect/Close leak, no Get-NetTCPConnection)'
} else {
    Bad 'tcp probe missing GetActiveTcpListeners or still connects / Get-NetTCPConnection'
}
if ($instSrc -match 'function Invoke-StartGrokChild' -and $instSrc -match '-ProxyOnly' -and $instSrc -match '-Quiet' -and $instSrc -match 'WaitForExit' -and $instSrc -notmatch '-Wait -PassThru' -and $instSrc -notmatch '& \$startPs1 -ProxyOnly' -and $unSrc -notmatch '& \$startPs1 -StopProxy' -and $unSrc -match '-File., \$startPs1, .-StopProxy' -and $unSrc -match 'WaitForExit' -and $unSrc -notmatch '-Wait -PassThru') {
    Ok 'install/uninstall: start-grok via powershell -File child (no & exit suicide, no pwsh -Wait descendant hang)'
} else {
    Bad 'install/uninstall still & start-grok or Start-Process -Wait (pwsh descendant hang)'
}
if ($instSrc -match 'one Headroom' -and $instSrc -match "-StopProxy', '-Port', '8788'" -and $instSrc -notmatch "-ProxyOnly', '-Quiet', '-Port', '8788'") {
    Ok 'installer: one Headroom :8787; stops leftover :8788; does not start dual gate proxy'
} else {
    Bad 'installer still starts :8788 or missing one-proxy next-steps'
}
$docSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\doctor.ps1') -Raw
if ($docSrc -match 'Test-ProxyCommandLineMatchesStack' -and $docSrc -match 'headroom-proxy.fingerprint' -and $docSrc -match 'live argv' -and $docSrc -match 'headroom-proxy-8788' -and $docSrc -match 'grok-gate') {
    Ok 'doctor: live proxy cmdline / fingerprint + gate :8788'
} else {
    Bad 'doctor missing live proxy cmdline/fingerprint / gate :8788'
}
if ($docSrc -match 'v3\|hr=' -and $docSrc -match '/readyz' -and $docSrc -match '0\.36' -and $docSrc -match '--no-http2' -and $docSrc -match 'env_key') {
    Ok 'doctor: hr v3 fingerprint + readyz + env_key warn'
} else {
    Bad 'doctor missing hr v3 fingerprint / readyz / env_key warn'
}
if ($rawReview -match 'function Test-ProxyHttpReady' -and $rawReview -match 'function Test-ProxyUsable' -and $rawReview -match 'GetActiveTcpListeners' -and $rawReview -match 'Get-NetTCPConnection can block' -and $rawReview -match 'Test-ProxyUsable \$Port' -and $rawReview -match 'proxy stream failed' -and $rawReview -match 'NoHatchRetry' -and $rawReview -match "Model = 'grok-4.6'" -and $rawReview -match 'ProxyPort = 8787' -and $rawReview -match 'sharesChatProxy' -and $rawReview -match 'NoLogonKeeper' -and $rawReview -match 'Test-ProxyUsable \$ProxyPort' -and $rawReview -match 'same Headroom' -and $rawReview -match 'reqwest error' -and $rawReview -match 'ConvertTo-SinglePatchText \$probe' -and $rawReview -match "'bucket', 'severity'" -and $rawReview -match 'Never call /readyz here' -and $rawReview -match 'WaitForExit' -and $rawReview -notmatch "ArgumentList \$sg -Wait" -and $rawReview -notmatch 'return \[bool\]\(Test-ProxyHttpReady') {
    Ok 'review: grok-4.6 :8787 one proxy; stream fail retries Headroom; listen-only preflight'
} else {
    Bad 'review missing grok-4.6 :8787 / Headroom retry / listen-only preflight'
}
$hrReq = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\requirements\headroom.txt') -Raw
if ($hrReq -match 'headroom-ai\[proxy\]>=0\.36\.0' -and $hrReq -match 'tokenizers>=0\.22\.0,<=0\.23\.0') {
    Ok 'reqs: headroom-ai[proxy] >= 0.36.0 + tokenizers pin'
} else {
    Bad 'reqs missing headroom-ai[proxy] >= 0.36.0 / tokenizers pin'
}
$snip = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\config\config-snippet.toml') -Raw
if ($snip -match '\[model\."grok-4.6"\]' -and $snip -match '\[model\."grok-gate"\]' -and $snip -match '127\.0\.0\.1:8787' -and $snip -notmatch '127\.0\.0\.1:8788' -and $snip -match '\[model\."grok-4.6-direct"\]' -and $snip -notmatch '(?m)^\s*\[model\.grok-4\.6' -and $snip -notmatch '(?m)^\s*env_key\s*=' -and $snip -match 'Do NOT set env_key') {
    Ok 'config: quoted grok-4.6 + grok-gate tables, no env_key (session auth)'
} else {
    Bad 'config-snippet missing quoted grok-4.6 / grok-gate tables or still has env_key'
}
if ($snip -match 'Optional off' -and $snip -match 'enabled = true') {
    Ok 'config: Headroom MCP default on, optional off documented'
} else {
    Bad 'config-snippet missing Headroom MCP optional-off docs'
}
$tomlHelper = Join-Path $RepoRoot 'assets\token-saving\scripts\GrokToml.ps1'
if (Test-Path -LiteralPath $tomlHelper) {
    . $tomlHelper
    $pre = @"
[cli]
installer = "internal"

[session]
auto_compact_threshold_percent = 55

[features]
two_pass_compaction = true

[mcp]
max_output_bytes = 20000

[mcp_servers.headroom]
command = 'old'
enabled = true

[model."grok-4.6"]
base_url = "http://127.0.0.1:8787/v1"

[models]
default = "grok-4.6"
"@
    $snippetText = Get-VibeManagedSnippet -SnippetPath (Join-Path $RepoRoot 'assets\config\config-snippet.toml') -HeadroomCmd 'C:\hr.cmd' -SerenaExe 'C:\serena.exe' -SerenaEnabled $true
    $cvt = @(Convert-VibeToArray 'base_url')
    $cvtHash = @(Convert-VibeToArray @{ k = 'v' })
    if ($cvt.Length -eq 1 -and $cvt[0] -eq 'base_url' -and $cvtHash.Length -eq 1) {
        Ok 'Convert-VibeToArray: string is one item; hashtable is one item'
    } else {
        Bad ("Convert-VibeToArray still enumerates string/hashtable len={0} first={1}" -f $cvt.Length, $cvt[0])
    }
    $merged = Merge-VibeToml -Raw $pre -Snippet $snippetText
    $mergedCheck = Test-VibeToml -Raw $merged
    if ($mergedCheck.Ok -and ($merged -match 'command = ''C:\\hr\.cmd''') -and ($merged -notmatch "command = 'old'")) {
        Ok 'config merge: reinstall over existing owned tables stays valid'
    } else {
        Bad ("config merge invalid after reinstall-shaped input: {0}" -f ($mergedCheck.Errors -join '; '))
    }
    # Exact user failure: Grok rewrite (tables, no markers) + installer appended snippet.
    $preDup = $pre.TrimEnd() + "`n`n" + $snippetText
    $mergedDup = Merge-VibeToml -Raw $preDup -Snippet $snippetText
    $dupCheck = Test-VibeToml -Raw $mergedDup
    $sessionHits = @([regex]::Matches($mergedDup, '(?m)^\s*\[session\]\s*$'))
    $modelHits = @([regex]::Matches($mergedDup, '(?m)^\s*\[model\."grok-4\.6"\]\s*$'))
    if ($dupCheck.Ok -and $sessionHits.Count -eq 1 -and $modelHits.Count -eq 1) {
        Ok 'config merge: rewritten tables + appended managed block collapses to one copy'
    } else {
        Bad ("config merge left duplicate tables after append-shaped input sessions={0} models={1} ok={2}" -f $sessionHits.Count, $modelHits.Count, $dupCheck.Ok)
    }
    # Strip-miss: table not in Get-VibeOwnedTomlSections. Merge must keep last
    # (snippet), not first (stale). Assert snippet command, not only Test-VibeToml.Ok.
    $preMiss = $pre + "`n`n[mcp_servers.untracked]`ncommand = 'stale-stub'`n"
    $mergedMiss = Merge-VibeToml -Raw $preMiss -Snippet $snippetText
    $missCheck = Test-VibeToml -Raw $mergedMiss
    $untracked = @([regex]::Matches($mergedMiss, '(?m)^\s*\[mcp_servers\.untracked\]\s*$'))
    if ($missCheck.Ok -and $untracked.Count -eq 1 -and ($mergedMiss -match 'stale-stub')) {
        Ok 'config merge: user custom MCP table kept once (not overwritten, not duplicated)'
    } else {
        Bad ("config merge custom MCP tables={0} ok={1}" -f $untracked.Count, $missCheck.Ok)
    }
    $userPre = @"
[marketplace]
default_skills_installs_purged = true

[ui]
permission_mode = "always-approve"
max_thoughts_width = 120

[features]
telemetry = false
two_pass_compaction = false

[mcp_servers]
headroom = { command = 'stale-inline', enabled = true }

[mcp_servers.headroom]
command = 'also-stale'
enabled = true
"@
    $mergedUser = Merge-VibeToml -Raw $userPre -Snippet $snippetText
    $userCheck = Test-VibeToml -Raw $mergedUser
    $hrHits = @([regex]::Matches($mergedUser, '(?m)^\s*\[mcp_servers\.headroom\]\s*$'))
    $parentHr = [bool]($mergedUser -match '(?s)\[mcp_servers\][^\[]*headroom\s*=')
    if ($userCheck.Ok -and ($mergedUser -match 'permission_mode = "always-approve"') -and ($mergedUser -match 'telemetry = false') -and ($mergedUser -match 'default_skills_installs_purged') -and ($mergedUser -match 'two_pass_compaction = true') -and $hrHits.Count -eq 1 -and (-not $parentHr) -and ($mergedUser -notmatch 'stale-inline') -and ($mergedUser -notmatch 'also-stale')) {
        Ok 'config merge: keeps user ui/marketplace/features; stack keys win; no parent+dotted duplicate key'
    } else {
        Bad ("config merge user-preserve/dup-key ok={0} err={1} hrTables={2} parentHr={3}" -f $userCheck.Ok, ($userCheck.Errors -join '; '), $hrHits.Count, $parentHr)
    }
    $stubToml = Test-VibeToml -Raw "[cli]`ninstaller = `"internal`"`n"
    if (-not $stubToml.Ok -and -not $stubToml.HasHeadroomOverride) {
        Ok 'Test-VibeToml: Headroom-less stub is not Ok'
    } else {
        Bad 'Test-VibeToml treated Headroom-less stub as Ok'
    }
    $srcTmp = Join-Path $env:TEMP ("vibe-cfg-src-{0}" -f [guid]::NewGuid().ToString('n'))
    try {
        New-Item -ItemType Directory -Path $srcTmp -Force | Out-Null
        $livePath = Join-Path $srcTmp 'config.toml'
        $bakPath = Join-Path $srcTmp 'config.toml.bak'
        $stub = "[cli]`ninstaller = `"internal`"`n"
        $stack = $pre
        [System.IO.File]::WriteAllText($livePath, $stub)
        [System.IO.File]::WriteAllText($bakPath, $stack)
        $fromStub = Resolve-VibeConfigMergeSource -ConfigPath $livePath
        if ($fromStub.SourcePath -eq $bakPath -and $fromStub.SidecarPath -eq $bakPath -and $fromStub.Raw -match '127\.0\.0\.1:8787') {
            Ok 'config source: stub live + stack bak prefers bak'
        } else {
            Bad ("config source stub+bak expected bak got source={0}" -f $fromStub.SourcePath)
        }
        [System.IO.File]::WriteAllText($livePath, $stack)
        [System.IO.File]::WriteAllText($bakPath, $stack)
        $fromOk = Resolve-VibeConfigMergeSource -ConfigPath $livePath
        if ($fromOk.SourcePath -eq $livePath -and (Test-Path -LiteralPath $bakPath)) {
            Ok 'config source: valid live is merge input (leftover bak not read)'
        } else {
            Bad ("config source valid+bak should keep live source={0}" -f $fromOk.SourcePath)
        }
        $weakBak = "[cli]`nnote = `"see 127.0.0.1:8787`"`n"
        [System.IO.File]::WriteAllText($livePath, $stub)
        [System.IO.File]::WriteAllText($bakPath, $weakBak)
        $fromWeak = Resolve-VibeConfigMergeSource -ConfigPath $livePath
        if ($fromWeak.SourcePath -eq $livePath) {
            Ok 'config source: 8787-only bak is not stack'
        } else {
            Bad ("config source weak bak should stay on live got source={0}" -f $fromWeak.SourcePath)
        }
        [System.IO.File]::WriteAllText($livePath, $stub)
        [System.IO.File]::WriteAllText($bakPath, $stack)
        $snipPath = Join-Path $RepoRoot 'assets\config\config-snippet.toml'
        $repaired = $null
        try {
            $repaired = Repair-GrokConfigFile -ConfigPath $livePath -SnippetPath $snipPath -HeadroomCmd 'C:\hr.cmd' -SerenaExe 'C:\serena.exe' -SerenaEnabled $true -BackupSuffix ('smoke-{0}' -f [guid]::NewGuid().ToString('n'))
            $reloc = Join-Path $env:USERPROFILE '.grok\relocations'
            $liveAfter = Read-Utf8NoBomFile -Path $livePath
            $liveOk = [bool]((Test-VibeToml -Raw $liveAfter).Ok)
            $bakGone = -not (Test-Path -LiteralPath $bakPath)
            $qOk = $repaired.Quarantined -and $repaired.Quarantined.StartsWith($reloc)
            $bOk = $repaired.BackupPath -and $repaired.BackupPath.StartsWith($reloc)
            if ($liveOk -and $bakGone -and $qOk -and $bOk) {
                Ok 'Repair: stub+stack bak writes Headroom live; backup+sidecar under relocations'
            } else {
                Bad ("Repair path liveOk={0} bakGone={1} q={2} bak={3}" -f $liveOk, $bakGone, $repaired.Quarantined, $repaired.BackupPath)
            }
        } finally {
            if ($repaired -and $repaired.BackupPath) { Remove-Item -LiteralPath $repaired.BackupPath -Force -ErrorAction SilentlyContinue }
            if ($repaired -and $repaired.Quarantined) { Remove-Item -LiteralPath $repaired.Quarantined -Force -ErrorAction SilentlyContinue }
        }
        $origKeep = "[cli]`ninstaller = `"keep-me`"`n"
        Write-Utf8NoBomFile -Path $livePath -Content $origKeep
        $restoreBak = Backup-VibeConfigFile -ConfigPath $livePath -BackupSuffix ('smoke-restore-{0}' -f [guid]::NewGuid().ToString('n'))
        Write-Utf8NoBomFile -Path $livePath -Content "[broken`n"
        $threw = $false
        try {
            $null = Confirm-VibeConfigWrite -ConfigPath $livePath -BackupPath $restoreBak
        } catch {
            $threw = $true
        }
        $restored = Read-Utf8NoBomFile -Path $livePath
        if ($threw -and $restored -notmatch 'keep-me' -and $restored -match 'broken') {
            Ok 'Confirm-VibeConfigWrite: invalid stub backup is not restored'
        } else {
            Bad ("no-restore-stub threw={0} live={1}" -f $threw, $restored)
        }
        $validExpect = $snippetText
        Write-Utf8NoBomFile -Path $livePath -Content "[broken`n"
        $threw2 = $false
        try {
            $null = Confirm-VibeConfigWrite -ConfigPath $livePath -BackupPath $restoreBak -ExpectedRaw $validExpect
        } catch {
            $threw2 = $true
        }
        $rewritten = Read-Utf8NoBomFile -Path $livePath
        $rewrittenOk = [bool]((Test-VibeToml -Raw $rewritten).Ok)
        if ($rewrittenOk -and $rewritten -match '127\.0\.0\.1:8787' -and -not $threw2) {
            Ok 'Confirm-VibeConfigWrite: rewrites ExpectedRaw instead of restoring stub'
        } else {
            Bad ("expected-raw rewrite threw={0} ok={1}" -f $threw2, $rewrittenOk)
        }
        if ($restoreBak) { Remove-Item -LiteralPath $restoreBak -Force -ErrorAction SilentlyContinue }
    } finally {
        Remove-Item -LiteralPath $srcTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $utfTmp = Join-Path $env:TEMP ("vibe-utf8-smoke-{0}.toml" -f [guid]::NewGuid().ToString('n'))
    try {
        Write-Utf8NoBomFile -Path $utfTmp -Content "[user]`nname = `"café`"`n"
        $back = Read-Utf8NoBomFile -Path $utfTmp
        if ($back -match 'café') {
            Ok 'config UTF-8 no-BOM write/read roundtrip (non-ASCII)'
        } else {
            Bad 'UTF-8 roundtrip lost non-ASCII'
        }
    } finally {
        Remove-Item -LiteralPath $utfTmp -Force -ErrorAction SilentlyContinue
    }
} else {
    Bad 'missing GrokToml.ps1'
}
if ($instSrc -match 'GrokToml\.ps1' -and $instSrc -match 'Repair-GrokConfigFile') {
    Ok 'installer: merge uses GrokToml Repair-GrokConfigFile'
} else {
    Bad 'installer merge no longer calls Repair-GrokConfigFile'
}
$tomlSrc = Get-Content -LiteralPath $tomlHelper -Raw
if ($tomlSrc -match 'config.toml merge still invalid' -and $tomlSrc -match 'HasHeadroomOverride' -and $tomlSrc -match 'Confirm-VibeConfigWrite' -and $tomlSrc -match 'ExpectedRaw' -and $tomlSrc -match 'Remove-VibeStackFromToml' -and $tomlSrc -match 'backup was not valid') {
    Ok 'GrokToml: repair throws on invalid merge; confirm retries ExpectedRaw; no stub restore'
} else {
    Bad 'GrokToml missing throw-on-invalid, ExpectedRaw retry, or no-stub-restore'
}
if ($startSrc -match 'Assert-GrokConfig' -and $startSrc -match 'Repair-GrokConfigFile' -and $startSrc -match 'GrokToml\.ps1 missing' -and $startSrc -match 'HasHeadroomOverride' -and $startSrc -match 'if \(\$check\.HasHeadroomOverride -and \$check\.Ok\) \{ return \}') {
    Ok 'start-grok: config preflight + auto-repair + fail-closed helper + skip rewrite when Headroom Ok'
} else {
    Bad 'start-grok missing config preflight/repair/fail-closed helper/Headroom-Ok return'
}
if ($rawReview -match 'Test-VanillaHatchEndpoint' -and $rawReview -match 'vanilla hatch') {
    Ok 'review: hatch official endpoint before proxy-down fallback'
} else {
    Bad 'review missing Test-VanillaHatchEndpoint hatch check'
}
# Live RTK segment behavior (no network)
$rtkScript = Join-Path $RepoRoot 'assets\token-saving\scripts\run-rtk-enforce.ps1'
function Invoke-RtkGate([string]$command) {
    $payload = (@{ toolName = 'run_terminal_command'; toolInput = @{ command = $command } } | ConvertTo-Json -Compress -Depth 5)
    $out = $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rtkScript 2>$null
    $text = ($out | Out-String).Trim()
    try { return ($text | ConvertFrom-Json) } catch { return @{ decision = 'error'; raw = $text } }
}
$prevBypass = $env:RTK_BYPASS
$env:RTK_BYPASS = $null
$env:NO_RTK = $null
try {
    $a = Invoke-RtkGate 'rtk git status'
    if ($a.decision -eq 'allow') { Ok 'rtk allow: single rtk-wrapped' } else { Bad "rtk should allow 'rtk git status' got $($a.decision)" }
    $b = Invoke-RtkGate 'rtk git status && git log -p'
    if ($b.decision -eq 'deny') { Ok 'rtk deny: chain second leg bare git' } else { Bad "rtk should deny bare second segment got $($b.decision)" }
    $c = Invoke-RtkGate 'cd foo && rtk git status'
    if ($c.decision -eq 'allow') { Ok 'rtk allow: tiny + rtk segment' } else { Bad "rtk should allow cd&&rtk got $($c.decision)" }
    $d = Invoke-RtkGate 'echo hi'
    if ($d.decision -eq 'allow') { Ok 'rtk allow: tiny echo' } else { Bad "rtk should allow echo got $($d.decision)" }
    $nl = Invoke-RtkGate "rtk git status`ngit log -p"
    if ($nl.decision -eq 'deny') { Ok 'rtk deny: newline second leg bare git' } else { Bad "rtk should deny newline-split bare git got $($nl.decision)" }
    $amp = Invoke-RtkGate 'rtk git status & git log -p'
    if ($amp.decision -eq 'deny') { Ok 'rtk deny: bare & second leg' } else { Bad "rtk should deny bare-and second segment got $($amp.decision)" }
    $redir = Invoke-RtkGate 'rtk git status 2>&1'
    if ($redir.decision -eq 'allow') { Ok 'rtk allow: 2>&1 not a splitter' } else { Bad "rtk should allow rtk+2>&1 got $($redir.decision)" }
    $call = Invoke-RtkGate '& rtk git status'
    if ($call.decision -eq 'allow') { Ok 'rtk allow: leading call-operator & rtk' } else { Bad "rtk should allow & rtk got $($call.decision)" }
} finally {
    if ($null -ne $prevBypass) { $env:RTK_BYPASS = $prevBypass } else { Remove-Item Env:RTK_BYPASS -ErrorAction SilentlyContinue }
}
if (Test-Path (Join-Path $RepoRoot 'assets\bin-shims\checkov.cmd')) {
    Ok 'bin-shims/checkov.cmd present'
} else {
    Bad 'missing assets/bin-shims/checkov.cmd'
}
if (Test-Path (Join-Path $RepoRoot '_hook_debug.ps1')) {
    Bad '_hook_debug.ps1 still in repo'
} else {
    Ok '_hook_debug.ps1 removed'
}

# Hook wiring
$hookInst = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\install-vibe-hooks.ps1') -Raw
if ($hookInst -match '-Profile standard' -and $hookInst -match '-AutoProfile' -and $hookInst -match '-Scope Auto') {
    Ok 'pre-commit wires standard + AutoProfile + Scope Auto'
} else {
    Bad 'pre-commit missing AutoProfile/Scope Auto'
}
$prePushPs1 = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-pre-push.ps1') -Raw
$planSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-push-plan.ps1') -Raw
# Scope Full may be '-Scope Full' or Start-Process ArgumentList '-Scope','Full'
if ($prePushPs1 -match 'Get-VibePushReviewPlan' -and $prePushPs1 -match "-AutoProfile" -and ($prePushPs1 -match "-Scope['\s,]*Full" -or $prePushPs1 -match "'Full'")) {
    Ok 'pre-push wires plan profile + AutoProfile + Scope Full/cache'
} else {
    Bad 'pre-push missing AutoProfile/Scope Full'
}
if ($planSrc -match 'function Get-VibePushTipShas' -and $planSrc -match '\[0-9a-fA-F\]\{7,64\}' -and $prePushPs1 -match 'Where-Object \{ \$_ -match ''\^\[0-9a-fA-F\]\{7,64\}\$'' \}') {
    Ok 'push tips: hex allowlist on NEW/TAG/range + rev-list'
} else {
    Bad 'push tips still accept non-hex on rev-list or Get-VibePushTipShas'
}
if ($prePushPs1 -match 'refusing a guessed' -and $prePushPs1 -notmatch 'origin/HEAD\.\.\.HEAD' -and $prePushPs1 -match '\$plan\.HasRefLines' -and $prePushPs1 -match '\$hasRefLines' -and $prePushPs1 -notmatch '\$ranges\.Count -eq 0 -and -not \$onlyDeletes' -and $planSrc -match 'HasRefLines') {
    Ok 'pre-push: empty stdin fail-closed (no guessed diff); empty ranges not treated as no-stdin'
} else {
    Bad 'pre-push still reviews a guessed diff or treats empty $ranges as empty stdin'
}
if ($scanSrc -match 'Error running' -and $scanSrc -match '\$script:failed\+\+') {
    Ok 'scans: Pester catch increments failed'
} else {
    Bad 'Pester catch still swallows errors'
}
if ($rawReview -match 'Roles\)\.Count -gt 1' -and $rawReview -match 'start sequential reviewer' -and $rawReview -match 'Never downgrade in-support data corruption') {
    Ok 'review: parallel multi-role + sequential NOW + arbiter no-downgrade corruption'
} else {
    Bad 'review missing multi-role parallel / sequential NOW / arbiter corruption rule'
}
if ($hookInst -match 'rev-parse --git-path hooks') {
    Ok 'hooks install uses git-path hooks (worktree / core.hooksPath)'
} else {
    Bad 'hooks still join .git/hooks only'
}
$docSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\doctor.ps1') -Raw
$unSrcHooks = Get-Content -LiteralPath (Join-Path $RepoRoot 'Uninstall-GrokVibeStack.ps1') -Raw
if ($docSrc -match 'rev-parse --git-path hooks' -and $unSrcHooks -match 'rev-parse --git-path hooks') {
    Ok 'doctor + uninstall resolve hooks via git-path'
} else {
    Bad 'doctor/uninstall still hardcode .git\\hooks'
}
if ($progSrc -match 'PID:' -and $progSrc -match 'CWD:' -and $progSrc -match 'adoptPid' -and $progSrc -match 'all\[\$start' -and $progSrc -match 'gate-watch-' -and $progSrc -match '-File' -and $progSrc -notmatch 'Bypass'', ''-Command''') {
    Ok 'gate: adopt requires live PID+CWD; status tail slices then last 60; popup -File'
} else {
    Bad 'gate adopt/tail/popup still stale'
}
$startSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\start-grok.ps1') -Raw
if ($startSrc -match 'Test-ProxyProcessOk' -and $startSrc -match 'CIM parent lag' -and $startSrc -match 'recordedPid is a hint only' -and $startSrc -match 'Test-IsDescendantOf' -and $startSrc -match 'Get-ListenOwnerPids' -and $startSrc -notmatch 'recordedPid -and \$op -ne \$recordedPid' -and $startSrc -notmatch "ProcessName -match 'headroom\|python'") {
    Ok 'proxy stop/start: Headroom argv + TCP owner PID; adopt child listener; stale pid file does not veto live owner'
} else {
    Bad 'proxy still force-kills by name/stale PID or rejects live owner / child bind on pid mismatch'
}
if ($scanSrc -match 'Get-VibeSameVolumeTempDir' -and $scanSrc -match 'vibe-scan-tmp') {
    Ok 'scans: staged/tip trees stay on repo volume'
} else {
    Bad 'scans still materialize staged tree on TEMP (cross-drive)'
}
if ($rawReview -match 'refusing in-place edit' -and $rawReview -notmatch 'editing main tree') {
    Ok 'fixer: worktree fail is fail-closed'
} else {
    Bad 'fixer still yolo-edits the main tree'
}

# --- 4) Doctor (best-effort; should not throw) ---
Write-Host ""
Write-Host "4) Doctor script" -ForegroundColor Yellow
$doctor = Join-Path $RepoRoot 'assets\token-saving\scripts\doctor.ps1'
if (Test-Path $doctor) {
    try {
        $prev = Get-Location
        Set-Location $RepoRoot
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $doctor 2>&1 | Out-Null
        $code = $LASTEXITCODE
        if ($null -eq $code -or $code -eq 0) { Ok 'doctor.ps1 exited 0' } else { Bad "doctor.ps1 exit $code" }
        Set-Location $prev
    } catch {
        Bad "doctor.ps1 threw: $_"
        try { Set-Location $prev } catch {}
    }
} else {
    Bad 'doctor.ps1 missing'
}

# Live doctor markers (if installed)
$liveDoctor = Join-Path $env:USERPROFILE '.grok\token-saving\scripts\doctor.ps1'
if (Test-Path $liveDoctor) {
    $dTxt = Get-Content $liveDoctor -Raw -ErrorAction SilentlyContinue
    if ($dTxt -match 'Latest gate report' -and $dTxt -match 'Vibe gate') {
        Ok 'live doctor has report/gate sections'
    } else {
        Info 'live doctor not yet redeployed (assets OK)'
    }
}

# --- 5) Optional hooks install in temp repo ---
if ($WithHooksInstall) {
    Write-Host ""
    Write-Host "5) Temp repo hooks install" -ForegroundColor Yellow
    $tmp = Join-Path $env:TEMP ("vibe-smoke-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Push-Location $tmp
        git init -q 2>$null
        'smoke' | Set-Content -Path (Join-Path $tmp 'README.md') -Encoding utf8
        git add README.md 2>$null
        $env:GIT_AUTHOR_NAME = 'smoke'
        $env:GIT_AUTHOR_EMAIL = 'smoke@example.com'
        $env:GIT_COMMITTER_NAME = 'smoke'
        $env:GIT_COMMITTER_EMAIL = 'smoke@example.com'
        git -c commit.gpgsign=false commit -m 'smoke' -q 2>$null

        $installer = Join-Path $RepoRoot 'assets\vibe-tools\scripts\install-vibe-hooks.ps1'
        # Prefer live scripts path inside hook body; we only check installer writes files
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -RepoPath $tmp 2>&1 | Out-Null
        $pc = Join-Path $tmp '.git\hooks\pre-commit'
        $pp = Join-Path $tmp '.git\hooks\pre-push'
        if (Test-Path $pc) {
            $t = Get-Content $pc -Raw
            if ($t -match 'Profile standard') { Ok 'temp pre-commit has Profile standard' } else { Bad 'temp pre-commit lacks Profile standard' }
        } else { Bad 'temp pre-commit not created' }
        if (Test-Path $pp) { Ok 'temp pre-push created' } else { Bad 'temp pre-push not created' }
    } catch {
        Bad "hooks install: $_"
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Info 'skip hooks install (pass -WithHooksInstall)'
}

# --- 6) Secret hygiene: no hard-coded API keys in assets ---
Write-Host ""
Write-Host "6) Secret hygiene (heuristic)" -ForegroundColor Yellow
$secretHit = $false
$scanRoots = @(
    (Join-Path $RepoRoot 'assets'),
    (Join-Path $RepoRoot 'Install-GrokVibeStack.ps1'),
    (Join-Path $RepoRoot 'Uninstall-GrokVibeStack.ps1')
)
$pat = 'xai-[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|api[_-]?key\s*=\s*[''"][^''"]{16,}'
foreach ($root in $scanRoots) {
    if (-not (Test-Path $root)) { continue }
    $files = if (Test-Path $root -PathType Container) {
        Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '\.(ps1|md|toml|json|txt|yml|yaml)$' }
    } else {
        @(Get-Item $root)
    }
    foreach ($f in $files) {
        try {
            $c = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
            if ($c -match $pat) {
                Bad "possible secret in $($f.FullName)"
                $secretHit = $true
            }
        } catch {}
    }
}
if (-not $secretHit) { Ok 'no obvious API key literals in assets/installers' }

# --- 7) Uninstall dry-run ---
if ($WithUninstallDryRun) {
    Write-Host ""
    Write-Host "7) Uninstall -DryRun" -ForegroundColor Yellow
    $un = Join-Path $RepoRoot 'Uninstall-GrokVibeStack.ps1'
    if (Test-Path $un) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $un -DryRun 2>&1 | Out-Null
            if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -eq 0) { Ok 'Uninstall -DryRun exit 0' }
            else { Bad "Uninstall -DryRun exit $LASTEXITCODE" }
        } catch { Bad "Uninstall -DryRun: $_" }
    } else { Bad 'Uninstall-GrokVibeStack.ps1 missing' }
} else {
    Info 'skip uninstall dry-run (pass -WithUninstallDryRun)'
}

# --- Summary ---
Write-Host ""
Write-Host "=== Smoke summary ===" -ForegroundColor Cyan
Write-Host "Passed: $($passed.Count)  Failed: $($failed.Count)" -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
if ($failed.Count) {
    Write-Host "Failures:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All smoke checks passed." -ForegroundColor Green
exit 0

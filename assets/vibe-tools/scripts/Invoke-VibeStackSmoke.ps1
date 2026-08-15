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
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-evals.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-schema.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-push-plan.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-review-context.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\gate-fixer-worktree.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\doctor.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\start-grok.ps1'),
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
if ($prePushSrc -match 'Get-NewBranchPushDiff' -and $prePushSrc -notmatch 'rev-list --max-count=20' -and $prePushSrc -match '--not --remotes' -and $prePushSrc -notmatch "'origin/HEAD'" -and $prePushSrc -notmatch "'origin/main'" -and $prePushSrc -notmatch "'origin/master'" -and $prePushSrc -notmatch 'refs/remotes/origin/HEAD' -and $prePushSrc -notmatch '\$localSha~20' -and $prePushSrc -match 'ConvertTo-SinglePatchText') {
    Ok 'pre-push: new branch is unique-vs-remotes (no 20-commit cap, no guessed origin/*); patches flattened'
} else {
    Bad 'pre-push still caps new-branch history, guesses origin/*, or nests git string[]'
}
if ($prePushSrc -match 'Get-VibePushTipShas' -and $prePushSrc -match '-TreeIsh' -and $scanSrc -match 'function New-CommitScanTree' -and $scanSrc -match 'TreeIsh' -and $scanSrc -match 'worktree add --detach' -and $scanSrc -match '\.vibe-wt-' -and $scanSrc -match '\.Trim\(\)' -and $scanSrc -notmatch 'Expand-Archive') {
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
if ($progSrc -match 'function Write-GateProgress' -and $progSrc -match 'live-gate\.log' -and $progSrc -match 'gate-status\.txt' -and $progSrc -match 'AppendAllLines' -and $progSrc -match 'gate-now\.txt' -and $progSrc -match 'function Write-GateDone' -and $progSrc -match 'Start-GateWatchPopup' -and $progSrc -match 'function Wait-VibeJobs' -and $progSrc -match 'function Start-GateRun' -and $progSrc -match 'RUN:' -and $progSrc -notmatch 'WriteAllLines\(\$script:GateStatusFile' -and $rawReview -match 'Wait-VibeJobs' -and $rawReview -match 'Write-GateDone' -and $rawReview -match 'Write-GateFail' -and $rawReview -match 'Start-GateRun' -and $scanSrc -match 'Write-GateDone' -and $scanSrc -match 'Start-GateRun' -and $prePushSrc -match 'gate-progress\.ps1') {
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
} else {
    Bad 'missing UserPromptSubmit / on-edit-findings wiring'
}
if ($rawReview -match 'Get-GateSchemaVersion' -and $rawReview -match 'schemaVersion' -and $rawReview -match 'tokenEstimate' -and $rawReview -match 'Add-ReviewContext' -and $rawReview -match 'New-FixerWorktree') {
    Ok 'review: schema cache + intent/blast + token estimate + worktree fixer'
} else {
    Bad 'review missing schema/intent/tokens/worktree wiring'
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
if ($startSrc -match 'Test-ProxyMatchesStack' -and $startSrc -match 'ProxyStackFingerprint' -and $startSrc -match 'Save-ProxyFingerprint' -and $startSrc -match 'require the flag pair') {
    Ok 'start-grok: proxy fingerprint / stale restart'
} else {
    Bad 'start-grok missing proxy fingerprint checks'
}
$docSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\doctor.ps1') -Raw
if ($docSrc -match 'Test-ProxyCommandLineMatchesStack' -and $docSrc -match 'headroom-proxy.fingerprint' -and $docSrc -match 'live argv') {
    Ok 'doctor: live proxy cmdline / fingerprint'
} else {
    Bad 'doctor missing live proxy cmdline/fingerprint'
}
$snip = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\config\config-snippet.toml') -Raw
if ($snip -match '\[model\."grok-4\.6"\]' -and $snip -match '\[model\."grok-4\.6-direct"\]' -and $snip -notmatch '(?m)^\s*\[model\.grok-4\.6') {
    Ok 'config: quoted grok-4.6 / grok-4.6-direct tables'
} else {
    Bad 'config-snippet missing quoted model tables (unquoted dotted ids are ignored)'
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
    $merged = Merge-VibeToml -Raw $pre -Snippet $snippetText
    $mergedCheck = Test-VibeToml -Raw $merged
    if ($mergedCheck.Ok -and ($merged -match 'command = ''C:\\hr\.cmd''') -and ($merged -notmatch "command = 'old'")) {
        Ok 'config merge: reinstall over existing owned tables stays valid'
    } else {
        Bad ("config merge invalid after reinstall-shaped input: {0}" -f ($mergedCheck.Errors -join '; '))
    }
    # Strip-miss: table not in Get-VibeOwnedTomlSections. Merge must keep last
    # (snippet), not first (stale). Assert snippet command, not only Test-VibeToml.Ok.
    $preMiss = $pre + "`n`n[mcp_servers.untracked]`ncommand = 'stale-stub'`n"
    $snipMiss = $snippetText.TrimEnd() + "`n`n[mcp_servers.untracked]`ncommand = 'C:\hr.cmd'`n"
    $mergedMiss = Merge-VibeToml -Raw $preMiss -Snippet $snipMiss
    $missCheck = Test-VibeToml -Raw $mergedMiss
    $untracked = @([regex]::Matches($mergedMiss, '(?m)^\s*\[mcp_servers\.untracked\]\s*$'))
    if ($missCheck.Ok -and $untracked.Count -eq 1 -and ($mergedMiss -match '(?s)\[mcp_servers\.untracked\].*?command = ''C:\\hr\.cmd''') -and ($mergedMiss -notmatch 'stale-stub')) {
        Ok 'config merge: snippet wins when strip misses a table'
    } else {
        Bad ("config merge strip-miss did not keep snippet tables={0} ok={1}" -f $untracked.Count, $missCheck.Ok)
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
if ($instSrc -match 'GrokToml\.ps1' -and $instSrc -match 'Test-VibeToml' -and $instSrc -match 'Merge-VibeToml' -and $instSrc -match 'Write-Utf8NoBomFile' -and $instSrc -match 'throw \("config.toml merge invalid') {
    Ok 'installer: merge uses GrokToml + validates + UTF8 no BOM + throw on invalid'
} else {
    Bad 'installer merge no longer validates TOML / uses GrokToml / throw'
}
if ($startSrc -match 'Assert-GrokConfig' -and $startSrc -match 'Repair-GrokConfigFile') {
    Ok 'start-grok: config preflight + auto-repair'
} else {
    Bad 'start-grok missing config preflight/repair'
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
if ($startSrc -match 'Test-ProxyProcessOk' -and $startSrc -match 'TCP owner is not Headroom PID' -and $startSrc -match 'recordedPid is a hint only' -and $startSrc -notmatch 'recordedPid -and \$op -ne \$recordedPid' -and $startSrc -notmatch "ProcessName -match 'headroom\|python'") {
    Ok 'proxy stop/start: Headroom argv + TCP owner PID; stale pid file does not veto live owner'
} else {
    Bad 'proxy still force-kills by name/stale PID or rejects live owner on pid mismatch'
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

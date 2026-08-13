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
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\install-vibe-hooks.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-pre-push.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-scans.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\scan-pass-cache.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-on-edit.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\run-vibe-stop-remind.ps1'),
    (Join-Path $RepoRoot 'assets\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\doctor.ps1'),
    (Join-Path $RepoRoot 'assets\token-saving\scripts\start-grok.ps1'),
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
if ($cacheSrc -and $cacheSrc -match 'ScopeUsed -ne ''Full''' -and $cacheSrc -match 'cachedScope -ne ''Full''' -and $cacheSrc -match 'Normalize-ScanCacheCwd' -and $prePushSrc -match 'scan-pass-cache\.ps1' -and $prePushSrc -match 'Test-ScanPassCache') {
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
if ($rawReview -match 'Update-GitStageAfterFix' -and $rawReview -match 'PriorStaged' -and $rawReview -match 'PreFixDirty' -and $restageLive -notmatch 'git add -u' -and $restageLive -notmatch 'git add -A\s') {
    Ok 'review: scoped restage (blocker + prior-staged + PreFixDirty)'
} else {
    Bad 'review restage still uses git add -u/-A or missing PriorStaged/PreFixDirty'
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
$instSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'Install-GrokVibeStack.ps1') -Raw
$unSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'Uninstall-GrokVibeStack.ps1') -Raw
$hooksInstSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\vibe-tools\scripts\install-vibe-hooks.ps1') -Raw
$vibeHookTpl = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\hooks\vibe-coding.json') -Raw
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
if ($instSrc -match 'stackOwned' -and $instSrc -match 'Never record pre-existing' -and $unSrc -match 'outside GrokHome' -and $unSrc -match 'keep shared Git/Node/npm') {
    Ok 'PATH: record stack-owned only; uninstall never strips outside ~/.grok'
} else {
    Bad 'PATH AlwaysRecord / uninstall shared-dir strip still unsafe'
}
$rtkSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\run-rtk-enforce.ps1') -Raw
if ($rtkSrc -match 'Split-ShellSegments' -and $rtkSrc -match 'each shell segment') {
    Ok 'rtk: per-segment enforce present'
} else {
    Bad 'rtk missing per-segment enforce'
}
$startSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\token-saving\scripts\start-grok.ps1') -Raw
if ($startSrc -match 'Test-ProxyMatchesStack' -and $startSrc -match 'ProxyStackFingerprint' -and $startSrc -match 'Save-ProxyFingerprint') {
    Ok 'start-grok: proxy fingerprint / stale restart'
} else {
    Bad 'start-grok missing proxy fingerprint checks'
}
$snip = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets\config\config-snippet.toml') -Raw
if ($snip -match '\[model\."grok-4\.6"\]' -and $snip -match '\[model\."grok-4\.6-direct"\]' -and $snip -notmatch '(?m)^\s*\[model\.grok-4\.6') {
    Ok 'config: quoted grok-4.6 / grok-4.6-direct tables'
} else {
    Bad 'config-snippet missing quoted model tables (unquoted dotted ids are ignored)'
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
# Scope Full may be '-Scope Full' or Start-Process ArgumentList '-Scope','Full'
if ($prePushPs1 -match '-Profile fast' -and $prePushPs1 -match '-AutoProfile' -and ($prePushPs1 -match "-Scope['\s,]*Full" -or $prePushPs1 -match "'Full'")) {
    Ok 'pre-push wires fast + AutoProfile + Scope Full/cache'
} else {
    Bad 'pre-push missing AutoProfile/Scope Full'
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

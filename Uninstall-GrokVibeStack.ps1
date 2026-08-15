#Requires -Version 5.1
<#
.SYNOPSIS
  Remove the Grok vibe-coding + token-saving stack installed by Install-GrokVibeStack.ps1.

.DESCRIPTION
  Safe by default:
    - NEVER deletes Grok Build (grok.exe, agent.exe, auth.json, sessions, marketplace, etc.)
    - Removes stack dirs: token-saving, vibe-tools, our rules/skills/hooks
    - Removes managed config.toml block (restores from backup if available)
    - Removes PATH entries recorded in the install manifest
    - Removes bin shims we added (start-grok, vibe-review, rtk copy, ...)

  Optional aggressive cleanup (off by default):
    -RemoveWingetPackages  uninstall winget IDs recorded in manifest
    -RemoveNpmPackages     npm uninstall -g packages from manifest
    -RemoveSerena          uv tool uninstall / remove serena binaries
    -RemovePsModules       Uninstall-Module PSScriptAnalyzer/Pester (CurrentUser)
    -RemovePython          winget uninstall Python if pythonInstalledByUs
    -RemoveGit / -RemoveNode / -RemoveUv similarly when *InstalledByUs

.PARAMETER KeepRepoHooks
  Do not delete pre-commit/pre-push from the repo path stored in the manifest.

.PARAMETER DryRun
  Print actions only.

.EXAMPLE
  .\Uninstall-GrokVibeStack.ps1
  .\Uninstall-GrokVibeStack.ps1 -RemoveWingetPackages -RemoveNpmPackages
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$RemoveWingetPackages,
    [switch]$RemoveNpmPackages,
    [switch]$RemoveSerena,
    [switch]$RemovePsModules,
    [switch]$RemovePython,
    [switch]$RemoveGit,
    [switch]$RemoveNode,
    [switch]$RemoveUv,
    [switch]$KeepRepoHooks,
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$GrokHome = Join-Path $env:USERPROFILE '.grok'
$GrokBin = Join-Path $GrokHome 'bin'
$ManifestPath = Join-Path $GrokHome 'vibe-stack-manifest.json'
$LocalBin = Join-Path $env:USERPROFILE '.local\bin'

$script:Removed = New-Object System.Collections.Generic.List[string]
$script:Skipped = New-Object System.Collections.Generic.List[string]
$script:Warned = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Info([string]$m) { Write-Host "  ..  $m" -ForegroundColor DarkGray }
function Write-Do([string]$m) { Write-Host "  DEL $m" -ForegroundColor Yellow; [void]$script:Removed.Add($m) }
function Write-Skip([string]$m) { Write-Host "  keep $m" -ForegroundColor DarkGray; [void]$script:Skipped.Add($m) }
function Write-Warn2([string]$m) { Write-Host "  WARN $m" -ForegroundColor Yellow; [void]$script:Warned.Add($m) }

function Get-Manifest {
    if (Test-Path -LiteralPath $ManifestPath) {
        try {
            return Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        } catch {
            Write-Warn2 "Manifest unreadable: $_"
        }
    }
    # Fallback defaults matching installer layout
    Write-Warn2 "No manifest at $ManifestPath - using default stack layout"
    return [pscustomobject]@{
        # Only stack-specific PATH entries (never strip ~/.grok/bin or shared ~/.local/bin without manifest)
        pathEntries         = @(
            (Join-Path $GrokHome 'token-saving\venv\Scripts')
            (Join-Path $GrokHome 'vibe-tools\venv\Scripts')
            (Join-Path $env:USERPROFILE '.headroom\bin')
        )
        # Only stack-owned trees — never wipe shared rules/skills/hooks roots
        stackDirs           = @(
            (Join-Path $GrokHome 'token-saving')
            (Join-Path $GrokHome 'vibe-tools')
        )
        binShims            = @(
            'start-grok.cmd', 'start-grok.ps1', 'stop-grok-proxy.cmd',
            'vibe-review.ps1', 'install-vibe-hooks.ps1', 'rtk.exe', 'scc.exe', 'tokei.exe'
        )
        hookFiles           = @('token-saving.json', 'vibe-coding.json', 'serena-hooks.json')
        ruleFiles           = @('caveman.md', 'rtk.md', 'token-efficiency.md', 'vibe-coding.md')
        skillDirs           = @('caveman', 'token-save', 'vibe-coding')
        wingetIds           = @()
        npmPackages         = @()
        psModules           = @('PSScriptAnalyzer', 'Pester')
        pythonInstalledByUs = $false
        gitInstalledByUs    = $false
        nodeInstalledByUs   = $false
        uvInstalledByUs     = $false
        serenaInstalledByUs = $false
        repoHooksPath       = $null
        configBackup        = $null
        neverRemove         = @('grok.exe', 'grok.exe.old', 'agent.exe', 'auth.json', 'sessions')
    }
}

function Remove-UserPathEntry([string]$Dir) {
    if (-not $Dir) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { return }
    $norm = $Dir.TrimEnd('\')
    $parts = @($userPath -split ';' | Where-Object {
            $_ -and ($_.TrimEnd('\') -ine $norm)
        })
    $newPath = $parts -join ';'
    if ($newPath -eq $userPath) {
        Write-Info "PATH entry not present: $Dir"
        return
    }
    if ($DryRun) {
        Write-Info "DRY PATH remove $Dir"
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Do "PATH entry $Dir"
}

function Remove-FileSafe([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $name = Split-Path $Path -Leaf
    if ($name -match '^(grok\.exe|grok\.exe\.old|agent\.exe|auth\.json)$') {
        Write-Skip $Path
        return
    }
    if ($DryRun) { Write-Info "DRY del file $Path"; return }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    Write-Do $Path
}

function Remove-DirSafe([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    # never delete entire .grok
    if ((Resolve-Path $Path -ErrorAction SilentlyContinue).Path -ieq (Resolve-Path $GrokHome -ErrorAction SilentlyContinue).Path) {
        Write-Skip "refusing to delete entire $GrokHome"
        return
    }
    if ($DryRun) { Write-Info "DRY del dir $Path"; return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    Write-Do $Path
}

function Stop-HeadroomProxy {
    Write-Step "Stop Headroom proxy"
    $stopShim = Join-Path $GrokBin 'stop-grok-proxy.cmd'
    $startPs1 = Join-Path $GrokHome 'token-saving\scripts\start-grok.ps1'
    if ($DryRun) { Write-Info "DRY stop proxy"; return }
    if (Test-Path -LiteralPath $startPs1) {
        try { & $startPs1 -StopProxy 2>$null | Out-Null } catch {}
    } elseif (Test-Path -LiteralPath $stopShim) {
        try { & $stopShim 2>$null | Out-Null } catch {}
    }
    # Never Stop-Process by raw PID file — Windows may have reused it.
    # start-grok -StopProxy already verified image/cmdline; just drop a leftover marker.
    $pidFile = Join-Path $GrokHome 'token-saving\state\headroom-proxy.pid'
    if (Test-Path -LiteralPath $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Write-Do "Headroom proxy stop attempted"
}

function Remove-ManagedConfigBlock {
    Write-Step "config.toml managed block"
    $cfg = Join-Path $GrokHome 'config.toml'
    if (-not (Test-Path -LiteralPath $cfg)) {
        Write-Info "no config.toml"
        return
    }
    $begin = '# --- grok-vibe-stack managed block (begin) ---'
    $end = '# --- grok-vibe-stack managed block (end) ---'
    $raw = Get-Content -LiteralPath $cfg -Raw
    if (-not $raw.Contains($begin)) {
        Write-Info "no managed block markers (leaving config as-is)"
        return
    }
    if ($DryRun) { Write-Info "DRY strip managed block"; return }

    $bak = "$cfg.pre-uninstall-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $cfg -Destination $bak -Force
    Write-Info "Backup before strip: $bak"

    $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?'
    $newRaw = [regex]::Replace($raw, $pattern, '')
    # collapse excessive blank lines
    $newRaw = $newRaw -replace '(\r?\n){3,}', "`n`n"
    [System.IO.File]::WriteAllText($cfg, $newRaw.TrimEnd() + "`n")
    Write-Do "stripped managed block from config.toml"
}

function Remove-RepoHooks([string]$RepoPath) {
    if (-not $RepoPath -or -not (Test-Path -LiteralPath $RepoPath)) { return }
    $hooks = $null
    try {
        $hooks = (git -C $RepoPath rev-parse --git-path hooks 2>$null | Select-Object -First 1)
    } catch {}
    if ([string]::IsNullOrWhiteSpace($hooks)) {
        $hooks = Join-Path $RepoPath '.git\hooks'
    }
    if (-not [System.IO.Path]::IsPathRooted($hooks)) {
        $hooks = Join-Path $RepoPath $hooks
    }
    if (-not (Test-Path -LiteralPath $hooks)) { return }
    foreach ($h in @('pre-commit', 'pre-push')) {
        $p = Join-Path $hooks $h
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $txt = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
        if ($txt -and $txt -match 'Vibe pre-') {
            if ($DryRun) { Write-Info "DRY remove $p"; continue }
            Remove-Item -LiteralPath $p -Force
            Write-Do $p
        }
    }
}

# ---------- main ----------
Write-Host ""
Write-Host "+================================================================+" -ForegroundColor Magenta
Write-Host "|  Uninstall-GrokVibeStack                                       |" -ForegroundColor Magenta
Write-Host "|  Removes vibe/token stack; keeps Grok Build CLI                |" -ForegroundColor Magenta
Write-Host "+================================================================+" -ForegroundColor Magenta
if ($DryRun) { Write-Host "MODE: DRY RUN" -ForegroundColor Yellow }

if (-not $Force -and -not $DryRun) {
    Write-Host ""
    Write-Host "This removes token-saving, vibe-tools, stack hooks/rules/skills, and PATH shims." -ForegroundColor Yellow
    Write-Host "Grok Build itself will NOT be removed." -ForegroundColor Green
    $ans = Read-Host "Type YES to continue"
    if ($ans -ne 'YES') {
        Write-Host "Aborted."
        exit 0
    }
}

$m = Get-Manifest

Stop-HeadroomProxy

Write-Step "Repo git hooks"
if ($KeepRepoHooks) {
    Write-Info "KeepRepoHooks set"
} elseif ($m.repoHooksPath) {
    Remove-RepoHooks -RepoPath ([string]$m.repoHooksPath)
} else {
    Write-Info "No repoHooksPath in manifest"
}

Write-Step "Session hooks / rules / skills (stack-owned names only)"
$hooksDir = Join-Path $GrokHome 'hooks'
foreach ($hf in @($m.hookFiles)) {
    Remove-FileSafe (Join-Path $hooksDir $hf)
}
$rulesDir = Join-Path $GrokHome 'rules'
foreach ($rf in @($m.ruleFiles)) {
    Remove-FileSafe (Join-Path $rulesDir $rf)
}
$skillsDir = Join-Path $GrokHome 'skills'
foreach ($sd in @($m.skillDirs)) {
    # Only named skill packages we installed — never delete entire skills root
    Remove-DirSafe (Join-Path $skillsDir $sd)
}

Write-Step "Docs dropped by installer"
foreach ($f in @('AGENTS.md', 'RTK.md')) {
    $p = Join-Path $GrokHome $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $txt = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
    # Skip removal if user clearly replaced stack docs
    if ($txt -and $f -eq 'AGENTS.md' -and $txt -notmatch 'vibe|token-sav|caveman|rtk') {
        Write-Skip "$p (does not look like stack AGENTS.md)"
        continue
    }
    Remove-FileSafe $p
}
Remove-FileSafe (Join-Path $GrokHome '.caveman-active')

Write-Step "Bin shims (never grok.exe / agent.exe)"
foreach ($shim in @($m.binShims)) {
    Remove-FileSafe (Join-Path $GrokBin $shim)
}

Write-Step "Stack directories (token-saving + vibe-tools only)"
$allowedStackRoots = @(
    (Join-Path $GrokHome 'token-saving')
    (Join-Path $GrokHome 'vibe-tools')
)
foreach ($d in @($m.stackDirs)) {
    $full = [string]$d
    if (-not $full) { continue }
    $ok = $false
    foreach ($a in $allowedStackRoots) {
        if ($full.TrimEnd('\') -ieq $a.TrimEnd('\')) { $ok = $true; break }
    }
    # Also allow only if path is under .grok AND is token-saving or vibe-tools leaf
    if (-not $ok) {
        $leaf = Split-Path $full -Leaf
        if ($leaf -in @('token-saving', 'vibe-tools')) {
            $parent = Split-Path $full -Parent
            if ($parent.TrimEnd('\') -ieq $GrokHome.TrimEnd('\')) { $ok = $true }
        }
    }
    if (-not $ok) {
        Write-Skip "refusing stackDir outside allowlist: $full"
        continue
    }
    Remove-DirSafe $full
}
# Always try canonical stack trees
Remove-DirSafe (Join-Path $GrokHome 'token-saving')
Remove-DirSafe (Join-Path $GrokHome 'vibe-tools')

Write-Step "config.toml"
Remove-ManagedConfigBlock

Write-Step "User PATH cleanup"
$grokHomeNorm = $GrokHome.TrimEnd('\')
foreach ($pe in @($m.pathEntries)) {
    if (-not $pe) { continue }
    $peNorm = ([string]$pe).TrimEnd('\')
    # NEVER remove $GrokBin from PATH - grok lives there.
    if ($peNorm -ieq $GrokBin.TrimEnd('\')) {
        Write-Skip "PATH $pe (Grok bin - keep)"
        continue
    }
    # Old manifests recorded Git/Node/npm. Never strip anything outside GrokHome.
    if (-not $peNorm.StartsWith($grokHomeNorm, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Skip "PATH $pe (outside GrokHome - keep shared Git/Node/npm)"
        continue
    }
    Remove-UserPathEntry -Dir ([string]$pe)
}

Write-Step "Optional package removal"
if ($RemoveWingetPackages -and $m.wingetIds -and @($m.wingetIds).Count -gt 0) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        foreach ($id in @($m.wingetIds)) {
            # Never uninstall Git/Python/Node unless dedicated flags
            if ($id -match '^Python\.' -and -not $RemovePython) { Write-Skip "winget $id (need -RemovePython)"; continue }
            if ($id -eq 'Git.Git' -and -not $RemoveGit) { Write-Skip "winget $id (need -RemoveGit)"; continue }
            if ($id -match 'NodeJS' -and -not $RemoveNode) { Write-Skip "winget $id (need -RemoveNode)"; continue }
            if ($id -eq 'astral-sh.uv' -and -not $RemoveUv) { Write-Skip "winget $id (need -RemoveUv)"; continue }
            Write-Info "winget uninstall $id"
            if ($DryRun) { continue }
            & winget uninstall --id $id -e --disable-interactivity 2>$null | Out-Null
            Write-Do "winget $id"
        }
    }
} else {
    Write-Info "Winget packages left installed (pass -RemoveWingetPackages to remove scanners)"
}

if ($RemoveNpmPackages -and $m.npmPackages) {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        foreach ($pkg in @($m.npmPackages)) {
            Write-Info "npm uninstall -g $pkg"
            if ($DryRun) { continue }
            & npm uninstall -g $pkg 2>$null | Out-Null
            Write-Do "npm $pkg"
        }
    }
}

if ($RemoveSerena -or $m.serenaInstalledByUs) {
    if (-not $RemoveSerena -and $m.serenaInstalledByUs) {
        # only auto-remove if we installed it when -RemoveSerena not set? Require explicit for safety.
        Write-Info "Serena was installed by stack; pass -RemoveSerena to remove it"
    }
    if ($RemoveSerena) {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            if (-not $DryRun) { & uv tool uninstall serena 2>$null | Out-Null }
            Write-Do "uv tool serena"
        }
        foreach ($b in @('serena.exe', 'serena-hooks.exe', 'serena-agent.exe')) {
            Remove-FileSafe (Join-Path $LocalBin $b)
        }
    }
}

if ($RemovePsModules) {
    foreach ($mod in @($m.psModules)) {
        Write-Info "Uninstall-Module $mod"
        if ($DryRun) { continue }
        try {
            Uninstall-Module -Name $mod -AllVersions -Force -ErrorAction Stop
            Write-Do "PS module $mod"
        } catch {
            Write-Warn2 "Uninstall-Module $mod : $_"
        }
    }
}

if ($RemovePython -and $m.pythonInstalledByUs) {
    foreach ($id in @('Python.Python.3.12', 'Python.Python.3.13', 'Python.Python.3.11')) {
        if ($DryRun) { Write-Info "DRY winget uninstall $id"; continue }
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            & winget uninstall --id $id -e --disable-interactivity 2>$null | Out-Null
            Write-Do "winget $id"
        }
    }
}
if ($RemoveGit -and $m.gitInstalledByUs) {
    if (-not $DryRun -and (Get-Command winget -EA SilentlyContinue)) {
        & winget uninstall --id Git.Git -e --disable-interactivity 2>$null | Out-Null
        Write-Do "winget Git.Git"
    }
}
if ($RemoveNode -and $m.nodeInstalledByUs) {
    if (-not $DryRun -and (Get-Command winget -EA SilentlyContinue)) {
        foreach ($id in @('OpenJS.NodeJS.LTS', 'OpenJS.NodeJS')) {
            & winget uninstall --id $id -e --disable-interactivity 2>$null | Out-Null
        }
        Write-Do "winget Node.js"
    }
}
if ($RemoveUv -and $m.uvInstalledByUs) {
    if (-not $DryRun -and (Get-Command winget -EA SilentlyContinue)) {
        & winget uninstall --id astral-sh.uv -e --disable-interactivity 2>$null | Out-Null
        Write-Do "winget uv"
    }
}

Write-Step "Manifest"
Remove-FileSafe $ManifestPath

# headroom home leftover
$hrHome = Join-Path $env:USERPROFILE '.headroom'
if (Test-Path $hrHome) {
    Write-Info "Left $hrHome (rtk cache). Delete manually if desired."
}

Write-Step "Summary"
Write-Host "Removed ($($script:Removed.Count)):" -ForegroundColor Yellow
$script:Removed | ForEach-Object { Write-Host "  - $_" }
if ($script:Skipped.Count) {
    Write-Host "Kept ($($script:Skipped.Count)):" -ForegroundColor Green
    $script:Skipped | ForEach-Object { Write-Host "  - $_" }
}
if ($script:Warned.Count) {
    Write-Host "Warnings:" -ForegroundColor Yellow
    $script:Warned | ForEach-Object { Write-Host "  - $_" }
}

Write-Host ""
Write-Host "Grok Build CLI left intact under $GrokBin (grok.exe)." -ForegroundColor Green
Write-Host "Open a new terminal so PATH updates apply." -ForegroundColor Cyan
Write-Host "Done."
exit 0

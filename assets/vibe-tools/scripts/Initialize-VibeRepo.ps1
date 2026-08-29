#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap a git repo for the vibe stack: hooks, Serena project.yml, thin AGENTS.md.
#>
[CmdletBinding()]
param(
    [string]$RepoPath = '.',
    [switch]$SkipSerena,
    [switch]$SkipHooks,
    [switch]$SkipAgents,
    [switch]$ForceAgents,
    [switch]$SkipSerenaInstall
)

$ErrorActionPreference = 'Stop'

function Write-Info([string]$m) { Write-Host ('[vibe-repo] {0}' -f $m) -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host ('[vibe-repo] {0}' -f $m) -ForegroundColor Green }
function Write-Warn2([string]$m) { Write-Host ('[vibe-repo] {0}' -f $m) -ForegroundColor Yellow }

try {
    $repo = (Resolve-Path -LiteralPath $RepoPath -ErrorAction Stop).Path
} catch {
    throw ('RepoPath not found: {0}' -f $RepoPath)
}

$gitDir = Join-Path $repo '.git'
if (-not (Test-Path -LiteralPath $gitDir)) {
    throw ('Not a git repository: {0}' -f $repo)
}

$vibeScripts = Join-Path $env:USERPROFILE '.grok\vibe-tools\scripts'
if (-not (Test-Path -LiteralPath $vibeScripts)) { $vibeScripts = $PSScriptRoot }
$hookPs1 = Join-Path $vibeScripts 'install-vibe-hooks.ps1'
if (-not (Test-Path -LiteralPath $hookPs1)) {
    $hookPs1 = Join-Path $PSScriptRoot 'install-vibe-hooks.ps1'
}

if (-not $SkipHooks) {
    if (-not (Test-Path -LiteralPath $hookPs1)) {
        throw 'install-vibe-hooks.ps1 missing'
    }
    Write-Info ('install-vibe-hooks {0}' -f $repo)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookPs1 $repo
    if ($LASTEXITCODE -ne 0) {
        throw ('install-vibe-hooks failed (exit {0})' -f $LASTEXITCODE)
    }
    Write-Ok 'git hooks'
}

if (-not $SkipSerena) {
    $ensure = $null
    foreach ($c in @(
            (Join-Path $env:USERPROFILE '.grok\token-saving\scripts\ensure-serena.ps1'),
            (Join-Path $PSScriptRoot '..\..\token-saving\scripts\ensure-serena.ps1')
        )) {
        if (Test-Path -LiteralPath $c) {
            $ensure = (Resolve-Path -LiteralPath $c).Path
            break
        }
    }
    if ($ensure -and (Test-Path -LiteralPath $ensure)) {
        Write-Info ('ensure-serena -RepoPath {0}' -f $repo)
        $ensArgs = @('-RepoPath', $repo)
        if ($SkipSerenaInstall) { $ensArgs += '-SkipInstall' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ensure @ensArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 ('ensure-serena exit {0} (hooks still installed)' -f $LASTEXITCODE)
        } else {
            Write-Ok 'serena project.yml'
        }
    } else {
        Write-Warn2 'ensure-serena.ps1 missing - skip Serena project.yml'
    }
}

if (-not $SkipAgents) {
    $agents = Join-Path $repo 'AGENTS.md'
    $stub = @(
        '# Project agent notes',
        '',
        'Put this repo build and test commands here. Do not paste global Grok rules.',
        'Thin TUI user rules: user-rules-thin.md after install.',
        '',
        'Build:',
        'Test:'
    ) -join "`n"
    if ((Test-Path -LiteralPath $agents) -and -not $ForceAgents) {
        Write-Info 'AGENTS.md exists (left in place)'
    } else {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($agents, ($stub.TrimStart() + "`n"), $utf8)
        Write-Ok 'AGENTS.md stub'
    }
}

Write-Ok ('bootstrap done: {0}' -f $repo)
Write-Host 'CI twin (scanners only, no LLM): copy ~/.grok/vibe-tools/ci/vibe-user-repo.yml'
Write-Host 'If Grok was already open: /hooks then r'
exit 0

#Requires -Version 5.1
<#
.SYNOPSIS
  Ensure Serena MCP is installed, on PATH, and the repo has usable language servers.

.DESCRIPTION
  Binary: uv tool install serena-agent (PyPI), then git+https fallback, then pip.
  Project: if -RepoPath is set, create or repair .serena/project.yml so
  language_servers is never empty (empty list => "No language servers available").

.PARAMETER Quiet
  Suppress logs; print the serena.exe path on success.

.PARAMETER RepoPath
  Git/project root to initialize or repair.

.PARAMETER SkipInstall
  Only repair project.yml (do not download Serena).

.PARAMETER SkipProject
  Only install/verify the binary.
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    [string]$RepoPath = '',
    [switch]$SkipInstall,
    [switch]$SkipProject
)

$ErrorActionPreference = 'Stop'

$GrokHome = Join-Path $env:USERPROFILE '.grok'
$GrokBin = Join-Path $GrokHome 'bin'
$LocalBin = Join-Path $env:USERPROFILE '.local\bin'
$VenvPy = Join-Path $GrokHome 'token-saving\venv\Scripts\python.exe'

function Write-Msg([string]$msg, [string]$color = 'Cyan') {
    if (-not $Quiet) { Write-Host "[ensure-serena] $msg" -ForegroundColor $color }
}

function Test-SerenaAlive([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $Path --version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Find-Serena {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($dir in @($LocalBin, $GrokBin)) {
        foreach ($name in @('serena.exe', 'serena.cmd', 'serena')) {
            [void]$cands.Add((Join-Path $dir $name))
        }
    }
    $cmd = Get-Command serena -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { [void]$cands.Add($cmd.Source) }
    foreach ($p in $cands) {
        if (Test-SerenaAlive $p) { return $p }
    }
    return $null
}

function Add-ProcessPath([string]$Dir) {
    if (-not $Dir) { return }
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    if ($env:PATH -notlike "*$Dir*") {
        $env:PATH = "$Dir;$env:PATH"
    }
}

function Find-Uv {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $guess = @(
        (Join-Path $env:USERPROFILE '.local\bin\uv.exe')
        (Join-Path $env:USERPROFILE '.cargo\bin\uv.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\uv\uv.exe')
    )
    foreach ($p in $guess) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Install-SerenaBinary {
    New-Item -ItemType Directory -Force -Path $LocalBin, $GrokBin | Out-Null
    Add-ProcessPath $LocalBin
    Add-ProcessPath $GrokBin

    $uv = Find-Uv
    if ($uv) {
        Write-Msg "uv tool install serena-agent (PyPI)"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $uv tool install --force serena-agent==1.7.0 2>&1 | ForEach-Object { Write-Msg "$_" 'DarkGray' }
        } finally {
            $ErrorActionPreference = $prev
        }
        Add-ProcessPath $LocalBin
        $found = Find-Serena
        if ($found) { return $found }

        Write-Msg "PyPI miss; trying git+https://github.com/oraios/serena" 'Yellow'
        $ErrorActionPreference = 'Continue'
        try {
            & $uv tool install --force git+https://github.com/oraios/serena@v1.7.0 2>&1 | ForEach-Object { Write-Msg "$_" 'DarkGray' }
        } finally {
            $ErrorActionPreference = $prev
        }
        Add-ProcessPath $LocalBin
        $found = Find-Serena
        if ($found) { return $found }
    } else {
        Write-Msg "uv not on PATH" 'Yellow'
    }

    $py = $null
    if (Test-Path -LiteralPath $VenvPy) { $py = $VenvPy }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { $py = (Get-Command python).Source }
    if ($py) {
        Write-Msg "pip install serena-agent --user"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $py -m pip install --user serena-agent==1.7.0 2>&1 | Out-Null
        } finally {
            $ErrorActionPreference = $prev
        }
        Add-ProcessPath $LocalBin
        $found = Find-Serena
        if ($found) { return $found }
    }

    return $null
}

function Test-RepoHasFile {
    param(
        [string]$Root,
        [string]$Filter,
        [int]$Depth = 4
    )
    $skip = '\\(\.git|node_modules|\.venv|venv|\.serena|dist|build|__pycache__)\\'
    $hit = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter -Depth $Depth -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $skip } |
        Select-Object -First 1
    return [bool]$hit
}

function Get-InferredSerenaLanguages([string]$Root) {
    $langs = New-Object System.Collections.Generic.List[string]
    function Add-Lang([string]$id) {
        if (-not $langs.Contains($id)) { [void]$langs.Add($id) }
    }

    if ((Test-Path -LiteralPath (Join-Path $Root 'Cargo.toml'))) { Add-Lang 'rust' }
    if ((Test-Path -LiteralPath (Join-Path $Root 'go.mod'))) { Add-Lang 'go' }
    if ((Test-RepoHasFile $Root '*.ps1') -or (Test-RepoHasFile $Root '*.psm1')) { Add-Lang 'powershell' }
    if ((Test-RepoHasFile $Root '*.py')) { Add-Lang 'python' }
    if ((Test-RepoHasFile $Root '*.ts') -or (Test-RepoHasFile $Root '*.tsx') -or
        (Test-RepoHasFile $Root '*.js') -or (Test-RepoHasFile $Root '*.jsx') -or
        (Test-Path -LiteralPath (Join-Path $Root 'package.json'))) {
        Add-Lang 'typescript'
    }
    if ((Test-RepoHasFile $Root '*.sh')) { Add-Lang 'bash' }

    if ($langs.Count -eq 0) {
        if ((Test-RepoHasFile $Root '*.toml')) { Add-Lang 'toml' }
        if ((Test-RepoHasFile $Root '*.yml') -or (Test-RepoHasFile $Root '*.yaml')) { Add-Lang 'yaml' }
        if ((Test-RepoHasFile $Root '*.json')) { Add-Lang 'json' }
        if ((Test-RepoHasFile $Root '*.md')) { Add-Lang 'markdown' }
    }
    if ($langs.Count -eq 0) { Add-Lang 'markdown' }
    return @($langs)
}

function Test-LanguageServersEmpty([string]$Raw) {
    if ($Raw -match '(?m)^language_servers:\s*\r?\n-') { return $false }
    if ($Raw -match '(?m)^language_servers:\s*\[\s*[^\]]+\s*\]') { return $false }
    return $true
}

function Set-LanguageServersList {
    param([string]$Raw, [string[]]$Langs)
    $block = "language_servers:`n" + (($Langs | ForEach-Object { "- $_" }) -join "`n")
    if ($Raw -match '(?m)^language_servers:\s*\[\s*\]') {
        return [regex]::Replace($Raw, '(?m)^language_servers:\s*\[\s*\]\s*', ($block + "`n"), 1)
    }
    if ($Raw -match '(?m)^language_servers:\s*$') {
        return [regex]::Replace($Raw, '(?m)^language_servers:\s*$', $block, 1)
    }
    if ($Raw -notmatch '(?m)^language_servers:') {
        return $Raw.TrimEnd() + "`n`n" + $block + "`n"
    }
    return $Raw
}

function Ensure-PwshIfNeeded([string[]]$Langs) {
    if ($Langs -notcontains 'powershell') { return }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        Write-Msg "pwsh ready: $($pwsh.Source)"
        return
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Msg "pwsh missing; PowerShell LS needs PowerShell 7+. Install: winget install Microsoft.PowerShell" 'Yellow'
        return
    }
    Write-Msg "Installing PowerShell 7 (required for Serena powershell LS)"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & winget install --id Microsoft.PowerShell -e --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
            ForEach-Object { Write-Msg "$_" 'DarkGray' }
    } finally {
        $ErrorActionPreference = $prev
    }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Msg "pwsh still missing after winget; Serena powershell LS may fail until PowerShell 7 is on PATH" 'Yellow'
    }
}

function Initialize-SerenaProject {
    param(
        [string]$Root,
        [string]$SerenaExe
    )
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) {
        Write-Msg "Skip project init (no repo path)" 'Yellow'
        return
    }
    $yml = Join-Path $Root '.serena\project.yml'
    $langs = Get-InferredSerenaLanguages $Root
    Ensure-PwshIfNeeded $langs

    if (-not (Test-Path -LiteralPath $yml)) {
        if (-not $SerenaExe) {
            Write-Msg "No serena.exe; cannot create project.yml" 'Yellow'
            return
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $Root '.serena') | Out-Null
        $name = Split-Path $Root -Leaf
        $args = @('project', 'create', $Root, '--name', $name)
        foreach ($ls in $langs) { $args += @('--ls', $ls) }
        Write-Msg "serena project create --ls $($langs -join ',')"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $SerenaExe @args 2>&1 | ForEach-Object { Write-Msg "$_" 'DarkGray' }
        } finally {
            $ErrorActionPreference = $prev
        }
    }

    if (-not (Test-Path -LiteralPath $yml)) {
        Write-Msg "project.yml still missing after create" 'Yellow'
        return
    }

    $raw = Get-Content -LiteralPath $yml -Raw
    if (Test-LanguageServersEmpty $raw) {
        Write-Msg "Repairing empty language_servers -> $($langs -join ', ')" 'Yellow'
        $fixed = Set-LanguageServersList -Raw $raw -Langs $langs
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($yml, $fixed, $utf8)
    } else {
        Write-Msg "project.yml language_servers already set"
    }
}

# ---- main ----
Add-ProcessPath $LocalBin
Add-ProcessPath $GrokBin

$serena = Find-Serena
if (-not $serena -and -not $SkipInstall) {
    $serena = Install-SerenaBinary
}

if (-not $serena) {
    if ($SkipInstall) {
        Write-Msg "serena not found (SkipInstall)" 'Yellow'
    } else {
        Write-Msg "serena install failed. Later: uv tool install serena-agent" 'Red'
        exit 1
    }
} else {
    $ver = & $serena --version 2>&1
    Write-Msg "ok: $ver ($serena)" 'Green'
}

if (-not $SkipProject -and $RepoPath) {
    $resolved = $RepoPath
    if (Test-Path -LiteralPath $RepoPath) {
        $resolved = (Resolve-Path -LiteralPath $RepoPath).Path
    }
    Initialize-SerenaProject -Root $resolved -SerenaExe $serena
}

if ($Quiet -and $serena) { Write-Output $serena }
if (-not $serena) { exit 1 }
exit 0

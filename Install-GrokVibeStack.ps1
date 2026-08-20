#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap the full Grok vibe-coding + token-saving stack on a machine that only has Grok Build CLI.

.DESCRIPTION
  Idempotent. Requires grok.exe. Installs the full GrokVibeStack from this repository's assets/:

  Prerequisites auto-installed when missing (via winget unless skipped):
    Python 3.10+, Git, Node.js LTS, uv

  Then:
    token-saving (Headroom venv, rtk, start-grok, caveman)
    vibe-tools (scanner venv, review scripts, git + Grok hooks)
    rules / skills / AGENTS.md / RTK.md
    winget CLIs (rg, fd, bat, trivy, gitleaks, biome, shellcheck, hadolint, gh)
    npm globals (jscpd, markdownlint-cli, prettier, eslint, typescript)
    PS modules (PSScriptAnalyzer, Pester)
    Serena MCP (uv tool)
    config.toml managed block (Headroom + Serena MCP, grok-4.6 chat :8787 + grok-gate reviews :8788 + grok-4.6-direct)
    install manifest for Uninstall-GrokVibeStack.ps1

  Does NOT install or remove Grok Build itself. Does NOT write API keys.

.PARAMETER SkipWinget
  Skip optional winget CLIs (still installs Python/Git/Node/uv unless those Skip* flags are set).

.PARAMETER SkipNpm
  Skip global npm packages.

.PARAMETER SkipSerena
  Skip Serena MCP.

.PARAMETER SkipRepoHooks
  Do not install git hooks into the current directory.

.PARAMETER SkipPythonInstall
  Do not auto-install Python.

.PARAMETER SkipGitInstall
  Do not auto-install Git.

.PARAMETER SkipNodeInstall
  Do not auto-install Node.js.

.PARAMETER UseFrozenReqs
  Use pip freeze pins from assets/requirements/*-freeze.txt.

.PARAMETER DryRun
  Print actions only.

.EXAMPLE
  .\Install-GrokVibeStack.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipWinget,
    [switch]$SkipNpm,
    [switch]$SkipSerena,
    [switch]$SkipRepoHooks,
    [switch]$SkipPythonInstall,
    [switch]$SkipGitInstall,
    [switch]$SkipNodeInstall,
    [switch]$UseFrozenReqs,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Assets = Join-Path $ScriptRoot 'assets'

$GrokHome = Join-Path $env:USERPROFILE '.grok'
$GrokBin = Join-Path $GrokHome 'bin'
$TokenRoot = Join-Path $GrokHome 'token-saving'
$VibeRoot = Join-Path $GrokHome 'vibe-tools'
$LocalBin = Join-Path $env:USERPROFILE '.local\bin'
$HeadroomBin = Join-Path $env:USERPROFILE '.headroom\bin'
$ManifestPath = Join-Path $GrokHome 'vibe-stack-manifest.json'

# winget: success / already installed / no upgrade available
$script:WingetOkCodes = @(0, -1978335189, -1978335215)

$script:Failed = New-Object System.Collections.Generic.List[string]
$script:GithubReleasePins = $null
$script:Warned = New-Object System.Collections.Generic.List[string]
$script:Ok = New-Object System.Collections.Generic.List[string]
function Get-StackVersion {
    $vf = Join-Path $ScriptRoot 'VERSION'
    if (Test-Path -LiteralPath $vf) {
        $v = (Get-Content -LiteralPath $vf -TotalCount 1).Trim()
        if ($v -match '^\d+\.\d+\.\d+') { return $v }
    }
    return '0.0.0'
}
$script:StackVersion = Get-StackVersion

$script:Manifest = [ordered]@{
    version              = 1
    stackVersion         = $script:StackVersion
    installedAt          = (Get-Date -Format 'o')
    scriptRoot           = $ScriptRoot
    grokHome             = $GrokHome
    pathEntries          = New-Object System.Collections.Generic.List[string]
    # Only stack-owned trees — never whole shared rules/skills/hooks roots
    stackDirs            = @(
        $TokenRoot
        $VibeRoot
    )
    stackFiles           = New-Object System.Collections.Generic.List[string]
    binShims             = @(
        'start-grok.cmd', 'start-grok.ps1', 'stop-grok-proxy.cmd',
        'vibe-review.ps1', 'install-vibe-hooks.ps1', 'doctor.ps1', 'checkov.cmd', 'rtk.exe', 'scc.exe', 'tokei.exe'
    )
    hookFiles            = @('token-saving.json', 'vibe-coding.json', 'serena-hooks.json')
    qualityGates         = @('pre-commit', 'pre-push', 'on-edit', 'rtk-enforce', 'ai-review-high')
    ruleFiles            = @('caveman.md', 'rtk.md', 'token-efficiency.md', 'vibe-coding.md')
    skillDirs            = @('caveman', 'token-save', 'vibe-coding')
    wingetIds            = New-Object System.Collections.Generic.List[string]
    npmPackages          = New-Object System.Collections.Generic.List[string]
    psModules            = @('PSScriptAnalyzer', 'Pester')
    pythonInstalledByUs  = $false
    gitInstalledByUs     = $false
    nodeInstalledByUs    = $false
    uvInstalledByUs      = $false
    serenaInstalledByUs  = $false
    repoHooksPath        = $null
    configBackup         = $null
}

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "  OK  $msg" -ForegroundColor Green; [void]$script:Ok.Add($msg) }
function Write-Warn2([string]$msg) { Write-Host "  WARN $msg" -ForegroundColor Yellow; [void]$script:Warned.Add($msg) }
function Write-Fail([string]$msg) { Write-Host "  FAIL $msg" -ForegroundColor Red; [void]$script:Failed.Add($msg) }
function Write-Info([string]$msg) { Write-Host "  ..  $msg" -ForegroundColor DarkGray }

function Test-CommandExists([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Ensure-Dir {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Paths)
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        if ($DryRun) { Write-Info "DRY mkdir $p"; continue }
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
}

function Copy-Tree([string]$From, [string]$To) {
    if (-not (Test-Path -LiteralPath $From)) { throw "Missing asset: $From" }
    Ensure-Dir $To
    if ($DryRun) { Write-Info "DRY copy $From -> $To"; return }
    Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force
}

function Add-UserPath {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [switch]$CreateIfMissing,
        [switch]$AlwaysRecord
    )
    if (-not $Dir) { return }
    $norm = $Dir.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $Dir)) {
        if ($CreateIfMissing) {
            # Only create user-owned dirs (never Program Files / system roots)
            $pf = ${env:ProgramFiles}
            $pf86 = ${env:ProgramFiles(x86)}
            $underSystem = ($pf -and $norm.StartsWith($pf.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) -or
                ($pf86 -and $norm.StartsWith($pf86.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) -or
                $norm.StartsWith('C:\Windows', [StringComparison]::OrdinalIgnoreCase)
            if ($underSystem) {
                Write-Info "Skip PATH (missing system dir, will not create): $Dir"
                return
            }
            Ensure-Dir $Dir
        } else {
            Write-Info "Skip PATH (dir not present yet): $Dir"
            return
        }
    }
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Info "Skip PATH (still missing): $Dir"
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
    $has = $false
    foreach ($p in $parts) {
        if ($p.TrimEnd('\') -ieq $norm) { $has = $true; break }
    }
    if (-not $has) {
        if ($DryRun) {
            Write-Info "DRY PATH += $Dir"
        } else {
            $newPath = if ($userPath.Trim()) { "$Dir;$userPath" } else { $Dir }
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Ok "User PATH += $Dir"
        }
    } else {
        Write-Info "PATH already has $Dir"
    }
    # Record for uninstall only when we prepended this dir, or AlwaysRecord on a
    # ~/.grok-owned path. Never record pre-existing Git/Node/npm/shared bins —
    # old AlwaysRecord + uninstall stripped User PATH of tools the user already had.
    $stackOwned = $false
    if ($GrokHome) {
        $g = $GrokHome.TrimEnd('\')
        $stackOwned = $norm.StartsWith($g, [StringComparison]::OrdinalIgnoreCase)
    }
    if ((-not $has) -or ($AlwaysRecord -and $stackOwned)) {
        if (-not $script:Manifest.pathEntries.Contains($Dir)) {
            [void]$script:Manifest.pathEntries.Add($Dir)
        }
    }
    if ($env:PATH -notlike "*$Dir*") { $env:PATH = "$Dir;$env:PATH" }
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Required
    )
    if (-not (Test-CommandExists 'winget')) {
        $msg = "winget missing; cannot install $Label ($Id)"
        if ($Required) { Write-Fail $msg } else { Write-Warn2 $msg }
        return $false
    }
    Write-Info "winget install $Id ($Label)"
    if ($DryRun) {
        Write-Info "DRY winget $Id"
        if (-not $script:Manifest.wingetIds.Contains($Id)) { [void]$script:Manifest.wingetIds.Add($Id) }
        return $true
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & winget install --id $Id -e --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    Refresh-ProcessPath
    if ($script:WingetOkCodes -contains $code) {
        Write-Ok "winget $Label (exit $code)"
        if (-not $script:Manifest.wingetIds.Contains($Id)) { [void]$script:Manifest.wingetIds.Add($Id) }
        return $true
    }
    # Sometimes package is usable even when winget returns odd codes
    $msg = "winget $Label exit=$code"
    if ($Required) { Write-Fail $msg } else { Write-Warn2 $msg }
    return $false
}

function Test-GrokInstalled {
    $cands = New-Object System.Collections.Generic.List[string]
    $local = Join-Path $GrokBin 'grok.exe'
    if (Test-Path -LiteralPath $local) { [void]$cands.Add($local) }
    $cmd = Get-Command grok -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { [void]$cands.Add($cmd.Source) }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Find-Python310Plus {
    if (Test-CommandExists 'py') {
        try {
            $ver = & py -3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            if ($ver -match '^3\.(\d+)$' -and [int]$Matches[1] -ge 10) {
                return @{ Exe = 'py'; Args = @('-3'); Version = $ver.Trim() }
            }
        } catch {}
    }
    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if ($cmd.Source -match 'WindowsApps\\python') { continue }
        try {
            $ver = & $cmd.Source -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            if ($ver -match '^3\.(\d+)$' -and [int]$Matches[1] -ge 10) {
                return @{ Exe = $cmd.Source; Args = @(); Version = $ver.Trim() }
            }
        } catch {}
    }
    $guesses = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310\python.exe'),
        'C:\Python313\python.exe',
        'C:\Python312\python.exe',
        'C:\Program Files\Python313\python.exe',
        'C:\Program Files\Python312\python.exe'
    )
    foreach ($g in $guesses) {
        if (-not (Test-Path -LiteralPath $g)) { continue }
        try {
            $ver = & $g -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            if ($ver -match '^3\.(\d+)$' -and [int]$Matches[1] -ge 10) {
                $dir = Split-Path $g -Parent
                $env:PATH = "$dir;$dir\Scripts;$env:PATH"
                return @{ Exe = $g; Args = @(); Version = $ver.Trim() }
            }
        } catch {}
    }
    return $null
}

function Ensure-Python {
    $found = Find-Python310Plus
    if ($found) {
        Write-Info "Python $($found.Version): $($found.Exe) $($found.Args -join ' ')"
        return $found
    }
    if ($SkipPythonInstall) {
        Write-Fail "Python 3.10+ missing and -SkipPythonInstall set"
        return $null
    }
    Write-Warn2 "Python 3.10+ not found - installing via winget"
    foreach ($id in @('Python.Python.3.12', 'Python.Python.3.13', 'Python.Python.3.11')) {
        if ($DryRun) {
            Write-Info "DRY install $id"
            $script:Manifest.pythonInstalledByUs = $true
            return @{ Exe = 'py'; Args = @('-3'); Version = 'dry-run' }
        }
        if (Invoke-WingetInstall -Id $id -Label "Python ($id)" -Required:$false) {
            $script:Manifest.pythonInstalledByUs = $true
            Start-Sleep -Seconds 2
            Refresh-ProcessPath
            $found = Find-Python310Plus
            if ($found) {
                Write-Ok "Python $($found.Version) ready"
                return $found
            }
        }
    }
    Write-Fail "Python 3.10+ still not found after winget"
    Write-Info "Manual: winget install Python.Python.3.12  (check Add to PATH)"
    return $null
}

function Ensure-Git {
    if (Test-CommandExists 'git') {
        Write-Ok "Git present: $((git --version 2>&1 | Select-Object -First 1))"
        return $true
    }
    if ($SkipGitInstall) {
        Write-Fail "Git missing and -SkipGitInstall set (required for hooks/review)"
        return $false
    }
    Write-Warn2 "Git not found - installing via winget"
    $ok = Invoke-WingetInstall -Id 'Git.Git' -Label 'Git' -Required:$true
    if ($ok) {
        $script:Manifest.gitInstalledByUs = $true
        Refresh-ProcessPath
        # Git often lands in Program Files
        $gitGuess = @(
            'C:\Program Files\Git\cmd',
            'C:\Program Files\Git\bin'
        )
        foreach ($g in $gitGuess) {
            if (Test-Path $g) { $env:PATH = "$g;$env:PATH" }
        }
    }
    if (Test-CommandExists 'git') {
        Write-Ok "Git ready: $((git --version 2>&1 | Select-Object -First 1))"
        return $true
    }
    Write-Fail "Git still not on PATH"
    return $false
}

function Ensure-Node {
    if ((Test-CommandExists 'node') -and (Test-CommandExists 'npm')) {
        Write-Ok "Node present: $((node -v 2>&1)) / npm $((npm -v 2>&1))"
        return $true
    }
    if ($SkipNodeInstall) {
        Write-Warn2 "Node missing and -SkipNodeInstall set (npm scanners will be skipped)"
        return $false
    }
    Write-Warn2 "Node.js not found - installing LTS via winget"
    $ok = Invoke-WingetInstall -Id 'OpenJS.NodeJS.LTS' -Label 'Node.js LTS' -Required:$false
    if (-not $ok) {
        $ok = Invoke-WingetInstall -Id 'OpenJS.NodeJS' -Label 'Node.js' -Required:$false
    }
    if ($ok) { $script:Manifest.nodeInstalledByUs = $true }
    Refresh-ProcessPath
    $nodeDirs = @(
        'C:\Program Files\nodejs',
        (Join-Path $env:APPDATA 'npm')
    )
    foreach ($d in $nodeDirs) {
        if (Test-Path $d) { $env:PATH = "$d;$env:PATH" }
    }
    if ((Test-CommandExists 'node') -and (Test-CommandExists 'npm')) {
        Write-Ok "Node ready: $((node -v 2>&1))"
        return $true
    }
    Write-Warn2 "Node/npm still not on PATH - npm global packages will be skipped"
    return $false
}

function Ensure-Uv {
    if (Test-CommandExists 'uv') {
        Write-Ok "uv present"
        return $true
    }
    if ($SkipSerena) { Write-Info "uv skip (Serena skipped)"; return $false }
    Write-Info "Installing uv (for Serena)"
    if (Invoke-WingetInstall -Id 'astral-sh.uv' -Label 'uv' -Required:$false) {
        $script:Manifest.uvInstalledByUs = $true
        Refresh-ProcessPath
        $uvGuess = @(
            (Join-Path $env:USERPROFILE '.local\bin'),
            (Join-Path $env:USERPROFILE '.cargo\bin'),
            (Join-Path $env:LOCALAPPDATA 'Programs\uv')
        )
        foreach ($d in $uvGuess) {
            if (Test-Path $d) { $env:PATH = "$d;$env:PATH" }
        }
    }
    if (Test-CommandExists 'uv') {
        Write-Ok "uv ready"
        return $true
    }
    Write-Warn2 "uv not available - Serena install may fall back to pip"
    return $false
}

function Test-PipFileLockText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    # WinError 32 / 5, EN, and Swedish sharing-violation fragments (OS locale).
    return [bool]($Text -match '(?i)(WinError\s*32|WinError\s*5|sharing violation|being used by another process|cannot access the file|kan inte komma |g.r inte att komma |det g.r inte att komma)')
}

function Invoke-StartGrokChild {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$GrokArgs
    )
    # start-grok uses `exit`; `&` / dot-source kills this installer runspace.
    if (-not (Test-Path -LiteralPath $ScriptPath)) { return 1 }
    $arg = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($GrokArgs)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -Wait -PassThru -WindowStyle Hidden
    if ($p) { return [int]$p.ExitCode }
    return 1
}

function Stop-HeadroomServices {
    $startPs1 = Join-Path $TokenRoot 'scripts\start-grok.ps1'
    $stopShim = Join-Path $GrokBin 'stop-grok-proxy.cmd'
    if (Test-Path -LiteralPath $startPs1) {
        Write-Info "Stopping Headroom proxy (unlock venv for pip)"
        try { Invoke-StartGrokChild -ScriptPath $startPs1 -GrokArgs @('-StopProxy') | Out-Null } catch {}
        try { Invoke-StartGrokChild -ScriptPath $startPs1 -GrokArgs @('-StopProxy', '-Port', '8788') | Out-Null } catch {}
    } elseif (Test-Path -LiteralPath $stopShim) {
        try { & $stopShim 2>$null | Out-Null } catch {}
    }
}

function Get-VenvLockerPids {
    param([string]$VenvDir)
    if (-not $VenvDir -or -not (Test-Path -LiteralPath $VenvDir)) { return @() }
    $root = [IO.Path]::GetFullPath($VenvDir).TrimEnd('\')
    $scripts = Join-Path $root 'Scripts'
    $needles = @(
        (Join-Path $scripts 'headroom.exe'),
        (Join-Path $scripts 'python.exe'),
        (Join-Path $scripts 'pythonw.exe'),
        (Join-Path $TokenRoot 'scripts\headroom-mcp-serve.cmd')
    )
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        foreach ($proc in Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) {
            if (-not $proc.ProcessId) { continue }
            $procId = [int]$proc.ProcessId
            if ($procId -eq $PID) { continue }
            $exe = [string]$proc.ExecutablePath
            $cmd = [string]$proc.CommandLine
            $hit = $false
            if ($exe) {
                if ($exe.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
                    $exe.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
                    $hit = $true
                }
            }
            if (-not $hit -and $cmd) {
                foreach ($n in $needles) {
                    if ($n -and $cmd.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $hit = $true
                        break
                    }
                }
                if (-not $hit -and $cmd -match '(?i)headroom(\.exe)?(\s|").*mcp\s+serve') { $hit = $true }
            }
            if ($hit) { [void]$ids.Add($procId) }
        }
    } catch {}
    return @($ids)
}

function Stop-VenvLockers {
    param(
        [string]$VenvDir,
        [string]$Label
    )
    if ($Label -eq 'headroom') {
        Stop-HeadroomServices
    }
    $lockPids = @(Get-VenvLockerPids -VenvDir $VenvDir)
    foreach ($procId in $lockPids) {
        Write-Info "Stopping venv locker PID $procId ($Label)"
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
    if ($lockPids.Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
}

function Get-PipLockedPaths {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Text, '[''"]([^''"]+\.exe)[''"]')) {
        $p = $m.Groups[1].Value
        if ($p) { $found.Add($p) }
    }
    return @($found)
}

function Unlock-VenvEntryPoints {
    param(
        [string]$VenvDir,
        [string[]]$OnlyPaths
    )
    $scripts = Join-Path $VenvDir 'Scripts'
    if (-not (Test-Path -LiteralPath $scripts)) { return }
    $keep = @{
        'python.exe'  = $true
        'pythonw.exe' = $true
        'python3.exe' = $true
    }
    $files = @()
    if ($OnlyPaths -and @($OnlyPaths).Count -gt 0) {
        $files = @($OnlyPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue })
    } else {
        # Never rename the whole Scripts dir. Only common lock magnets.
        foreach ($n in @('headroom.exe', 'pip.exe', 'pip3.exe')) {
            $p = Join-Path $scripts $n
            if (Test-Path -LiteralPath $p) { $files += ,(Get-Item -LiteralPath $p) }
        }
    }
    foreach ($item in $files) {
        if (-not $item) { continue }
        if ($keep.ContainsKey($item.Name.ToLowerInvariant())) { continue }
        $newName = $item.Name + '.old'
        $bak = Join-Path $scripts $newName
        if (Test-Path -LiteralPath $bak) {
            $newName = '{0}.old-{1}' -f $item.Name, [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
        }
        try {
            Rename-Item -LiteralPath $item.FullName -NewName $newName -ErrorAction Stop
            Write-Info "Renamed locked $($item.Name) -> $newName"
        } catch {
            Write-Info "Could not rename $($item.Name): $_"
        }
    }
}

function Restore-VenvOldEntryPoints {
    param([string]$VenvDir)
    $scripts = Join-Path $VenvDir 'Scripts'
    if (-not (Test-Path -LiteralPath $scripts)) { return }
    Get-ChildItem -LiteralPath $scripts -Filter '*.old*' -ErrorAction SilentlyContinue | ForEach-Object {
        $origName = $_.Name -replace '\.old(-\d+)?$', ''
        if (-not $origName -or $origName -eq $_.Name) { return }
        $orig = Join-Path $scripts $origName
        if (-not (Test-Path -LiteralPath $orig)) {
            try {
                Rename-Item -LiteralPath $_.FullName -NewName $origName -ErrorAction Stop
                Write-Info "Restored $origName from $($_.Name)"
            } catch {
                Write-Warn2 "Could not restore $origName : $_"
            }
        } else {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-VenvAndPip {
    param(
        [string]$VenvDir,
        [string]$ReqFile,
        [string]$Label,
        $PyInfo
    )
    if (-not $PyInfo) {
        Write-Fail "No Python for $Label"
        return $false
    }
    if (-not (Test-Path -LiteralPath $ReqFile)) {
        Write-Fail "Missing requirements: $ReqFile"
        return $false
    }
    Ensure-Dir (Split-Path $VenvDir -Parent)
    $pyExe = Join-Path $VenvDir 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pyExe)) {
        Write-Info "Creating venv $VenvDir"
        if (-not $DryRun) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $PyInfo.Exe @($PyInfo.Args + @('-m', 'venv', $VenvDir))
            } finally {
                $ErrorActionPreference = $prev
            }
            if (-not (Test-Path -LiteralPath $pyExe)) {
                Write-Fail "venv create failed: $VenvDir"
                return $false
            }
        }
    } else {
        Write-Info "venv exists: $VenvDir"
    }
    if ($DryRun) {
        Write-Info "DRY pip install -U -r $ReqFile"
        return $true
    }
    # Reinstall while proxy/MCP hold headroom.exe -> WinError 32. Stop, then retry/rename.
    if (Test-Path -LiteralPath $pyExe) {
        Stop-VenvLockers -VenvDir $VenvDir -Label $Label
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $maxTries = 4
        $lastPipText = ''
        for ($attempt = 1; $attempt -le $maxTries; $attempt++) {
            $forceReinstall = $false
            if ($attempt -gt 1) {
                Write-Info "pip retry $attempt/$maxTries after file lock ($Label)"
                Stop-VenvLockers -VenvDir $VenvDir -Label $Label
                Unlock-VenvEntryPoints -VenvDir $VenvDir -OnlyPaths (Get-PipLockedPaths $lastPipText)
                $forceReinstall = $true
                Start-Sleep -Seconds 1
            }
            $null = & $pyExe -m pip install --upgrade pip wheel setuptools 2>&1
            Write-Info "pip install -U -r $ReqFile ($Label) - this can take several minutes"
            $pipArgs = @('install', '--upgrade')
            if ($forceReinstall) { $pipArgs += '--force-reinstall' }
            $pipArgs += @('-r', $ReqFile)
            $pipOut = & $pyExe -m pip @pipArgs 2>&1
            $code = $LASTEXITCODE
            $pipText = ($pipOut | Out-String)
            $lastPipText = $pipText
            $pipOut | ForEach-Object {
                $line = "$_"
                if ($line -match '(?i)(ERROR:(?! pip.s dependency)|No matching distribution|Could not find|failed building|WinError)') {
                    Write-Host "    $line" -ForegroundColor DarkYellow
                }
            }
            if ($code -eq 0) {
                Restore-VenvOldEntryPoints -VenvDir $VenvDir
                Write-Ok "pip $Label"
                return $true
            }
            if ((Test-PipFileLockText $pipText) -and $attempt -lt $maxTries) {
                Write-Warn2 "pip $Label file in use (WinError 32) - stopping lockers and retrying"
                continue
            }
            Restore-VenvOldEntryPoints -VenvDir $VenvDir
            if (Test-PipFileLockText $pipText) {
                Write-Fail "pip install $Label (exit $code) - file in use; close Grok/Headroom and re-run"
                return $false
            }
            Write-Fail "pip install $Label (exit $code)"
            return $false
        }
        Restore-VenvOldEntryPoints -VenvDir $VenvDir
        Write-Fail "pip install $Label (retries exhausted)"
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Merge-GrokConfig {
    $tomlHelper = $null
    foreach ($p in @(
            (Join-Path $TokenRoot 'scripts\GrokToml.ps1'),
            (Join-Path $Assets 'token-saving\scripts\GrokToml.ps1')
        )) {
        if (Test-Path -LiteralPath $p) { $tomlHelper = $p; break }
    }
    if (-not $tomlHelper) { throw "GrokToml.ps1 not found (deploy token-saving/scripts first)" }
    . $tomlHelper
    $cfgPath = Join-Path $GrokHome 'config.toml'
    $snippetPath = Join-Path $Assets 'config\config-snippet.toml'
    if (-not (Test-Path -LiteralPath $snippetPath)) {
        Write-Fail "missing config snippet"
        return
    }

    $hr = Join-Path $TokenRoot 'scripts\headroom-mcp-serve.cmd'
    $serenaExe = Resolve-SerenaExe
    $serenaOn = (-not $SkipSerena) -and (Test-SerenaAlive $serenaExe)
    if (-not $serenaOn) {
        if ($SkipSerena) {
            Write-Info "config: Serena MCP disabled (SkipSerena)"
        } else {
            Write-Fail "config: no working serena.exe - MCP server will be disabled"
        }
        if (-not $serenaExe) { $serenaExe = Join-Path $LocalBin 'serena.exe' }
    }

    if ($DryRun) { Write-Info "DRY merge config.toml"; return }

    Ensure-Dir $GrokHome
    $existed = Test-Path -LiteralPath $cfgPath
    if (-not $existed) {
        Write-Utf8NoBomFile -Path $cfgPath -Content "[cli]`ninstaller = `"internal`"`n"
    }

    $result = Repair-GrokConfigFile -ConfigPath $cfgPath -SnippetPath $snippetPath -HeadroomCmd $hr -SerenaExe $serenaExe -SerenaEnabled $serenaOn -BackupSuffix ("install-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($result.BackupPath) {
        $script:Manifest.configBackup = $result.BackupPath
        Write-Info "Config backup: $($result.BackupPath)"
    }
    if ($result.Quarantined) {
        Write-Info "Quarantined sidecar: $($result.Quarantined)"
    }
    if ($existed) {
        Write-Ok "Merged vibe stack into config.toml"
    } else {
        Write-Ok "Created config.toml"
        [void]$script:Manifest.stackFiles.Add($cfgPath)
    }
}

function Write-Utf8NoBomFile([string]$Path, [string]$Content) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Install-HooksJson {
    $hooksDir = Join-Path $GrokHome 'hooks'
    Ensure-Dir $hooksDir

    # Live JSON is materialized from assets/hooks templates (placeholders → absolute
    # -File paths). Do not rebuild via ConvertTo-Json hashtables: that drifted from
    # the templates (stale always-on Stop nag) and PS 5.1 unwraps single-element arrays.
    $tplDir = Join-Path $Assets 'hooks'
    $homeJson = $GrokHome.Replace('\', '\\')

    function Write-HookFromTemplate([string]$Name) {
        $src = Join-Path $tplDir $Name
        if (-not (Test-Path -LiteralPath $src)) { throw "Missing hook template: $src" }
        $raw = Get-Content -LiteralPath $src -Raw
        $out = $raw.Replace('__GROK_HOME__', $homeJson)
        if ($out.Contains('__GROK_HOME__')) { throw "Unsubstituted placeholder in $Name" }
        if ($Name -eq 'vibe-coding.json' -and $out -notmatch 'run-vibe-stop-remind\.ps1') {
            throw "vibe-coding template missing run-vibe-stop-remind.ps1"
        }
        $null = $out | ConvertFrom-Json
        if ($DryRun) { Write-Info "DRY write hooks\$Name"; return }
        Write-Utf8NoBomFile (Join-Path $hooksDir $Name) $out
    }

    Write-HookFromTemplate 'token-saving.json'
    Write-HookFromTemplate 'vibe-coding.json'
    if ($DryRun) { return }

    # Serena MCP stays in config.toml. Do NOT install serena-hooks PreToolUse by default:
    # serena-hooks "remind" on every read_file/grep exits silent-allow and Grok UI counts
    # "hooks: N failed" even with a wrapper (host/stdin quirks). Opt-in via Enable-SerenaRemindHooks.ps1.
    $staleSerena = Join-Path $hooksDir 'serena-hooks.json'
    if (Test-Path -LiteralPath $staleSerena) {
        Remove-Item -LiteralPath $staleSerena -Force -ErrorAction SilentlyContinue
        Write-Info "removed serena-hooks.json (remind on read caused false hook failures)"
    }
    Write-Ok "hooks: token-saving (rtk-enforce), vibe-coding (on-edit + gated stop-remind)"
}

function Get-GithubReleasePin([string]$DestName) {
    if ($null -eq $script:GithubReleasePins) {
        $pinPath = Join-Path $Assets 'requirements\github-release-pins.json'
        $script:GithubReleasePins = @()
        if (Test-Path -LiteralPath $pinPath) {
            try {
                $doc = (Get-Content -LiteralPath $pinPath -Raw) | ConvertFrom-Json
                if ($doc -and $doc.pins) { $script:GithubReleasePins = @($doc.pins) }
            } catch {
                Write-Fail "github-release-pins.json parse failed: $_"
            }
        }
    }
    foreach ($p in $script:GithubReleasePins) {
        if ($p.dest -eq $DestName) { return $p }
    }
    return $null
}

function Test-FileSha256([string]$Path, [string]$Expected) {
    $want = (($Expected -replace '(?i)^sha256:', '')).Trim().ToLowerInvariant()
    if ($want.Length -ne 64 -or $want -notmatch '^[0-9a-f]{64}$') { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $got = [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '').ToLowerInvariant()
    } finally {
        $fs.Dispose()
        $sha.Dispose()
    }
    return ($got -eq $want)
}

function Test-GithubReleasePinShape($Pin) {
    if (-not $Pin) { return $false }
    if ([string]$Pin.repo -notmatch '^[\w.-]+/[\w.-]+$') { return $false }
    if ([string]$Pin.tag -notmatch '^[\w./-]+$') { return $false }
    if ([string]$Pin.asset -notmatch '^[\w.+-]+$') { return $false }
    $sha = (([string]$Pin.sha256) -replace '(?i)^sha256:', '').Trim()
    if ($sha -notmatch '^[0-9a-fA-F]{64}$') { return $false }
    $dsha = [string]$Pin.destSha256
    if ($dsha -and $dsha -notmatch '^[0-9a-fA-F]{64}$') { return $false }
    return $true
}

function Install-GithubReleaseBinary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestName
    )
    Ensure-Dir $GrokBin
    $dest = Join-Path $GrokBin $DestName
    $pin = Get-GithubReleasePin $DestName
    if (-not $pin -or -not (Test-GithubReleasePinShape $pin)) {
        Write-Fail "no valid GitHub pin for $DestName (assets/requirements/github-release-pins.json)"
        return $false
    }
    $tag = [string]$pin.tag
    $asset = [string]$pin.asset
    $repo = [string]$pin.repo
    $sha = [string]$pin.sha256
    $destSha = [string]$pin.destSha256
    $reinstall = $false
    if (Test-Path -LiteralPath $dest) {
        if ($destSha -and (Test-FileSha256 $dest $destSha)) {
            Write-Info "$DestName already present (hash ok)"
            return $true
        }
        if ($destSha) {
            Write-Warn2 "$DestName present but dest hash mismatch - reinstalling"
            $reinstall = $true
        } else {
            Write-Info "$DestName already present"
            return $true
        }
    }
    if ($DryRun) {
        if ($reinstall) {
            Write-Info ('DRY would reinstall {0} from {1}@{2} ({3})' -f $DestName, $repo, $tag, $asset)
        } else {
            Write-Info ('DRY download {0} from {1}@{2} ({3})' -f $DestName, $repo, $tag, $asset)
        }
        return $true
    }
    $removedDest = $false
    if ($reinstall -and (Test-Path -LiteralPath $dest)) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        $removedDest = -not (Test-Path -LiteralPath $dest)
    }
    $url = 'https://github.com/{0}/releases/download/{1}/{2}' -f $repo, $tag, $asset
    $tmp = Join-Path $env:TEMP ("gvibe-" + [guid]::NewGuid().ToString('n'))
    try {
        Ensure-Dir $tmp
        $dl = Join-Path $tmp $asset
        Write-Info ('download {0} {1}@{2}' -f $DestName, $repo, $tag)
        Invoke-WebRequest -Uri $url -OutFile $dl -UseBasicParsing -Headers @{
            'User-Agent' = 'Install-GrokVibeStack'
        }
        if (-not (Test-FileSha256 $dl $sha)) {
            Write-Fail ('SHA256 mismatch for {0} ({1} from {2}@{3}) - not installing' -f $DestName, $asset, $repo, $tag)
            return $false
        }
        if ($asset -match '\.zip$') {
            Expand-Archive -Path $dl -DestinationPath $tmp -Force
            $exe = Get-ChildItem -Path $tmp -Recurse -Filter $DestName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $exe) {
                $exe = Get-ChildItem -Path $tmp -Recurse -Filter *.exe -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ieq $DestName -or $_.BaseName -ieq ([IO.Path]::GetFileNameWithoutExtension($DestName)) } |
                    Select-Object -First 1
            }
            if ($exe) { Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force }
        } elseif ($asset -match '\.exe$') {
            Copy-Item -LiteralPath $dl -Destination $dest -Force
        } else {
            Write-Fail "pinned asset for $DestName is not .zip/.exe: $asset"
            return $false
        }
        if ((Test-Path -LiteralPath $dest) -and ((-not $destSha) -or (Test-FileSha256 $dest $destSha))) {
            Write-Ok ('Installed {0} ({1}@{2}, hash ok)' -f $DestName, $repo, $tag)
            return $true
        }
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            Write-Fail "placed $DestName but dest SHA256 mismatch - removed"
            return $false
        }
        if ($removedDest) {
            Write-Fail "Failed to place $DestName after verified download (prior dest removed)"
        } else {
            Write-Warn2 "Failed to place $DestName after verified download"
        }
        return $false
    } catch {
        if ($removedDest) {
            Write-Fail "Download $DestName failed after dest removed: $_"
        } else {
            Write-Warn2 "Download $DestName failed: $_"
        }
        return $false
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-SerenaExe {
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

function Install-Serena {
    if ($SkipSerena) { Write-Info "Skip Serena"; return }
    $ensure = Join-Path $TokenRoot 'scripts\ensure-serena.ps1'
    if (-not (Test-Path -LiteralPath $ensure)) {
        $ensure = Join-Path $Assets 'token-saving\scripts\ensure-serena.ps1'
    }
    if (-not (Test-Path -LiteralPath $ensure)) {
        Write-Fail "ensure-serena.ps1 missing after deploy"
        return
    }
    if ($DryRun) {
        Write-Info "DRY ensure-serena"
        return
    }
    $had = Test-SerenaAlive (Resolve-SerenaExe)
    $here = (Get-Location).Path
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Named parameter, not string[] splat. @('-RepoPath', $here) passed two positionals
        # (value '-RepoPath', then the path) and PowerShell errored on the leftover path.
        & $ensure -RepoPath $here
        $code = $LASTEXITCODE
        Refresh-ProcessPath
        $env:PATH = ($LocalBin + ';' + $GrokBin + ';' + $env:PATH)
        $exe = Resolve-SerenaExe
        if ((Test-SerenaAlive $exe)) {
            if (-not $had) { $script:Manifest.serenaInstalledByUs = $true }
            Write-Ok "Serena ready: $exe"
            return
        }
        if ($code -ne 0) {
            Write-Fail "ensure-serena failed (exit $code)"
        } else {
            Write-Fail "ensure-serena ran but serena.exe not runnable"
        }
    } catch {
        Write-Fail "ensure-serena: $_"
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Install-PsModules {
    foreach ($mod in @('PSScriptAnalyzer', 'Pester')) {
        $have = Get-Module -ListAvailable $mod -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($have -and -not ($mod -eq 'Pester' -and $have.Version.Major -lt 5)) {
            Write-Ok "PS module $mod $($have.Version)"
            continue
        }
        if ($mod -eq 'Pester' -and $have -and $have.Version.Major -lt 5) {
            Write-Info "Upgrading Pester (found $($have.Version), want 5+)"
        }
        Write-Info "Install-Module $mod -Scope CurrentUser"
        if ($DryRun) { continue }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($mod -eq 'Pester') {
                Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber -MinimumVersion 5.0.0 -ErrorAction Stop
            } else {
                Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            }
            Write-Ok "Installed PS module $mod"
        } catch {
            Write-Warn2 "PS module $mod failed: $_"
        } finally {
            $ErrorActionPreference = $prev
        }
    }
}

function Install-NpmGlobals {
    if ($SkipNpm) { Write-Info "Skip npm packages"; return }
    if (-not (Test-CommandExists 'npm')) {
        Write-Warn2 "npm missing - skip global packages"
        return
    }
    foreach ($pkg in @('jscpd', 'markdownlint-cli', 'prettier', 'eslint', 'typescript')) {
        Write-Info "npm i -g $pkg"
        if ($DryRun) {
            [void]$script:Manifest.npmPackages.Add($pkg)
            continue
        }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & npm install -g $pkg 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "npm $pkg"
                if (-not $script:Manifest.npmPackages.Contains($pkg)) {
                    [void]$script:Manifest.npmPackages.Add($pkg)
                }
            } else {
                Write-Warn2 "npm $pkg exit=$LASTEXITCODE"
            }
        } finally {
            $ErrorActionPreference = $prev
        }
    }
    $npmBin = Join-Path $env:APPDATA 'npm'
    if (Test-Path $npmBin) { Add-UserPath $npmBin -AlwaysRecord }
}

function Save-Manifest {
    if ($DryRun) { Write-Info "DRY skip manifest write"; return }
    # Convert lists to arrays for JSON
    $obj = [ordered]@{
        version             = $script:Manifest.version
        stackVersion        = $script:Manifest.stackVersion
        installedAt         = $script:Manifest.installedAt
        scriptRoot          = $script:Manifest.scriptRoot
        grokHome            = $script:Manifest.grokHome
        pathEntries         = @($script:Manifest.pathEntries)
        stackDirs           = @($script:Manifest.stackDirs)
        stackFiles          = @($script:Manifest.stackFiles)
        binShims            = @($script:Manifest.binShims)
        hookFiles           = @($script:Manifest.hookFiles)
        ruleFiles           = @($script:Manifest.ruleFiles)
        skillDirs           = @($script:Manifest.skillDirs)
        wingetIds           = @($script:Manifest.wingetIds)
        npmPackages         = @($script:Manifest.npmPackages)
        psModules           = @($script:Manifest.psModules)
        pythonInstalledByUs = [bool]$script:Manifest.pythonInstalledByUs
        gitInstalledByUs    = [bool]$script:Manifest.gitInstalledByUs
        nodeInstalledByUs   = [bool]$script:Manifest.nodeInstalledByUs
        uvInstalledByUs     = [bool]$script:Manifest.uvInstalledByUs
        serenaInstalledByUs = [bool]$script:Manifest.serenaInstalledByUs
        repoHooksPath       = $script:Manifest.repoHooksPath
        configBackup        = $script:Manifest.configBackup
        neverRemove         = @('grok.exe', 'grok.exe.old', 'agent.exe', 'auth.json', 'sessions')
    }
    Ensure-Dir $GrokHome
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ManifestPath, ($obj | ConvertTo-Json -Depth 6), $utf8)
    Write-Ok "Manifest: $ManifestPath"
}

function Test-StackHealth {
    Write-Step "Post-install verification"
    $checks = @(
        @{ Name = 'grok'; Path = (Join-Path $GrokBin 'grok.exe'); Cmd = 'grok' },
        @{ Name = 'start-grok'; Path = (Join-Path $GrokBin 'start-grok.cmd') },
        @{ Name = 'headroom'; Path = (Join-Path $TokenRoot 'venv\Scripts\headroom.exe') },
        @{ Name = 'rtk'; Path = (Join-Path $GrokBin 'rtk.exe'); Cmd = 'rtk' },
        @{ Name = 'vibe-review'; Path = (Join-Path $GrokBin 'vibe-review.ps1') },
        @{ Name = 'run-vibe-scans'; Path = (Join-Path $VibeRoot 'scripts\run-vibe-scans.ps1') },
        @{ Name = 'caveman rule'; Path = (Join-Path $GrokHome 'rules\caveman.md') },
        @{ Name = 'token-saving hook'; Path = (Join-Path $GrokHome 'hooks\token-saving.json') },
        @{ Name = 'vibe-coding hook'; Path = (Join-Path $GrokHome 'hooks\vibe-coding.json') },
        @{ Name = 'config.toml'; Path = (Join-Path $GrokHome 'config.toml') },
        @{ Name = 'GrokToml.ps1'; Path = (Join-Path $TokenRoot 'scripts\GrokToml.ps1') },
        @{ Name = 'config-snippet.toml'; Path = (Join-Path $TokenRoot 'config-snippet.toml') },
        @{ Name = 'manifest'; Path = $ManifestPath }
    )
    $bad = 0
    foreach ($c in $checks) {
        $ok = $false
        if ($c.Path -and (Test-Path -LiteralPath $c.Path)) { $ok = $true }
        elseif ($c.Cmd -and (Test-CommandExists $c.Cmd)) { $ok = $true }
        if ($ok) { Write-Ok "check $($c.Name)" }
        else { Write-Fail "check $($c.Name) missing"; $bad++ }
    }
    # soft checks
    foreach ($soft in @('git', 'node', 'npm', 'rg', 'gitleaks')) {
        if (Test-CommandExists $soft) { Write-Ok "check cmd $soft" }
        else { Write-Warn2 "check cmd $soft missing (some features degraded)" }
    }
    $serenaCheck = Resolve-SerenaExe
    if ($SkipSerena) {
        Write-Info "check serena skipped"
    } elseif (Test-SerenaAlive $serenaCheck) {
        Write-Ok "check serena"
    } else {
        Write-Fail "check serena missing or not runnable"
        $bad++
    }
    $cfgHealth = Join-Path $GrokHome 'config.toml'
    $tomlHelper = Join-Path $TokenRoot 'scripts\GrokToml.ps1'
    if ((Test-Path -LiteralPath $cfgHealth) -and (Test-Path -LiteralPath $tomlHelper)) {
        try {
            . $tomlHelper
            $cfgRaw = Read-Utf8NoBomFile -Path $cfgHealth
            $cfgCheck = Test-VibeToml -Raw $cfgRaw
            if ($cfgCheck.Ok) {
                Write-Ok "check config.toml parse (Headroom override present, no duplicate keys/tables)"
            } else {
                Write-Fail ("check config.toml: {0}" -f ($cfgCheck.Errors -join '; '))
                $bad++
            }
        } catch {
            Write-Fail "check config.toml: $_"
            $bad++
        }
    }
    return ($bad -eq 0)
}

# ===================== MAIN =====================
Write-Host ""
Write-Host "+================================================================+" -ForegroundColor Magenta
Write-Host ('|  Install-GrokVibeStack  {0,-39}|' -f $script:StackVersion) -ForegroundColor Magenta
Write-Host "|  Full stack for machines that only have Grok Build CLI         |" -ForegroundColor Magenta
Write-Host "+================================================================+" -ForegroundColor Magenta
Write-Host "Assets: $Assets"
Write-Host "Target: $GrokHome"
if ($DryRun) { Write-Host "MODE: DRY RUN" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $Assets)) {
    Write-Error "assets/ folder missing next to this script. Copy/clone the full repo."
    exit 2
}

Write-Step "Check Grok Build"
$grokPath = Test-GrokInstalled
if (-not $grokPath) {
    Write-Host ""
    Write-Host "Grok Build is NOT installed (grok.exe not found)." -ForegroundColor Red
    Write-Host "Install Grok first, then re-run:" -ForegroundColor Yellow
    Write-Host "  https://x.ai/cli" -ForegroundColor Yellow
    exit 1
}
Write-Ok "Grok found: $grokPath"

if (-not (Test-CommandExists 'winget')) {
    Write-Warn2 "winget not found - auto-install of Python/Git/Node/CLIs will fail. Install App Installer from Microsoft Store."
}

Write-Step "Deploy stack files into ~/.grok"
Ensure-Dir $GrokHome $GrokBin $TokenRoot $VibeRoot $LocalBin $HeadroomBin
Ensure-Dir (Join-Path $TokenRoot 'logs') (Join-Path $TokenRoot 'state') (Join-Path $TokenRoot 'scripts')
Ensure-Dir (Join-Path $VibeRoot 'scripts')
Ensure-Dir (Join-Path $GrokHome 'rules') (Join-Path $GrokHome 'skills') (Join-Path $GrokHome 'hooks')

Copy-Tree (Join-Path $Assets 'rules') (Join-Path $GrokHome 'rules')
Copy-Tree (Join-Path $Assets 'skills') (Join-Path $GrokHome 'skills')
Copy-Tree (Join-Path $Assets 'token-saving\scripts') (Join-Path $TokenRoot 'scripts')
if (Test-Path (Join-Path $Assets 'token-saving\README.md')) {
    if (-not $DryRun) { Copy-Item (Join-Path $Assets 'token-saving\README.md') (Join-Path $TokenRoot 'README.md') -Force }
}
Copy-Tree (Join-Path $Assets 'vibe-tools\scripts') (Join-Path $VibeRoot 'scripts')
if (-not $DryRun) {
    Copy-Item (Join-Path $Assets 'vibe-tools\*.ps1') $VibeRoot -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $Assets 'vibe-tools\README.md') (Join-Path $VibeRoot 'README.md') -Force -ErrorAction SilentlyContinue
    $tplDir = Join-Path $VibeRoot 'templates'
    Ensure-Dir $tplDir
    $hookTpl = Join-Path $Assets 'hooks\vibe-coding.json'
    if (Test-Path -LiteralPath $hookTpl) {
        Copy-Item -LiteralPath $hookTpl -Destination (Join-Path $tplDir 'vibe-coding.json') -Force
    }
    Copy-Item (Join-Path $Assets 'bin-shims\*') $GrokBin -Force
    $verSrc = Join-Path $ScriptRoot 'VERSION'
    if (Test-Path -LiteralPath $verSrc) {
        Copy-Item -LiteralPath $verSrc -Destination (Join-Path $GrokHome 'VERSION') -Force
    }
    Copy-Item (Join-Path $Assets 'config\AGENTS.md') (Join-Path $GrokHome 'AGENTS.md') -Force
    Copy-Item (Join-Path $Assets 'config\RTK.md') (Join-Path $GrokHome 'RTK.md') -Force
    Copy-Item (Join-Path $Assets 'config\config-snippet.toml') (Join-Path $TokenRoot 'config-snippet.toml') -Force
    # portable mcp launcher
    $mcpCmd = @"
@echo off
set "SCRIPTS=%USERPROFILE%\.grok\token-saving\venv\Scripts"
set "PATH=%SCRIPTS%;%PATH%"
"%SCRIPTS%\headroom.exe" mcp serve %*
"@
    [System.IO.File]::WriteAllText((Join-Path $TokenRoot 'scripts\headroom-mcp-serve.cmd'), ($mcpCmd -replace "`n", "`r`n"))
}
Write-Ok "Deployed rules, skills, scripts, shims, docs"

$caveman = Join-Path $GrokHome '.caveman-active'
if (-not $DryRun) {
    Set-Content -Path $caveman -Value 'ultra' -Encoding utf8 -NoNewline
}
Write-Ok "caveman flag = ultra"

Write-Step "Core prerequisites (Python, Git, Node, uv)"
$py = Ensure-Python
if (-not $py) {
    Write-Host "Cannot continue without Python." -ForegroundColor Red
    exit 1
}
Write-Ok "Python ready: $($py.Version)"
[void](Ensure-Git)
[void](Ensure-Node)
[void](Ensure-Uv)

Write-Step "User PATH entries"
# Create only user-owned dirs; never mkdir under Program Files
Add-UserPath $GrokBin -CreateIfMissing -AlwaysRecord
Add-UserPath $LocalBin -CreateIfMissing
Add-UserPath $HeadroomBin -CreateIfMissing
Add-UserPath (Join-Path $TokenRoot 'venv\Scripts') -AlwaysRecord
Add-UserPath (Join-Path $VibeRoot 'venv\Scripts') -AlwaysRecord
# Shared bins: add if present so this session can find them; do NOT AlwaysRecord
# (uninstall must never strip pre-existing Git/Node/npm from User PATH).
Add-UserPath (Join-Path $env:APPDATA 'npm')
Add-UserPath 'C:\Program Files\Git\cmd'
Add-UserPath 'C:\Program Files\nodejs'
Add-UserPath 'C:\Program Files\GitHub CLI'

Write-Step "Python venvs (Headroom + vibe scanners)"
$hrReq = if ($UseFrozenReqs -and (Test-Path (Join-Path $Assets 'requirements\headroom-freeze.txt'))) {
    Join-Path $Assets 'requirements\headroom-freeze.txt'
} else {
    Join-Path $Assets 'requirements\headroom.txt'
}
$vibeReq = if ($UseFrozenReqs -and (Test-Path (Join-Path $Assets 'requirements\vibe-tools-freeze.txt'))) {
    Join-Path $Assets 'requirements\vibe-tools-freeze.txt'
} else {
    Join-Path $Assets 'requirements\vibe-tools.txt'
}
$hrOk = New-VenvAndPip -VenvDir (Join-Path $TokenRoot 'venv') -ReqFile $hrReq -Label 'headroom' -PyInfo $py
$vibeOk = New-VenvAndPip -VenvDir (Join-Path $VibeRoot 'venv') -ReqFile $vibeReq -Label 'vibe-tools' -PyInfo $py
# checkov ships a Windows .cmd shim that resolves PATH python (not the venv) and breaks.
# Rewrite venv launcher + ensure ~/.grok/bin/checkov.cmd (from bin-shims) wins on PATH.
if (-not $DryRun -and $vibeOk) {
    $vPy = Join-Path $VibeRoot 'venv\Scripts\python.exe'
    $ckCmd = Join-Path $VibeRoot 'venv\Scripts\checkov.cmd'
    $ckPkg = Join-Path $VibeRoot 'venv\Lib\site-packages\checkov'
    if ((Test-Path -LiteralPath $vPy) -and (Test-Path -LiteralPath $ckPkg)) {
        # Prefer bin-shim style launcher file (avoids python -c quote loss on Windows)
        $shimSrc = Join-Path $Assets 'bin-shims\checkov.cmd'
        if (Test-Path -LiteralPath $shimSrc) {
            Copy-Item -LiteralPath $shimSrc -Destination $ckCmd -Force
            Copy-Item -LiteralPath $shimSrc -Destination (Join-Path $GrokBin 'checkov.cmd') -Force
            Write-Ok "checkov Windows launcher fixed (venv + bin shim)"
        }
    }
}
if (-not $hrOk -or -not $vibeOk) {
    Write-Fail "Critical venv/pip step failed - stack incomplete"
}

# Re-assert PATH now that venvs exist
Add-UserPath (Join-Path $TokenRoot 'venv\Scripts') -CreateIfMissing -AlwaysRecord
Add-UserPath (Join-Path $VibeRoot 'venv\Scripts') -CreateIfMissing -AlwaysRecord
Refresh-ProcessPath
$env:PATH = "$(Join-Path $TokenRoot 'venv\Scripts');$(Join-Path $VibeRoot 'venv\Scripts');$GrokBin;$env:PATH"

Write-Step "RTK (Rust Token Killer)"
$ensureRtk = Join-Path $TokenRoot 'scripts\ensure-rtk.ps1'
if (Test-Path -LiteralPath $ensureRtk) {
    if ($DryRun) {
        Write-Info "DRY ensure-rtk"
    } else {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $ensureRtk
            if ((Test-Path (Join-Path $GrokBin 'rtk.exe')) -or (Test-CommandExists 'rtk')) {
                Write-Ok "rtk ready"
            } else {
                Write-Warn2 "ensure-rtk ran but rtk.exe not found"
            }
        } catch {
            Write-Warn2 "ensure-rtk: $_"
        } finally {
            $ErrorActionPreference = $prev
        }
    }
} else {
    Write-Fail "ensure-rtk.ps1 missing after deploy"
}

Write-Step "Winget CLI tools"
if ($SkipWinget) {
    Write-Info "SkipWinget set - skipping optional scanners"
} else {
    $wingetPkgs = @(
        @{ Id = 'BurntSushi.ripgrep.MSVC'; Label = 'ripgrep' },
        @{ Id = 'sharkdp.fd'; Label = 'fd' },
        @{ Id = 'sharkdp.bat'; Label = 'bat' },
        @{ Id = 'AquaSecurity.Trivy'; Label = 'trivy' },
        @{ Id = 'Gitleaks.Gitleaks'; Label = 'gitleaks' },
        @{ Id = 'BiomeJS.Biome'; Label = 'biome' },
        @{ Id = 'koalaman.shellcheck'; Label = 'shellcheck' },
        @{ Id = 'hadolint.hadolint'; Label = 'hadolint' },
        @{ Id = 'GitHub.cli'; Label = 'gh' }
    )
    foreach ($p in $wingetPkgs) {
        [void](Invoke-WingetInstall -Id $p.Id -Label $p.Label)
    }
    Refresh-ProcessPath
}

Write-Step "npm global packages"
Install-NpmGlobals

Write-Step "PowerShell modules"
Install-PsModules

Write-Step "Optional binaries (scc, tokei, difft via headroom tools)"
[void](Install-GithubReleaseBinary -DestName 'scc.exe')
[void](Install-GithubReleaseBinary -DestName 'tokei.exe')
# Headroom bundles ast-grep + difft + scc into user cache (structural diff = fewer tokens than raw diffs)
$hrExe = Join-Path $TokenRoot 'venv\Scripts\headroom.exe'
if ((Test-Path -LiteralPath $hrExe) -and -not $DryRun) {
    Write-Info "headroom tools install (ast-grep, difft, scc)"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $hrExe tools install 2>&1 | ForEach-Object { Write-Info "$_" }
        Write-Ok "headroom tools install attempted"
    } catch {
        Write-Warn2 "headroom tools install: $_"
    } finally {
        $ErrorActionPreference = $prev
    }
} elseif ($DryRun) {
    Write-Info "DRY headroom tools install"
}

# jq - compact JSON for pipelines (big savings on API/CLI JSON dumps)
if (-not $SkipWinget) {
    [void](Invoke-WingetInstall -Id 'jqlang.jq' -Label 'jq')
}

Write-Step "Serena MCP"
Install-Serena

if (-not $hrOk) {
    Write-Fail "Headroom venv failed - skipping config model default merge (would point at missing proxy stack)"
} else {
    Write-Step "Merge ~/.grok/config.toml"
    Merge-GrokConfig
}

Write-Step "Grok session hooks"
Install-HooksJson
# Re-write serena hooks if serena appeared after first hooks write
if (-not $DryRun -and (Test-Path (Join-Path $LocalBin 'serena-hooks.exe'))) {
    Install-HooksJson
}

Write-Step "Git quality gates (pre-commit + pre-push + AI review) - ALWAYS when .git present"
$installHooks = Join-Path $VibeRoot 'scripts\install-vibe-hooks.ps1'
$here = (Get-Location).Path
if ($SkipRepoHooks) {
    Write-Warn2 "SkipRepoHooks set - quality gates NOT installed in this repo (not recommended)"
} elseif ((Test-Path (Join-Path $here '.git')) -and (Test-Path -LiteralPath $installHooks)) {
    Write-Info "Installing vibe git hooks (scans + LLM review) into $here"
    if (-not $DryRun) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $installHooks -RepoPath $here
            # Re-assert max-savings session hooks (install-vibe-hooks may rewrite vibe-coding.json only)
            Install-HooksJson
            $script:Manifest.repoHooksPath = $here
            Write-Ok "Repo git hooks + session hooks installed (max quality + max savings)"
        } catch {
            Write-Warn2 "Repo hooks: $_"
        } finally {
            $ErrorActionPreference = $prev
        }
    }
} else {
    Write-Info "No .git in cwd - global session hooks still installed. Per-repo: install-vibe-hooks.ps1 ."
}

Write-Step "Write uninstall manifest"
Save-Manifest

$healthy = $true
if (-not $DryRun) {
    $healthy = Test-StackHealth
}
if (-not $DryRun -and $hrOk) {
    Write-Step "Headroom proxy + keeper"
    $startPs1 = Join-Path $TokenRoot 'scripts\start-grok.ps1'
    if (Test-Path -LiteralPath $startPs1) {
        try {
            $proxyCode = Invoke-StartGrokChild -ScriptPath $startPs1 -GrokArgs @('-ProxyOnly', '-Quiet')
            if ($proxyCode -eq 0) {
                Write-Ok "Headroom chat proxy :8787 + keeper started"
            } else {
                Write-Warn2 ("proxy/keeper start exit {0}" -f $proxyCode)
            }
            $gateCode = Invoke-StartGrokChild -ScriptPath $startPs1 -GrokArgs @('-ProxyOnly', '-Quiet', '-Port', '8788', '-NoLogonKeeper')
            if ($gateCode -eq 0) {
                Write-Ok "Headroom gate proxy :8788 (grok-gate, no logon keeper) started"
            } else {
                Write-Warn2 ("gate proxy :8788 start exit {0}" -f $gateCode)
            }
        } catch {
            Write-Warn2 "proxy/keeper start: $_"
        }
    }
}

if (-not $DryRun -and (Test-Path (Join-Path $TokenRoot 'scripts\doctor.ps1'))) {
    Write-Step "Doctor"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & (Join-Path $TokenRoot 'scripts\doctor.ps1') } catch { Write-Warn2 "doctor: $_" }
    finally { $ErrorActionPreference = $prev }
}

Write-Step "Summary"
Write-Host ""
Write-Host "Succeeded ($($script:Ok.Count)):" -ForegroundColor Green
$script:Ok | Select-Object -Last 40 | ForEach-Object { Write-Host "  - $_" }
if ($script:Warned.Count) {
    Write-Host "Warnings ($($script:Warned.Count)):" -ForegroundColor Yellow
    $script:Warned | ForEach-Object { Write-Host "  - $_" }
}
if ($script:Failed.Count) {
    Write-Host "Failures ($($script:Failed.Count)):" -ForegroundColor Red
    $script:Failed | ForEach-Object { Write-Host "  - $_" }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host " If Grok is ALREADY open: reload hooks once (or restart Grok)" -ForegroundColor Yellow
Write-Host "   In Grok TUI:  /hooks   then press  r" -ForegroundColor Yellow
Write-Host " New Grok sessions load hooks from disk automatically." -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open a NEW terminal (PATH refresh)"
Write-Host "  2. start-grok -Status"
Write-Host "  3. start-grok   (chat Headroom :8787; grok-4.6). Vanilla: start-grok -m grok-4.6-direct"
Write-Host "     Gates: grok-gate on :8788 (installer starts it; no logon keeper)."
Write-Host "     Manual: start-grok -ProxyOnly -Port 8788 -NoLogonKeeper"
Write-Host "     Do not restart :8788 because /readyz is slow - TCP listen = up."
Write-Host "  4. If Grok was already running: /hooks then r  (or restart Grok)"
Write-Host "  5. Other projects:  & `"`$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1`" ."
Write-Host "  6. Uninstall later:  .\Uninstall-GrokVibeStack.ps1"
Write-Host ""
Write-Host "Quality gates: profiles fast|standard|strict; fail-closed AI; reports in ~/.grok/vibe-tools/reports/" -ForegroundColor DarkGray
Write-Host "  commit=standard (3 reviewers+fix)  push=fast (1 reviewer)  doctor shows latest report" -ForegroundColor DarkGray
Write-Host "Smoke (no AI): & `"$VibeRoot\scripts\Invoke-VibeStackSmoke.ps1`" -WithHooksInstall" -ForegroundColor DarkGray
Write-Host "Permissions: stack does NOT set always-approve. Check /settings if tools auto-run." -ForegroundColor DarkGray
Write-Host ""

# Warn if user already has always-approve (not set by this installer)
if (-not $DryRun) {
    $cfgCheck = Join-Path $GrokHome 'config.toml'
    if (Test-Path -LiteralPath $cfgCheck) {
        $cfgTxt = Get-Content -LiteralPath $cfgCheck -Raw -ErrorAction SilentlyContinue
        if ($cfgTxt -match '(?m)^\s*permission_mode\s*=\s*"always-approve"') {
            Write-Warn2 "config.toml has permission_mode=always-approve (tools auto-run). Not set by this stack; change in /settings if undesired."
        }
    }
}

$criticalFail = ($script:Failed.Count -gt 0) -or (-not $hrOk) -or (-not $vibeOk) -or (-not $healthy -and -not $DryRun)
if ($criticalFail) { exit 1 }
exit 0

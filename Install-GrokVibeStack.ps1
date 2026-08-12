#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap the full Grok vibe-coding + token-saving stack on a machine that only has Grok Build CLI.

.DESCRIPTION
  Idempotent. Requires grok.exe. Installs everything else needed for the donor-machine stack:

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
    config.toml managed block (Headroom + Serena MCP, grok-via-headroom)
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
$script:Warned = New-Object System.Collections.Generic.List[string]
$script:Ok = New-Object System.Collections.Generic.List[string]
$script:Manifest = [ordered]@{
    version              = 1
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
        'vibe-review.ps1', 'install-vibe-hooks.ps1', 'rtk.exe', 'scc.exe', 'tokei.exe'
    )
    hookFiles            = @('token-saving.json', 'vibe-coding.json', 'serena-hooks.json')
    # Always max quality gates + max token savings on fresh machines
    maxSavingsProfile    = $true
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
    # Always record intended stack PATH entries for uninstall (even if pre-existing)
    if ($AlwaysRecord -or -not $has) {
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
        Write-Info "DRY pip install -r $ReqFile"
        return $true
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $pyExe -m pip install --upgrade pip wheel setuptools 2>&1
        Write-Info "pip install -r $ReqFile ($Label) - this can take several minutes"
        $pipOut = & $pyExe -m pip install -r $ReqFile 2>&1
        $code = $LASTEXITCODE
        $pipOut | ForEach-Object {
            $line = "$_"
            if ($line -match '(?i)(ERROR:(?! pip.s dependency)|No matching distribution|Could not find|failed building)') {
                Write-Host "    $line" -ForegroundColor DarkYellow
            }
        }
        if ($code -ne 0) {
            Write-Fail "pip install $Label (exit $code)"
            return $false
        }
        Write-Ok "pip $Label"
        return $true
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Remove-TomlSections {
    param([string]$Raw, [string[]]$SectionNames)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([string[]]$SectionNames), ([StringComparer]::OrdinalIgnoreCase)
    $lines = $Raw -split "`r?`n", -1
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $skip = $set.Contains($Matches[1].Trim())
        }
        if (-not $skip) { [void]$out.Add($line) }
    }
    return ($out -join "`n")
}

function Merge-GrokConfig {
    $cfgPath = Join-Path $GrokHome 'config.toml'
    $snippetPath = Join-Path $Assets 'config\config-snippet.toml'
    if (-not (Test-Path -LiteralPath $snippetPath)) {
        Write-Fail "missing config snippet"
        return
    }

    $hr = Join-Path $TokenRoot 'scripts\headroom-mcp-serve.cmd'
    $serenaExe = Join-Path $LocalBin 'serena.exe'
    if (-not (Test-Path -LiteralPath $serenaExe)) {
        $sc = Get-Command serena -ErrorAction SilentlyContinue
        if ($sc) { $serenaExe = $sc.Source }
    }

    $snippet = Get-Content -LiteralPath $snippetPath -Raw
    $snippet = $snippet.Replace('command = "HEADROOM_MCP_CMD"', "command = '$hr'")
    $snippet = $snippet.Replace('command = "SERENA_EXE"', "command = '$serenaExe'")
    $snippet = $snippet.TrimEnd() + "`n"

    $begin = '# --- grok-vibe-stack managed block (begin) ---'
    $end = '# --- grok-vibe-stack managed block (end) ---'
    $owned = @(
        'session', 'features', 'mcp',
        'mcp_servers.headroom', 'mcp_servers.serena',
        'model.grok-via-headroom', 'models'
    )

    if ($DryRun) { Write-Info "DRY merge config.toml"; return }

    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Ensure-Dir $GrokHome
        $seed = "[cli]`ninstaller = `"internal`"`n`n" + $snippet
        [System.IO.File]::WriteAllText($cfgPath, $seed)
        Write-Ok "Created config.toml"
        [void]$script:Manifest.stackFiles.Add($cfgPath)
        return
    }

    $bak = "$cfgPath.vibe-bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $cfgPath -Destination $bak -Force
    $script:Manifest.configBackup = $bak
    Write-Info "Config backup: $bak"

    $raw = Get-Content -LiteralPath $cfgPath -Raw
    if ($raw.Contains($begin)) {
        $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
        $newRaw = [regex]::Replace($raw, $pattern, $snippet.TrimEnd())
    } else {
        $stripped = Remove-TomlSections -Raw $raw -SectionNames $owned
        $newRaw = $stripped.TrimEnd() + "`n`n" + $snippet
    }
    if (-not $newRaw.EndsWith("`n")) { $newRaw += "`n" }
    [System.IO.File]::WriteAllText($cfgPath, $newRaw)
    Write-Ok "Merged vibe stack into config.toml"
}

function Write-Utf8NoBomFile([string]$Path, [string]$Content) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Install-HooksJson {
    $hooksDir = Join-Path $GrokHome 'hooks'
    Ensure-Dir $hooksDir

    # Absolute -File paths: required so PreToolUse stdin reaches the script (unlike -Command).
    # Regenerated per machine — do not copy donor usernames into the repo templates blindly.
    $sessionStart = Join-Path $TokenRoot 'scripts\session-start.ps1'
    $postShell = Join-Path $TokenRoot 'scripts\post-shell.ps1'
    $onEdit = Join-Path $VibeRoot 'scripts\run-vibe-on-edit.ps1'
    $rtkEnforce = Join-Path $TokenRoot 'scripts\run-rtk-enforce.ps1'

    $tokenSaving = @{
        hooks = @{
            SessionStart = @(@{
                    hooks = @(@{
                            type    = 'command'
                            command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$sessionStart`""
                            timeout = 15
                        })
                })
            PreToolUse   = @(@{
                    matcher = 'run_terminal_command|Bash'
                    hooks   = @(@{
                            type    = 'command'
                            command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$rtkEnforce`""
                            timeout = 5
                        })
                })
            PostToolUse  = @(@{
                    matcher = 'run_terminal_command|Bash'
                    hooks   = @(@{
                            type    = 'command'
                            command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$postShell`""
                            timeout = 10
                        })
                })
        }
    }

    $vibeCoding = @{
        hooks = @{
            PostToolUse = @(@{
                    matcher = 'search_replace|Write|Edit|MultiEdit|write'
                    hooks   = @(@{
                            type    = 'command'
                            command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$onEdit`""
                            timeout = 60
                        })
                })
            Stop        = @(@{
                    hooks = @(@{
                            type    = 'command'
                            command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"Write-Host '[vibe] Turn end - if you edited code, confirm vibe-review / scans ran before done.' -ForegroundColor Cyan`""
                            timeout = 5
                        })
                })
        }
    }

    if ($DryRun) { Write-Info "DRY write hooks"; return }

    Write-Utf8NoBomFile (Join-Path $hooksDir 'token-saving.json') ($tokenSaving | ConvertTo-Json -Depth 12)
    Write-Utf8NoBomFile (Join-Path $hooksDir 'vibe-coding.json') ($vibeCoding | ConvertTo-Json -Depth 12)

    # Serena MCP stays in config.toml. Do NOT install serena-hooks PreToolUse by default:
    # serena-hooks "remind" on every read_file/grep exits silent-allow and Grok UI counts
    # "hooks: N failed" even with a wrapper (host/stdin quirks). Opt-in via Enable-SerenaRemindHooks.ps1.
    $staleSerena = Join-Path $hooksDir 'serena-hooks.json'
    if (Test-Path -LiteralPath $staleSerena) {
        Remove-Item -LiteralPath $staleSerena -Force -ErrorAction SilentlyContinue
        Write-Info "removed serena-hooks.json (remind on read caused false hook failures)"
    }
    Write-Ok "hooks: token-saving (rtk-enforce), vibe-coding (Serena MCP only; no read_file remind hook)"
}

function Install-GithubReleaseBinary {
    param(
        [string]$Repo,
        [string]$AssetPattern,
        [string]$DestName
    )
    Ensure-Dir $GrokBin
    $dest = Join-Path $GrokBin $DestName
    if (Test-Path -LiteralPath $dest) {
        Write-Info "$DestName already present"
        return $true
    }
    if ($DryRun) { Write-Info "DRY download $DestName from $Repo"; return $true }
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{
            'User-Agent' = 'Install-GrokVibeStack'
        }
        $asset = $rel.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
        if (-not $asset) {
            Write-Warn2 "No release asset for $DestName ($Repo)"
            return $false
        }
        $tmp = Join-Path $env:TEMP ("gvibe-" + [guid]::NewGuid().ToString('n'))
        Ensure-Dir $tmp
        $dl = Join-Path $tmp $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dl -UseBasicParsing
        if ($asset.name -match '\.zip$') {
            Expand-Archive -Path $dl -DestinationPath $tmp -Force
            $exe = Get-ChildItem -Path $tmp -Recurse -Filter $DestName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $exe) {
                $exe = Get-ChildItem -Path $tmp -Recurse -Filter *.exe -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ieq $DestName -or $_.BaseName -ieq ([IO.Path]::GetFileNameWithoutExtension($DestName)) } |
                    Select-Object -First 1
            }
            if ($exe) { Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force }
        } elseif ($asset.name -match '\.exe$') {
            Copy-Item -LiteralPath $dl -Destination $dest -Force
        }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dest) {
            Write-Ok "Installed $DestName"
            return $true
        }
        Write-Warn2 "Failed to place $DestName"
        return $false
    } catch {
        Write-Warn2 "Download $DestName failed: $_"
        return $false
    }
}

function Install-Serena {
    if ($SkipSerena) { Write-Info "Skip Serena"; return }
    $existing = Join-Path $LocalBin 'serena.exe'
    if (Test-Path -LiteralPath $existing) {
        Write-Ok "Serena already at $existing"
        return
    }
    $cmd = Get-Command serena -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Ok "Serena on PATH: $($cmd.Source)"
        return
    }

    Ensure-Dir $LocalBin
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (Test-CommandExists 'uv') {
            Write-Info "uv tool install serena (git)"
            if (-not $DryRun) {
                $had = Test-Path -LiteralPath $existing
                & uv tool install --force git+https://github.com/oraios/serena 2>&1 | ForEach-Object { Write-Info "$_" }
                Refresh-ProcessPath
                if ((Test-Path -LiteralPath $existing) -or (Test-CommandExists 'serena')) {
                    if (-not $had) { $script:Manifest.serenaInstalledByUs = $true }
                    Write-Ok "Serena via uv"
                    return
                }
            } else {
                Write-Info "DRY uv tool install serena"
                return
            }
        }

        $py = Find-Python310Plus
        if ($py -and -not $DryRun) {
            Write-Info "pip install serena --user"
            & $py.Exe @($py.Args + @('-m', 'pip', 'install', '--user', 'git+https://github.com/oraios/serena')) 2>&1 | Out-Null
            Refresh-ProcessPath
            if (Test-CommandExists 'serena') {
                $script:Manifest.serenaInstalledByUs = $true
                Write-Ok "Serena via pip --user"
                return
            }
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    Write-Warn2 "Serena not installed. Later: uv tool install git+https://github.com/oraios/serena"
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
    if (Test-CommandExists 'serena' -or (Test-Path (Join-Path $LocalBin 'serena.exe'))) {
        Write-Ok "check serena"
    } else {
        Write-Warn2 "check serena missing"
    }
    return ($bad -eq 0)
}

# ===================== MAIN =====================
Write-Host ""
Write-Host "+================================================================+" -ForegroundColor Magenta
Write-Host "|  Install-GrokVibeStack                                         |" -ForegroundColor Magenta
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
    Copy-Item (Join-Path $Assets 'bin-shims\*') $GrokBin -Force
    Copy-Item (Join-Path $Assets 'config\AGENTS.md') (Join-Path $GrokHome 'AGENTS.md') -Force
    Copy-Item (Join-Path $Assets 'config\RTK.md') (Join-Path $GrokHome 'RTK.md') -Force
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
Add-UserPath $LocalBin -CreateIfMissing -AlwaysRecord
Add-UserPath $HeadroomBin -CreateIfMissing -AlwaysRecord
Add-UserPath (Join-Path $TokenRoot 'venv\Scripts') -AlwaysRecord
Add-UserPath (Join-Path $VibeRoot 'venv\Scripts') -AlwaysRecord
Add-UserPath (Join-Path $env:APPDATA 'npm') -AlwaysRecord
# System install locations: add only if already present (winget/Git put them there)
Add-UserPath 'C:\Program Files\Git\cmd' -AlwaysRecord
Add-UserPath 'C:\Program Files\nodejs' -AlwaysRecord
Add-UserPath 'C:\Program Files\GitHub CLI' -AlwaysRecord

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
            if (Test-Path (Join-Path $GrokBin 'rtk.exe') -or (Test-CommandExists 'rtk')) {
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
[void](Install-GithubReleaseBinary -Repo 'boyter/scc' -AssetPattern '(?i)(windows|win64|x86_64.*windows).*\.zip$' -DestName 'scc.exe')
[void](Install-GithubReleaseBinary -Repo 'XAMPPRocky/tokei' -AssetPattern '(?i)(x86_64-pc-windows|windows).*\.(zip|exe)$' -DestName 'tokei.exe')
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
Write-Host " REQUIRED: reload Grok hooks or RTK/on-edit gates stay OFF" -ForegroundColor Yellow
Write-Host "   In Grok TUI:  /hooks   then press  r" -ForegroundColor Yellow
Write-Host "   Or restart the Grok session after install." -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open a NEW terminal (PATH refresh)"
Write-Host "  2. start-grok -Status"
Write-Host "  3. start-grok   (starts Headroom proxy; default model needs it)"
Write-Host "  4. In Grok: /hooks then press r   <-- do not skip"
Write-Host "  5. Other repos:  & `"`$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1`" ."
Write-Host "  6. Uninstall later:  .\Uninstall-GrokVibeStack.ps1"
Write-Host ""
Write-Host "Quality gates: profiles fast|standard|strict; fail-closed AI; reports in ~/.grok/vibe-tools/reports/" -ForegroundColor DarkGray
Write-Host "  commit=standard (3 reviewers+fix)  push=fast (1 reviewer)  doctor shows latest report" -ForegroundColor DarkGray
Write-Host "Smoke (no AI): & `"$VibeRoot\scripts\Invoke-VibeStackSmoke.ps1`" -WithHooksInstall" -ForegroundColor DarkGray
Write-Host "Permissions: stack does NOT set always-approve. Check /settings if tools auto-run." -ForegroundColor DarkGray
Write-Host ""

# Warn if donor/user already has always-approve (not set by this installer)
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

#Requires -Version 5.1
<#
.SYNOPSIS
  Shared ~/.grok/config.toml helpers for the vibe stack.

.DESCRIPTION
  Grok rewrites config.toml and drops comments, including the managed-block
  markers. Reinstall then used to append the snippet on top of the same tables
  (duplicate-key TOML). start-grok / installer / doctor all use this file.
#>

function Get-VibeOwnedTomlSections {
    return @(
        'session', 'features', 'mcp',
        'mcp_servers.headroom', 'mcp_servers.serena',
        'model."grok-4.6"', 'model.grok-4.6', 'model.grok-via-headroom',
        'model."grok-4.6-direct"', 'model.grok-4.6-direct', 'models'
    )
}

function Get-VibeManagedBlockMarkers {
    return @{
        Begin = '# --- grok-vibe-stack managed block (begin) ---'
        End   = '# --- grok-vibe-stack managed block (end) ---'
    }
}

function ConvertFrom-TomlTableLine {
    param([string]$Line)
    if ($null -eq $Line) { return $null }
    if ($Line -match '^\s*\[\[([^\]]+)\]\]\s*(?:#.*)?$') {
        return @{ Kind = 'array'; Name = $Matches[1].Trim() }
    }
    if ($Line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
        return @{ Kind = 'table'; Name = $Matches[1].Trim() }
    }
    return $null
}

function Remove-TomlSections {
    param(
        [string]$Raw,
        [string[]]$SectionNames
    )
    if ([string]::IsNullOrEmpty($Raw)) { return '' }
    $names = @($SectionNames | ForEach-Object { [string]$_ })
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $names) {
        if ($n) { [void]$set.Add($n) }
    }
    $lines = $Raw -split "`r?`n", -1
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        $hdr = ConvertFrom-TomlTableLine $line
        if ($hdr) {
            $skip = $set.Contains([string]$hdr.Name)
        }
        if (-not $skip) { [void]$out.Add($line) }
    }
    return ($out -join "`n")
}

function Get-TomlDuplicateTables {
    param([string]$Raw)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $dups = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Raw -split "`r?`n", -1)) {
        $hdr = ConvertFrom-TomlTableLine $line
        if (-not $hdr -or $hdr.Kind -ne 'table') { continue }
        $name = [string]$hdr.Name
        if (-not $seen.Add($name)) {
            if (-not $dups.Contains($name)) { [void]$dups.Add($name) }
        }
    }
    return @($dups)
}

function Repair-TomlKeepFirstTables {
    param([string]$Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return '' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $lines = $Raw -split "`r?`n", -1
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        $hdr = ConvertFrom-TomlTableLine $line
        if ($hdr) {
            if ($hdr.Kind -eq 'table') {
                $skip = -not $seen.Add([string]$hdr.Name)
            } else {
                $skip = $false
            }
        }
        if (-not $skip) { [void]$out.Add($line) }
    }
    return ($out -join "`n")
}

function Repair-TomlKeepLastTables {
    param(
        [string]$Raw,
        [string[]]$OnlyNames = @()
    )
    if ([string]::IsNullOrEmpty($Raw)) { return '' }
    $filter = $null
    if ($OnlyNames -and @($OnlyNames).Count -gt 0) {
        $filter = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $OnlyNames) {
            if ($n) { [void]$filter.Add([string]$n) }
        }
    }
    $lines = $Raw -split "`r?`n", -1
    $lastIdx = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $hdr = ConvertFrom-TomlTableLine $lines[$i]
        if (-not $hdr -or $hdr.Kind -ne 'table') { continue }
        $name = [string]$hdr.Name
        if ($filter -and -not $filter.Contains($name)) { continue }
        $lastIdx[$name] = $i
    }
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $hdr = ConvertFrom-TomlTableLine $lines[$i]
        if ($hdr) {
            if ($hdr.Kind -eq 'table') {
                $name = [string]$hdr.Name
                $skip = $lastIdx.ContainsKey($name) -and ($i -ne $lastIdx[$name])
            } else {
                $skip = $false
            }
        }
        if (-not $skip) { [void]$out.Add($lines[$i]) }
    }
    return ($out -join "`n")
}

function Remove-VibeManagedTomlBlock {
    param([string]$Raw)
    $m = Get-VibeManagedBlockMarkers
    if ([string]::IsNullOrEmpty($Raw) -or -not $Raw.Contains($m.Begin)) { return $Raw }
    $pattern = '(?s)' + [regex]::Escape($m.Begin) + '.*?' + [regex]::Escape($m.End)
    return [regex]::Replace($Raw, $pattern, '').TrimEnd()
}

function Get-VibeConfigSnippetPath {
    param(
        [string]$TokenRoot = $(Join-Path $env:USERPROFILE '.grok\token-saving'),
        [string]$AssetsRoot = ''
    )
    $cands = @(
        (Join-Path $TokenRoot 'config-snippet.toml'),
        (Join-Path $TokenRoot 'scripts\config-snippet.toml')
    )
    if ($AssetsRoot) {
        $cands += (Join-Path $AssetsRoot 'config\config-snippet.toml')
    }
    foreach ($p in $cands) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-VibeManagedSnippet {
    param(
        [string]$SnippetPath,
        [string]$HeadroomCmd,
        [string]$SerenaExe,
        [bool]$SerenaEnabled = $true
    )
    if (-not $SnippetPath -or -not (Test-Path -LiteralPath $SnippetPath)) {
        throw "Missing vibe config snippet: $SnippetPath"
    }
    $snippet = Read-Utf8NoBomFile -Path $SnippetPath
    if ($HeadroomCmd) {
        $snippet = $snippet.Replace('command = "HEADROOM_MCP_CMD"', "command = '$HeadroomCmd'")
    }
    if ($SerenaExe) {
        $snippet = $snippet.Replace('command = "SERENA_EXE"', "command = '$SerenaExe'")
    }
    if (-not $SerenaEnabled) {
        $snippet = [regex]::Replace(
            $snippet,
            '(?s)(\[mcp_servers\.serena\].*?enabled = )true',
            '${1}false',
            1
        )
    }
    return ($snippet.TrimEnd() + "`n")
}

function Merge-VibeToml {
    param(
        [string]$Raw,
        [string]$Snippet
    )
    $body = Remove-VibeManagedTomlBlock -Raw $(if ($null -eq $Raw) { '' } else { $Raw })
    $body = Remove-TomlSections -Raw $body -SectionNames (Get-VibeOwnedTomlSections)
    $merged = $body.TrimEnd()
    if ($merged) { $merged += "`n`n" }
    $merged += $Snippet.TrimEnd() + "`n"
    # Always keep-last. Grok rewrite drops managed-block comments; a later
    # append then has two copies of the same tables. Strip-by-name can miss
    # a renamed table; last (snippet) must win.
    $merged = Repair-TomlKeepLastTables -Raw $merged
    return ($merged.TrimEnd() + "`n")
}

function Get-VibeConfigBackupDir {
    $d = Join-Path $env:USERPROFILE '.grok\relocations'
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    return $d
}

function Backup-VibeConfigFile {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$BackupSuffix = ''
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $suffix = if ($BackupSuffix) { ($BackupSuffix -replace '[^\w.\-]+', '-').Trim('-') } else { '' }
    if (-not $suffix) { $suffix = Get-Date -Format 'yyyyMMdd-HHmmss' }
    $dest = Join-Path (Get-VibeConfigBackupDir) ('config-{0}.toml' -f $suffix)
    Copy-Item -LiteralPath $ConfigPath -Destination $dest -Force
    return $dest
}

function Restore-VibeConfigBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$BackupPath
    )
    if (-not $BackupPath -or -not (Test-Path -LiteralPath $BackupPath)) { return $false }
    Copy-Item -LiteralPath $BackupPath -Destination $ConfigPath -Force
    return $true
}

function Confirm-VibeConfigWrite {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$BackupPath
    )
    $onDisk = Read-Utf8NoBomFile -Path $ConfigPath
    $recheck = Test-VibeToml -Raw $onDisk
    if ($recheck.Ok) { return $recheck }
    $restored = Restore-VibeConfigBackup -ConfigPath $ConfigPath -BackupPath $BackupPath
    $note = if ($restored) { '; live file restored from backup' } else { '; no backup to restore' }
    throw ('config.toml re-read after write is invalid: {0}{1}' -f ($recheck.Errors -join '; '), $note)
}

function Move-VibeConfigSidecar {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $leaf = Split-Path -Leaf $Path
    $dest = Join-Path (Get-VibeConfigBackupDir) ('sidecar-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $leaf)
    Move-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

function Resolve-VibeConfigMergeSource {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    $dir = Split-Path -Parent $ConfigPath
    $live = ''
    if (Test-Path -LiteralPath $ConfigPath) {
        $live = Read-Utf8NoBomFile -Path $ConfigPath
    }
    $sidecar = Join-Path $dir 'config.toml.bak'
    $sidecarRaw = $null
    if (Test-Path -LiteralPath $sidecar) {
        $sidecarRaw = Read-Utf8NoBomFile -Path $sidecar
    }
    $liveHr = $false
    if ($live) {
        $liveHr = [bool]((Test-VibeToml -Raw $live).HasHeadroomOverride)
    }
    # Prefer bak only when live lacks Headroom and bak has the same stack
    # signal (quoted [model."grok-4.6"] + 8787). Dups or a bare 8787 string
    # are not enough — that would promote extra same-user tables.
    $bakHr = $false
    if ($sidecarRaw) {
        $bakHr = [bool]((Test-VibeToml -Raw $sidecarRaw).HasHeadroomOverride)
    }
    if ($bakHr -and -not $liveHr) {
        return @{
            Raw         = $sidecarRaw
            SourcePath  = $sidecar
            SidecarPath = $sidecar
        }
    }
    return @{
        Raw         = $live
        SourcePath  = $ConfigPath
        SidecarPath = $null
    }
}

function Test-VibeToml {
    param([string]$Raw)
    $dups = @(Get-TomlDuplicateTables -Raw $Raw)
    $hasHr = [bool]($Raw -match '(?m)^\s*\[model\."grok-4\.6"\]\s*$' -and $Raw -match '127\.0\.0\.1:8787')
    $errors = New-Object System.Collections.Generic.List[string]
    if ($dups.Count -gt 0) {
        [void]$errors.Add(('duplicate TOML tables: {0}' -f ($dups -join ', ')))
    }
    if (-not $hasHr) {
        [void]$errors.Add('missing quoted [model."grok-4.6"] Headroom override (127.0.0.1:8787)')
    }
    return @{
        Ok                   = ($errors.Count -eq 0)
        Duplicates           = $dups
        HasHeadroomOverride  = $hasHr
        Errors               = @($errors)
    }
}

function Get-VibeUtf8NoBom {
    return (New-Object System.Text.UTF8Encoding $false)
}

function Read-Utf8NoBomFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, (Get-VibeUtf8NoBom))
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $utf8 = Get-VibeUtf8NoBom
    if (-not $Content.EndsWith("`n")) { $Content += "`n" }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Repair-GrokConfigFile {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$SnippetPath,
        [string]$HeadroomCmd,
        [string]$SerenaExe,
        [bool]$SerenaEnabled = $true,
        [string]$BackupSuffix = ''
    )
    $src = Resolve-VibeConfigMergeSource -ConfigPath $ConfigPath
    $snippet = Get-VibeManagedSnippet -SnippetPath $SnippetPath -HeadroomCmd $HeadroomCmd -SerenaExe $SerenaExe -SerenaEnabled $SerenaEnabled
    $merged = Merge-VibeToml -Raw $src.Raw -Snippet $snippet
    $check = Test-VibeToml -Raw $merged
    if (-not $check.Ok) {
        throw ('config.toml merge still invalid: {0}' -f ($check.Errors -join '; '))
    }
    $backup = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        $backup = Backup-VibeConfigFile -ConfigPath $ConfigPath -BackupSuffix $BackupSuffix
    }
    $dir = Split-Path -Parent $ConfigPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Write-Utf8NoBomFile -Path $ConfigPath -Content $merged
    $recheck = Confirm-VibeConfigWrite -ConfigPath $ConfigPath -BackupPath $backup
    $quarantined = $null
    if ($src.SidecarPath) {
        $quarantined = Move-VibeConfigSidecar -Path $src.SidecarPath
    }
    return @{
        Ok           = $true
        Duplicates   = @()
        Errors       = @()
        BackupPath   = $backup
        SourcePath   = $src.SourcePath
        Quarantined  = $quarantined
        HasHeadroomOverride = $recheck.HasHeadroomOverride
    }
}

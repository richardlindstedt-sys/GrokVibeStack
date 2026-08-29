#Requires -Version 5.1
<#
.SYNOPSIS
  Switch Grok MCP between coding (lean) and personal (mail/calendar) profiles.

.DESCRIPTION
  Coding: keep Serena + Headroom enabled; disable mail/calendar/drive/tasks
  via disabled_mcp_servers and disabled_mcp_tools.__managed_gateway_connectors.
  Personal: remove those names from the deny lists (other user denies stay).

  Does not rewrite the vibe managed block. Grok TUI /mcps still needed for
  some gateway connectors (CLI disable is not full parity). Restart Grok
  after a switch if a session is already open.

.PARAMETER Profile
  coding | personal | status

.PARAMETER ConfigPath
  Defaults to ~/.grok/config.toml

.PARAMETER StatePath
  Defaults to ~/.grok/token-saving/state/mcp-profile.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('coding', 'personal', 'status')]
    [string]$Profile,

    [string]$ConfigPath = '',
    [string]$StatePath = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$GrokHome = Join-Path $env:USERPROFILE '.grok'
if (-not $ConfigPath) { $ConfigPath = Join-Path $GrokHome 'config.toml' }
if (-not $StatePath) { $StatePath = Join-Path $GrokHome 'token-saving\state\mcp-profile.json' }

$tomlHelper = Join-Path $PSScriptRoot 'GrokToml.ps1'
if (-not (Test-Path -LiteralPath $tomlHelper)) {
    $tomlHelper = Join-Path $GrokHome 'token-saving\scripts\GrokToml.ps1'
}
if (-not (Test-Path -LiteralPath $tomlHelper)) {
    throw 'GrokToml.ps1 missing (re-run Install-GrokVibeStack.ps1)'
}
. $tomlHelper

# Names seen as always-on connectors in coding sessions. Keep this list small.
$script:PersonalMcpNames = @(
    'gmail',
    'google_calendar',
    'google_drive',
    'outlook',
    'outlook_calendar',
    'tasks'
)
$script:CodingKeepServers = @('headroom', 'serena')

function Get-PersonalNameSet {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $script:PersonalMcpNames) { [void]$set.Add($n) }
    return $set
}

function Format-TomlStringArray([string[]]$Items) {
    $q = New-Object System.Collections.Generic.List[string]
    foreach ($i in @($Items)) {
        if ([string]::IsNullOrWhiteSpace($i)) { continue }
        [void]$q.Add(('"{0}"' -f ($i -replace '"', '')))
    }
    return ('[{0}]' -f ($q -join ', '))
}

function Get-QuotedStrings([string]$Text) {
    $out = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    foreach ($m in [regex]::Matches($Text, '"([^"]+)"')) {
        [void]$out.Add([string]$m.Groups[1].Value)
    }
    return @($out)
}

function Read-McpProfileState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-McpProfileState([string]$Path, [string]$Name, [string[]]$Disabled) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $obj = [ordered]@{
        profile          = $Name
        updatedUtc       = [DateTime]::UtcNow.ToString('o')
        disabledPersonal = @($Disabled)
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, ($obj | ConvertTo-Json -Depth 4), $utf8)
}

function Get-PreambleSection($Doc) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Doc.Preamble) {
        foreach ($l in $Doc.Preamble) { [void]$lines.Add([string]$l) }
    }
    return @{ Kind = 'table'; Name = ''; HeaderLine = ''; Lines = $lines }
}

function Set-SectionBareLine($Section, [string]$Bare, [string]$Line) {
    $Section = Remove-TomlKeysFromSection -Section $Section -BareKeys @($Bare) -Heads @()
    $dst = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Section.Lines) {
        foreach ($l in $Section.Lines) { [void]$dst.Add([string]$l) }
    }
    while ($dst.Count -gt 0 -and [string]::IsNullOrWhiteSpace($dst[$dst.Count - 1])) {
        $dst.RemoveAt($dst.Count - 1)
    }
    [void]$dst.Add($Line)
    $Section.Lines = $dst
    return $Section
}

function Get-SectionAssignmentText($Section, [string]$Bare) {
    if ($null -eq $Section -or $null -eq $Section.Lines) { return '' }
    $arr = [string[]](Convert-VibeToArray $Section.Lines)
    $spans = @(Get-TomlAssignmentSpans -Lines $arr)
    foreach ($sp in $spans) {
        if ([string]$sp.Bare -eq $Bare) {
            $chunk = New-Object System.Collections.Generic.List[string]
            for ($i = [int]$sp.Start; $i -le [int]$sp.End; $i++) { [void]$chunk.Add($arr[$i]) }
            return ($chunk -join "`n")
        }
    }
    return ''
}

function Get-CurrentDisabledServers($PreambleSec) {
    $txt = Get-SectionAssignmentText -Section $PreambleSec -Bare 'disabled_mcp_servers'
    return @(Get-QuotedStrings $txt)
}

function Merge-NameLists([string[]]$A, [string[]]$B) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($A + $B)) {
        if ([string]::IsNullOrWhiteSpace($x)) { continue }
        if ($set.Add($x)) { [void]$order.Add($x) }
    }
    return @($order)
}

function Remove-NamesFromList([string[]]$Source, $RemoveSet) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($Source)) {
        if ([string]::IsNullOrWhiteSpace($x)) { continue }
        if ($RemoveSet.Contains($x)) { continue }
        [void]$out.Add($x)
    }
    return @($out)
}

function Set-McpServerEnabledFlag($Doc, [string]$Name, [bool]$Enabled) {
    $secName = 'mcp_servers.' + $Name
    $sec = Find-TomlSection -Doc $Doc -Name $secName -Kind 'table'
    if ($null -eq $sec) { return }
    $val = if ($Enabled) { 'true' } else { 'false' }
    $updated = Set-SectionBareLine -Section $sec -Bare 'enabled' -Line ('enabled = {0}' -f $val)
    $sec.Lines = $updated.Lines
}

function Show-StatusInner {
    $st = Read-McpProfileState $StatePath
    $profileName = 'unknown'
    if ($st -and $st.profile) { $profileName = [string]$st.profile }
    Write-Host ("MCP profile: {0}" -f $profileName)
    if ($st -and $st.updatedUtc) { Write-Host ("  updated:   {0}" -f $st.updatedUtc) }
    if (Test-Path -LiteralPath $ConfigPath) {
        $raw = Read-Utf8NoBomFile -Path $ConfigPath
        $doc = ConvertFrom-VibeTomlDocument -Raw $raw
        $pre = Get-PreambleSection $doc
        $disabled = @(Get-CurrentDisabledServers $pre)
        Write-Host ("  config:    {0}" -f $ConfigPath)
        Write-Host ("  disabled_mcp_servers ({0}): {1}" -f $disabled.Count, ($(if ($disabled.Count) { $disabled -join ', ' } else { '(none)' })))
        $gw = Find-TomlSection -Doc $doc -Name 'disabled_mcp_tools' -Kind 'table'
        $gwTxt = Get-SectionAssignmentText -Section $gw -Bare '__managed_gateway_connectors'
        $gwNames = @(Get-QuotedStrings $gwTxt)
        Write-Host ("  gateway connectors denied ({0}): {1}" -f $gwNames.Count, ($(if ($gwNames.Count) { $gwNames -join ', ' } else { '(none)' })))
    } else {
        Write-Host ("  config:    missing ({0})" -f $ConfigPath)
    }
    Write-Host '  coding keep: serena, headroom'
    Write-Host ('  personal:   ' + ($script:PersonalMcpNames -join ', '))
    Write-Host '  apply:      Enable-GrokCodingMcp.ps1 / Enable-GrokPersonalMcp.ps1'
    Write-Host '  then:       restart Grok if a session is already open (/mcps still needed for some gateway connectors)'
}

if ($Profile -eq 'status') {
    Show-StatusInner
    exit 0
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw ('config.toml not found: {0} (run start-grok or Install-GrokVibeStack.ps1 first)' -f $ConfigPath)
}

$raw = Read-Utf8NoBomFile -Path $ConfigPath
$doc = ConvertFrom-VibeTomlDocument -Raw $raw
$pre = Get-PreambleSection $doc
$personalSet = Get-PersonalNameSet
$existingDisabled = @(Get-CurrentDisabledServers $pre)

$keep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($k in $script:CodingKeepServers) { [void]$keep.Add($k) }
if ($Profile -eq 'coding') {
    $newDisabled = Merge-NameLists $existingDisabled $script:PersonalMcpNames
    $newDisabled = Remove-NamesFromList $newDisabled $keep
} else {
    $newDisabled = Remove-NamesFromList $existingDisabled $personalSet
}

if ($newDisabled.Count -gt 0) {
    $pre = Set-SectionBareLine -Section $pre -Bare 'disabled_mcp_servers' -Line ('disabled_mcp_servers = {0}' -f (Format-TomlStringArray $newDisabled))
} else {
    $pre = Remove-TomlKeysFromSection -Section $pre -BareKeys @('disabled_mcp_servers') -Heads @()
}
$doc.Preamble = $pre.Lines

$gwSec = Find-TomlSection -Doc $doc -Name 'disabled_mcp_tools' -Kind 'table'
if ($null -eq $gwSec) {
    $gwSec = @{
        Kind       = 'table'
        Name       = 'disabled_mcp_tools'
        HeaderLine = '[disabled_mcp_tools]'
        Lines      = New-Object System.Collections.Generic.List[string]
    }
    [void]$doc.Sections.Add($gwSec)
}
$gwExisting = @(Get-QuotedStrings (Get-SectionAssignmentText -Section $gwSec -Bare '__managed_gateway_connectors'))
if ($Profile -eq 'coding') {
    $gwNew = Merge-NameLists $gwExisting $script:PersonalMcpNames
} else {
    $gwNew = Remove-NamesFromList $gwExisting $personalSet
}
if ($gwNew.Count -gt 0) {
    $updatedGw = Set-SectionBareLine -Section $gwSec -Bare '__managed_gateway_connectors' -Line ('__managed_gateway_connectors = {0}' -f (Format-TomlStringArray $gwNew))
    $gwSec.Lines = $updatedGw.Lines
} else {
    $cleared = Remove-TomlKeysFromSection -Section $gwSec -BareKeys @('__managed_gateway_connectors') -Heads @()
    $gwSec.Lines = $cleared.Lines
    $hasAssign = $false
    foreach ($l in @($gwSec.Lines)) {
        if ($l -and $l.Trim() -and -not $l.Trim().StartsWith('#')) { $hasAssign = $true; break }
    }
    if (-not $hasAssign) {
        $kept = New-Object System.Collections.Generic.List[object]
        foreach ($sec in $doc.Sections) {
            if ([string]$sec.Name -eq 'disabled_mcp_tools') { continue }
            [void]$kept.Add($sec)
        }
        $doc.Sections = $kept
    }
}

if ($Profile -eq 'coding') {
    foreach ($n in $script:CodingKeepServers) { Set-McpServerEnabledFlag $doc $n $true }
    foreach ($n in $script:PersonalMcpNames) { Set-McpServerEnabledFlag $doc $n $false }
}

$newRaw = ConvertTo-VibeTomlDocument -Doc $doc
$parseErr = Test-TomlStrictParse -Raw $newRaw
if ($parseErr) {
    throw ("profile toml failed strict parse: {0}" -f $parseErr)
}

if ($DryRun) {
    Write-Host ("DRY {0}: disabled_mcp_servers = {1}" -f $Profile, ($(if ($newDisabled.Count) { $newDisabled -join ', ' } else { '(none)' })))
    Write-Host ("DRY {0}: gateway = {1}" -f $Profile, ($(if ($gwNew.Count) { $gwNew -join ', ' } else { '(none)' })))
    exit 0
}

$null = Backup-VibeConfigFile -ConfigPath $ConfigPath -BackupSuffix ("mcp-{0}-{1}" -f $Profile, (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-Utf8NoBomFile -Path $ConfigPath -Content $newRaw
Write-McpProfileState -Path $StatePath -Name $Profile -Disabled $script:PersonalMcpNames
Write-Host ("MCP profile: {0}" -f $Profile) -ForegroundColor Green
Write-Host ("  disabled_mcp_servers: {0}" -f ($(if ($newDisabled.Count) { $newDisabled -join ', ' } else { '(none)' })))
Write-Host '  Restart Grok if a session is already open. /mcps for leftover gateway connectors.'
exit 0

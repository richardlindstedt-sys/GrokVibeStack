#Requires -Version 5.1
<#
.SYNOPSIS
  Shared ~/.grok/config.toml helpers for the vibe stack.

.DESCRIPTION
  Grok rewrites config.toml and drops comments, including managed-block
  markers. Reinstall then used to append the snippet on top of the same tables
  (duplicate-key TOML) which makes grok.exe refuse to start.

  Merge is key-level for tables Grok/user share ([session], [features], [mcp],
  [models]): only stack keys are written. User keys and unrelated tables
  ([ui], [marketplace], [privacy], custom models/MCP) stay. Stack-only tables
  (Headroom/Serena MCP, grok-4.6 overrides) are replaced as a whole.
#>

function Get-VibeOwnedTomlSections {
    return @(
        'session', 'features', 'mcp',
        'mcp_servers.headroom', 'mcp_servers.serena',
        'model."grok-4.6"', 'model.grok-4.6', 'model.grok-via-headroom',
        'model."grok-gate"', 'model.grok-gate',
        'model."grok-4.6-direct"', 'model.grok-4.6-direct', 'models'
    )
}

function Get-VibeSharedTomlTables {
    return @('session', 'features', 'mcp', 'models')
}

function Get-VibeStackOnlyTomlTables {
    return @(
        'mcp_servers.headroom', 'mcp_servers.serena',
        'model."grok-4.6"', 'model.grok-4.6', 'model.grok-via-headroom',
        'model."grok-gate"', 'model.grok-gate',
        'model."grok-4.6-direct"', 'model.grok-4.6-direct'
    )
}

function Get-VibeCanonicalStackOnlyTomlTables {
    return @(
        'mcp_servers.headroom', 'mcp_servers.serena',
        'model."grok-4.6"', 'model.grok-via-headroom', 'model."grok-gate"', 'model."grok-4.6-direct"'
    )
}

function Get-VibeStackTomlKeys {
    return @{
        session  = @('auto_compact_threshold_percent')
        features = @('two_pass_compaction')
        mcp      = @('max_output_bytes')
        models   = @('default', 'default_reasoning_effort')
    }
}

function Get-VibeParentOwnedKeys {
    return @{
        mcp_servers = @('headroom', 'serena')
        model       = @('grok-4.6', 'grok-via-headroom', 'grok-gate', 'grok-4.6-direct')
    }
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

function Convert-VibeToArray {
    param($Value)
    if ($null -eq $Value) { return ,@() }
    # String foreach walks chars; hashtable foreach walks DictionaryEntry.
    if ($Value -is [string]) { return ,@($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return ,@($Value) }
    $a = New-Object System.Collections.ArrayList
    foreach ($i in @($Value)) { [void]$a.Add($i) }
    return ,$a.ToArray()
}

function Get-TomlPathSegments {
    param([string]$Name)
    $segs = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Name)) { return $segs.ToArray() }
    $n = [string]$Name
    $i = 0
    while ($i -lt $n.Length) {
        while ($i -lt $n.Length -and $n[$i] -eq '.') { $i++ }
        if ($i -ge $n.Length) { break }
        $ch = $n[$i]
        if ($ch -eq '"' -or $ch -eq "'") {
            $j = $i + 1
            while ($j -lt $n.Length -and $n[$j] -ne $ch) { $j++ }
            [void]$segs.Add($n.Substring($i + 1, [Math]::Max(0, $j - $i - 1)))
            $i = [Math]::Min($n.Length, $j + 1)
        } else {
            $j = $i
            while ($j -lt $n.Length -and $n[$j] -ne '.') { $j++ }
            [void]$segs.Add($n.Substring($i, $j - $i))
            $i = $j
        }
    }
    return $segs.ToArray()
}

function Get-TomlBareKey {
    param([string]$Key)
    if ([string]::IsNullOrEmpty($Key)) { return '' }
    $t = $Key.Trim()
    if ($t.Length -ge 2) {
        $a = $t[0]; $b = $t[$t.Length - 1]
        if (($a -eq '"' -and $b -eq '"') -or ($a -eq "'" -and $b -eq "'")) {
            return $t.Substring(1, $t.Length - 2)
        }
    }
    return $t
}

function Get-TomlKeyHead {
    param([string]$Key)
    $segs = @(Get-TomlPathSegments -Name (Get-TomlBareKey $Key))
    if ($segs.Count -gt 0) { return [string]$segs[0] }
    return (Get-TomlBareKey $Key)
}

function Get-TomlBracketDelta {
    param([string]$Line)
    $sq = 0; $cu = 0
    $in = [char]0
    $esc = $false
    foreach ($c in $Line.ToCharArray()) {
        if ($in -ne [char]0) {
            if ($esc) { $esc = $false; continue }
            if ($c -eq '\' -and $in -eq '"') { $esc = $true; continue }
            if ($c -eq $in) { $in = [char]0 }
            continue
        }
        if ($c -eq '"' -or $c -eq "'") { $in = $c; continue }
        if ($c -eq '#') { break }
        if ($c -eq '[') { $sq++ }
        elseif ($c -eq ']') { $sq-- }
        elseif ($c -eq '{') { $cu++ }
        elseif ($c -eq '}') { $cu-- }
    }
    return @{ Sq = $sq; Cu = $cu }
}

function Get-TomlAssignmentSpans {
    param($Lines)
    $spans = New-Object System.Collections.Generic.List[object]
    $arr = [string[]](Convert-VibeToArray $Lines)
    if ($null -eq $arr -or $arr.Length -eq 0) { return $spans.ToArray() }
    $i = 0
    $n = $arr.Length
    while ($i -lt $n) {
        $line = [string]$arr[$i]
        $trim = $line.Trim()
        if ($trim -eq '' -or $trim.StartsWith('#')) { $i++; continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { $i++; continue }
        $key = $line.Substring(0, $eq).Trim()
        if ($key -notmatch '^[A-Za-z0-9_\-"''.]+') { $i++; continue }
        $start = $i
        $sq = 0; $cu = 0
        do {
            $d = Get-TomlBracketDelta ([string]$arr[$i])
            $sq += [int]$d.Sq
            $cu += [int]$d.Cu
            $i++
        } while ($i -lt $n -and ($sq -gt 0 -or $cu -gt 0))
        [void]$spans.Add([pscustomobject]@{
            Key   = $key
            Bare  = (Get-TomlBareKey $key)
            Head  = (Get-TomlKeyHead $key)
            Start = $start
            End   = ($i - 1)
        })
    }
    return $spans.ToArray()
}

function ConvertFrom-VibeTomlDocument {
    param([string]$Raw)
    $preamble = New-Object System.Collections.Generic.List[string]
    $sections = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Raw)) {
        return @{ Preamble = $preamble; Sections = $sections }
    }
    $lines = $Raw -split "`r?`n", -1
    $cur = $null
    foreach ($line in $lines) {
        $hdr = ConvertFrom-TomlTableLine $line
        if ($hdr) {
            $cur = @{
                Kind       = [string]$hdr.Kind
                Name       = [string]$hdr.Name
                HeaderLine = [string]$line
                Lines      = New-Object System.Collections.Generic.List[string]
            }
            [void]$sections.Add($cur)
            continue
        }
        if ($null -eq $cur) {
            [void]$preamble.Add([string]$line)
        } else {
            [void]$cur.Lines.Add([string]$line)
        }
    }
    return @{ Preamble = $preamble; Sections = $sections }
}

function ConvertTo-VibeTomlDocument {
    param($Doc)
    $out = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Doc.Preamble) {
        foreach ($l in $Doc.Preamble) {
            [void]$out.Add([string]$l)
        }
    }
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) {
        $out.RemoveAt($out.Count - 1)
    }
    if ($null -ne $Doc.Sections) {
        foreach ($sec in $Doc.Sections) {
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { [void]$out.Add('') }
        if ($sec.Name -ne '') {
            $hdr = [string]$sec.HeaderLine
            if (-not $hdr) {
                if ($sec.Kind -eq 'array') { $hdr = ('[[{0}]]' -f $sec.Name) }
                else { $hdr = ('[{0}]' -f $sec.Name) }
            }
            [void]$out.Add($hdr)
        }
        if ($null -ne $sec.Lines) {
            foreach ($l in $sec.Lines) { [void]$out.Add([string]$l) }
        }
        while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) {
            $out.RemoveAt($out.Count - 1)
        }
        }
    }
    $text = ($out -join "`n").TrimEnd() + "`n"
    return $text
}

function Test-TomlSectionHasKeys {
    param($Section)
    $spans = @(Get-TomlAssignmentSpans -Lines $Section.Lines)
    return ($spans.Count -gt 0)
}

function Remove-TomlKeysFromSection {
    param($Section, $BareKeys, $Heads)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Section.Lines) {
        foreach ($l in $Section.Lines) { [void]$lines.Add([string]$l) }
    }
    $bareSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($k in (Convert-VibeToArray $BareKeys)) { if ($k) { [void]$bareSet.Add([string]$k) } }
    $headSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($k in (Convert-VibeToArray $Heads)) { if ($k) { [void]$headSet.Add([string]$k) } }
    $spans = @(Get-TomlAssignmentSpans -Lines $lines)
    $drop = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($sp in $spans) {
        $hit = $false
        if ($bareSet.Contains([string]$sp.Bare)) { $hit = $true }
        if ($headSet.Contains([string]$sp.Head)) { $hit = $true }
        if ($hit) {
            for ($i = [int]$sp.Start; $i -le [int]$sp.End; $i++) { [void]$drop.Add($i) }
        }
    }
    if ($drop.Count -eq 0) { return $Section }
    $kept = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $drop.Contains($i)) { [void]$kept.Add($lines[$i]) }
    }
    $Section.Lines = $kept
    return $Section
}

function Set-TomlKeysOnSection {
    param($Section, $FromSection, $BareKeys)
    $want = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($k in (Convert-VibeToArray $BareKeys)) { if ($k) { [void]$want.Add([string]$k) } }
    $Section = Remove-TomlKeysFromSection -Section $Section -BareKeys $BareKeys -Heads @()
    $srcLines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $FromSection.Lines) {
        foreach ($l in $FromSection.Lines) { [void]$srcLines.Add([string]$l) }
    }
    $srcSpans = @(Get-TomlAssignmentSpans -Lines $srcLines)
    $add = New-Object System.Collections.Generic.List[string]
    foreach ($sp in $srcSpans) {
        if (-not $want.Contains([string]$sp.Bare)) { continue }
        for ($i = [int]$sp.Start; $i -le [int]$sp.End; $i++) {
            [void]$add.Add([string]$srcLines[$i])
        }
    }
    if ($add.Count -eq 0) { return $Section }
    $dst = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Section.Lines) {
        foreach ($l in $Section.Lines) { [void]$dst.Add([string]$l) }
    }
    while ($dst.Count -gt 0 -and [string]::IsNullOrWhiteSpace($dst[$dst.Count - 1])) {
        $dst.RemoveAt($dst.Count - 1)
    }
    foreach ($l in $add) { [void]$dst.Add($l) }
    $Section.Lines = $dst
    return $Section
}

function Collapse-VibeTomlDuplicateTables {
    param($Doc)
    $firstPos = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($sec in $Doc.Sections) {
        if ([string]$sec.Kind -ne 'table') {
            [void]$kept.Add($sec)
            continue
        }
        $name = [string]$sec.Name
        if ($firstPos.ContainsKey($name)) {
            $kept[$firstPos[$name]] = $sec
        } else {
            $firstPos[$name] = $kept.Count
            [void]$kept.Add($sec)
        }
    }
    $Doc.Sections = $kept
    return $Doc
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
    return $dups.ToArray()
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
        foreach ($n in @($OnlyNames)) {
            if ($n) { [void]$filter.Add($n) }
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

function Remove-VibeManagedTomlMarkers {
    param([string]$Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return $Raw }
    $m = Get-VibeManagedBlockMarkers
    $lines = $Raw -split "`r?`n", -1
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -eq $m.Begin -or $t -eq $m.End) { continue }
        [void]$out.Add($line)
    }
    return ($out -join "`n")
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

function Find-TomlSection {
    param($Doc, [string]$Name, [string]$Kind = 'table')
    if ($null -eq $Doc.Sections) { return $null }
    foreach ($sec in $Doc.Sections) {
        if ([string]$sec.Kind -eq $Kind -and [string]$sec.Name -eq $Name) { return $sec }
    }
    return $null
}

function Get-TomlIntraTableDuplicateKeys {
    param([string]$Raw)
    $dups = New-Object System.Collections.Generic.List[string]
    $doc = ConvertFrom-VibeTomlDocument -Raw $Raw
    foreach ($sec in $doc.Sections) {
        if ([string]$sec.Kind -ne 'table') { continue }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($sp in @(Get-TomlAssignmentSpans -Lines $sec.Lines)) {
            $k = [string]$sp.Bare
            if (-not $seen.Add($k)) {
                $label = if ($sec.Name) { ('{0}.{1}' -f $sec.Name, $k) } else { $k }
                if (-not $dups.Contains($label)) { [void]$dups.Add($label) }
            }
        }
    }
    return $dups.ToArray()
}

function Get-TomlPathCollisions {
    param([string]$Raw)
    $hits = New-Object System.Collections.Generic.List[string]
    $tablePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $valuePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $doc = ConvertFrom-VibeTomlDocument -Raw $Raw

    function Join-TomlPath {
        param($Segs)
        $parts = New-Object System.Collections.ArrayList
        if ($null -ne $Segs) {
            foreach ($s in $Segs) { [void]$parts.Add([string]$s) }
        }
        return ($parts -join "`0")
    }

    foreach ($sec in $doc.Sections) {
        if ([string]$sec.Kind -ne 'table') { continue }
        $base = @(Get-TomlPathSegments -Name ([string]$sec.Name))
        if ($base.Count -eq 0 -and $sec.Name -eq '') { $base = @() }
        $acc = New-Object System.Collections.Generic.List[string]
        foreach ($s in $base) {
            [void]$acc.Add($s)
            $p = Join-TomlPath $acc
            if ($valuePaths.Contains($p)) {
                [void]$hits.Add(('path {0} is both a value and a table' -f ($acc -join '.')))
            }
            [void]$tablePaths.Add($p)
        }
        foreach ($sp in @(Get-TomlAssignmentSpans -Lines $sec.Lines)) {
            $keySegs = @(Get-TomlPathSegments -Name ([string]$sp.Bare))
            $vp = New-Object System.Collections.Generic.List[string]
            foreach ($s in $base) { [void]$vp.Add($s) }
            foreach ($s in $keySegs) { [void]$vp.Add($s) }
            $path = Join-TomlPath $vp
            if ($tablePaths.Contains($path)) {
                [void]$hits.Add(('duplicate key `{0}` (value collides with table)' -f ($vp -join '.')))
            }
            if (-not $valuePaths.Add($path)) {
                [void]$hits.Add(('duplicate key `{0}`' -f ($vp -join '.')))
            }
        }
    }
    return $hits.ToArray()
}

function Test-TomlStrictParse {
    param([string]$Raw)
    $py = $null
    foreach ($p in @(
            (Join-Path $env:USERPROFILE '.grok\token-saving\venv\Scripts\python.exe'),
            (Join-Path $env:USERPROFILE '.grok\vibe-tools\venv\Scripts\python.exe')
        )) {
        if (Test-Path -LiteralPath $p) { $py = $p; break }
    }
    if (-not $py) {
        $cmd = Get-Command python -ErrorAction SilentlyContinue
        if ($cmd) { $py = [string]$cmd.Source }
    }
    if (-not $py) { return $null }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('vibe-toml-{0}.toml' -f [guid]::NewGuid().ToString('n'))
    $pyf = Join-Path ([System.IO.Path]::GetTempPath()) ('vibe-toml-{0}.py' -f [guid]::NewGuid().ToString('n'))
    try {
        Write-Utf8NoBomFile -Path $tmp -Content $Raw
        $code = @(
            'import sys'
            'p = sys.argv[1]'
            'try:'
            '    import tomllib'
            'except ImportError:'
            '    try:'
            '        import tomli as tomllib'
            '    except ImportError:'
            '        sys.exit(0)'
            'try:'
            '    tomllib.load(open(p, "rb"))'
            'except Exception as e:'
            '    sys.stderr.write(str(e))'
            '    sys.exit(2)'
        ) -join "`n"
        Write-Utf8NoBomFile -Path $pyf -Content $code
        $err = & $py $pyf $tmp 2>&1
        if ($LASTEXITCODE -eq 2) {
            return ([string]$err).Trim()
        }
        return $null
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pyf -Force -ErrorAction SilentlyContinue
    }
}

function Merge-VibeToml {
    param(
        [string]$Raw,
        [string]$Snippet
    )
    $userRaw = Remove-VibeManagedTomlMarkers -Raw $(if ($null -eq $Raw) { '' } else { $Raw })
    $userRaw = Repair-TomlKeepLastTables -Raw $userRaw
    $userDoc = ConvertFrom-VibeTomlDocument -Raw $userRaw
    $userDoc = Collapse-VibeTomlDuplicateTables -Doc $userDoc
    $snipDoc = ConvertFrom-VibeTomlDocument -Raw $(Remove-VibeManagedTomlMarkers -Raw $Snippet)
    $snipDoc = Collapse-VibeTomlDuplicateTables -Doc $snipDoc

    $stackOnly = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in (Get-VibeStackOnlyTomlTables)) { [void]$stackOnly.Add($n) }
    $shared = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in (Get-VibeSharedTomlTables)) { [void]$shared.Add($n) }
    $stackKeys = Get-VibeStackTomlKeys
    $parentOwned = Get-VibeParentOwnedKeys

    $kept = New-Object System.Collections.Generic.List[object]
    $haveShared = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($sec in $userDoc.Sections) {
        $name = [string]$sec.Name
        $kind = [string]$sec.Kind
        if ($kind -eq 'table' -and $stackOnly.Contains($name)) { continue }
        if ($kind -eq 'table' -and $shared.Contains($name)) {
            $from = Find-TomlSection -Doc $snipDoc -Name $name
            $keys = @()
            if ($stackKeys.ContainsKey($name)) { $keys = @($stackKeys[$name]) }
            if ($from -and $keys.Count -gt 0) {
                $sec = Set-TomlKeysOnSection -Section $sec -FromSection $from -BareKeys $keys
            }
            [void]$haveShared.Add($name)
            [void]$kept.Add($sec)
            continue
        }
        if ($kind -eq 'table' -and $parentOwned.ContainsKey($name)) {
            $sec = Remove-TomlKeysFromSection -Section $sec -BareKeys @($parentOwned[$name]) -Heads @($parentOwned[$name])
            if (Test-TomlSectionHasKeys $sec) { [void]$kept.Add($sec) }
            continue
        }
        if ($kind -eq 'table' -and $name -eq '') {
            $heads = New-Object System.Collections.Generic.List[string]
            foreach ($k in $parentOwned.Keys) { [void]$heads.Add($k) }
            foreach ($k in $shared) { [void]$heads.Add($k) }
            $sec = Remove-TomlKeysFromSection -Section $sec -BareKeys @() -Heads $heads
            if (Test-TomlSectionHasKeys $sec -or (@($sec.Lines | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })).Count -gt 0) {
                [void]$kept.Add($sec)
            }
            continue
        }
        [void]$kept.Add($sec)
    }

    foreach ($name in (Get-VibeSharedTomlTables)) {
        if ($haveShared.Contains($name)) { continue }
        $from = Find-TomlSection -Doc $snipDoc -Name $name
        if ($from) { [void]$kept.Add($from) }
    }

    $m = Get-VibeManagedBlockMarkers
    $managed = New-Object System.Collections.Generic.List[object]
    foreach ($name in (Get-VibeCanonicalStackOnlyTomlTables)) {
        $from = Find-TomlSection -Doc $snipDoc -Name $name
        if ($from) { [void]$managed.Add($from) }
    }

    $preamble = New-Object System.Collections.Generic.List[string]
    foreach ($l in $userDoc.Preamble) {
        $t = [string]$l
        if ($t.Trim() -eq $m.Begin -or $t.Trim() -eq $m.End) { continue }
        [void]$preamble.Add($t)
    }

    $outSecs = New-Object System.Collections.Generic.List[object]
    foreach ($s in $kept) { [void]$outSecs.Add($s) }
    $text = ConvertTo-VibeTomlDocument @{ Preamble = $preamble; Sections = $outSecs }
    if ($managed.Count -gt 0) {
        $block = ConvertTo-VibeTomlDocument @{ Preamble = @(); Sections = $managed }
        $text = $text.TrimEnd() + "`n`n" + $m.Begin + "`n" + $block.TrimEnd() + "`n" + $m.End + "`n"
    }
    $text = Repair-TomlKeepLastTables -Raw $text
    return ($text.TrimEnd() + "`n")
}

function Remove-VibeStackFromToml {
    param([string]$Raw)
    $raw = Remove-VibeManagedTomlMarkers -Raw $(if ($null -eq $Raw) { '' } else { $Raw })
    $doc = ConvertFrom-VibeTomlDocument -Raw $raw
    $stackOnly = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in (Get-VibeStackOnlyTomlTables)) { [void]$stackOnly.Add($n) }
    $stackKeys = Get-VibeStackTomlKeys
    $parentOwned = Get-VibeParentOwnedKeys
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($sec in $doc.Sections) {
        $name = [string]$sec.Name
        $kind = [string]$sec.Kind
        if ($kind -eq 'table' -and $stackOnly.Contains($name)) { continue }
        if ($kind -eq 'table' -and $stackKeys.ContainsKey($name)) {
            $sec = Remove-TomlKeysFromSection -Section $sec -BareKeys @($stackKeys[$name]) -Heads @()
            if (Test-TomlSectionHasKeys $sec) { [void]$kept.Add($sec) }
            continue
        }
        if ($kind -eq 'table' -and $parentOwned.ContainsKey($name)) {
            $sec = Remove-TomlKeysFromSection -Section $sec -BareKeys @($parentOwned[$name]) -Heads @($parentOwned[$name])
            if (Test-TomlSectionHasKeys $sec) { [void]$kept.Add($sec) }
            continue
        }
        [void]$kept.Add($sec)
    }
    return (ConvertTo-VibeTomlDocument @{ Preamble = $doc.Preamble; Sections = $kept })
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
    $raw = Read-Utf8NoBomFile -Path $BackupPath
    if (-not (Test-VibeToml -Raw $raw).Ok) { return $false }
    Copy-Item -LiteralPath $BackupPath -Destination $ConfigPath -Force
    return $true
}

function Confirm-VibeConfigWrite {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$BackupPath,
        [string]$ExpectedRaw = ''
    )
    $attempts = 3
    for ($n = 0; $n -lt $attempts; $n++) {
        $onDisk = Read-Utf8NoBomFile -Path $ConfigPath
        $recheck = Test-VibeToml -Raw $onDisk
        if ($recheck.Ok) { return $recheck }
        if ($ExpectedRaw -and (Test-VibeToml -Raw $ExpectedRaw).Ok) {
            Write-Utf8NoBomFile -Path $ConfigPath -Content $ExpectedRaw
            Start-Sleep -Milliseconds 150
            continue
        }
        break
    }
    if ($ExpectedRaw -and (Test-VibeToml -Raw $ExpectedRaw).Ok) {
        Write-Utf8NoBomFile -Path $ConfigPath -Content $ExpectedRaw
        $again = Test-VibeToml -Raw (Read-Utf8NoBomFile -Path $ConfigPath)
        if ($again.Ok) { return $again }
        throw ('config.toml re-read after write is invalid: {0}; left last valid merge on disk (not restoring a broken backup)' -f ($again.Errors -join '; '))
    }
    $onDisk = Read-Utf8NoBomFile -Path $ConfigPath
    $recheck = Test-VibeToml -Raw $onDisk
    if ($recheck.Ok) { return $recheck }
    $restored = $false
    if ($BackupPath) {
        $restored = Restore-VibeConfigBackup -ConfigPath $ConfigPath -BackupPath $BackupPath
    }
    $note = if ($restored) { '; restored last good backup' } else { '; backup was not valid (not restored)' }
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
    $bakHr = $false
    if ($sidecarRaw) {
        $bakHr = [bool]((Test-VibeToml -Raw $sidecarRaw).HasHeadroomOverride)
    }
    # Prefer bak as merge *input* only when live lacks Headroom and bak has the
    # quoted override. Merge still key-level upserts (dups in bak are collapsed).
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
        SidecarPath = $(if ($sidecarRaw) { $sidecar } else { $null })
    }
}

function Test-TomlQuotedModelBaseUrl {
    param(
        [string]$Raw,
        [string]$ModelId,
        [string]$MustContain
    )
    if ([string]::IsNullOrEmpty($Raw) -or [string]::IsNullOrEmpty($ModelId) -or [string]::IsNullOrEmpty($MustContain)) {
        return $false
    }
    $doc = ConvertFrom-VibeTomlDocument -Raw $Raw
    $sec = Find-TomlSection -Doc $doc -Name ('model."{0}"' -f $ModelId)
    if (-not $sec) { return $false }
    $arr = [string[]](Convert-VibeToArray $sec.Lines)
    foreach ($sp in @(Get-TomlAssignmentSpans -Lines $arr)) {
        if ([string]$sp.Bare -ne 'base_url') { continue }
        $chunk = New-Object System.Collections.Generic.List[string]
        for ($i = [int]$sp.Start; $i -le [int]$sp.End; $i++) {
            [void]$chunk.Add([string]$arr[$i])
        }
        return [bool](($chunk -join "`n") -match [regex]::Escape($MustContain))
    }
    return $false
}

function Test-VibeToml {
    param([string]$Raw)
    $dups = @(Get-TomlDuplicateTables -Raw $Raw)
    $keyDups = @(Get-TomlIntraTableDuplicateKeys -Raw $Raw)
    $collisions = @(Get-TomlPathCollisions -Raw $Raw)
    $strict = Test-TomlStrictParse -Raw $Raw
    # One Headroom on :8787. grok-gate is an alias — table-local base_url, not a file-wide :8788 hunt.
    $hasHr = Test-TomlQuotedModelBaseUrl -Raw $Raw -ModelId 'grok-4.6' -MustContain '127.0.0.1:8787'
    $hasGate = Test-TomlQuotedModelBaseUrl -Raw $Raw -ModelId 'grok-gate' -MustContain '127.0.0.1:8787'
    $errors = New-Object System.Collections.Generic.List[string]
    if ($dups.Count -gt 0) {
        [void]$errors.Add(('duplicate TOML tables: {0}' -f ($dups -join ', ')))
    }
    if ($keyDups.Count -gt 0) {
        [void]$errors.Add(('duplicate key: {0}' -f ($keyDups -join ', ')))
    }
    if ($collisions.Count -gt 0) {
        [void]$errors.Add(('duplicate key: {0}' -f ($collisions -join ', ')))
    }
    if ($strict) {
        [void]$errors.Add(('TOML parse: {0}' -f $strict))
    }
    if (-not $hasHr) {
        [void]$errors.Add('missing quoted [model."grok-4.6"] Headroom override (127.0.0.1:8787)')
    }
    if (-not $hasGate) {
        [void]$errors.Add('missing quoted [model."grok-gate"] Headroom override (127.0.0.1:8787)')
    }
    return @{
        Ok                   = ($errors.Count -eq 0)
        Duplicates           = $dups
        HasHeadroomOverride  = $hasHr
        HasGateOverride      = $hasGate
        Errors               = $errors.ToArray()
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
        $merged = Repair-TomlKeepLastTables -Raw $merged
        $check = Test-VibeToml -Raw $merged
    }
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
    $recheck = Confirm-VibeConfigWrite -ConfigPath $ConfigPath -BackupPath $backup -ExpectedRaw $merged
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

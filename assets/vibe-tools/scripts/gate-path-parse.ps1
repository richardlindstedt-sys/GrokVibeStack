#Requires -Version 5.1
<#
.SYNOPSIS
    AutoProfile / restage path helpers (dot-sourced by grok-ai-review.ps1).
.NOTES
    Parses quoted `diff --git` headers, keeps both rename sides, rejects `.` / dirs / glob / pathspec.
#>

function Split-DiffGitPaths {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $t = $Line.TrimEnd("`r")
    if ($t.Length -lt 12 -or -not $t.StartsWith('diff --git ')) { return $null }
    $rest = $t.Substring(11)
    $parts = [System.Collections.Generic.List[string]]::new()
    $i = 0
    $len = $rest.Length
    while ($i -lt $len) {
        while ($i -lt $len -and [char]::IsWhiteSpace($rest[$i])) { $i++ }
        if ($i -ge $len) { break }
        if ($rest[$i] -eq [char]34) {
            $i++
            $sb = New-Object System.Text.StringBuilder
            while ($i -lt $len) {
                $ch = $rest[$i]
                if ($ch -eq [char]92 -and ($i + 1) -lt $len) {
                    [void]$sb.Append($rest[$i + 1])
                    $i += 2
                    continue
                }
                if ($ch -eq [char]34) { $i++; break }
                [void]$sb.Append($ch)
                $i++
            }
            [void]$parts.Add($sb.ToString())
        } else {
            $start = $i
            while ($i -lt $len -and -not [char]::IsWhiteSpace($rest[$i])) { $i++ }
            [void]$parts.Add($rest.Substring($start, $i - $start))
        }
    }
    if ($parts.Count -lt 2) { return $null }
    $a = [string]$parts[0]
    $b = [string]$parts[1]
    if ($a.StartsWith('a/')) { $a = $a.Substring(2) }
    if ($b.StartsWith('b/')) { $b = $b.Substring(2) }
    return @{ A = $a; B = $b }
}

function Add-ChangedPathToList {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    if ($null -eq $List) { return }
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $p = $Path.Trim()
    if (-not $p -or $p -eq '/dev/null') { return }
    [void]$List.Add($p)
}

function Get-PathsFromDiffText {
    param([string]$DiffText)
    $paths = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($DiffText)) { return @() }
    foreach ($line in ($DiffText -split "`n")) {
        $sides = Split-DiffGitPaths $line
        if (-not $sides) { continue }
        # Keep both sides so a rename auth/x.py -> docs/y.md stays sensitive.
        Add-ChangedPathToList $paths $sides.A
        Add-ChangedPathToList $paths $sides.B
    }
    return @($paths | Select-Object -Unique)
}

function Add-NameStatusLineToList {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Line
    )
    if ([string]::IsNullOrWhiteSpace($Line) -or $null -eq $List) { return }
    $tab = $Line.TrimEnd("`r") -split "`t"
    if ($tab.Count -ge 3 -and $tab[0] -match '^[RC]') {
        Add-ChangedPathToList $List $tab[1]
        Add-ChangedPathToList $List $tab[2]
        return
    }
    if ($tab.Count -ge 2) {
        Add-ChangedPathToList $List $tab[1]
    }
}

function Normalize-RestagePath {
    <#
      Returns a repo-relative file path, or $null if unsafe / not a file.
      Rejects empty, `.`, `..`, `.git`, absolute, trailing-slash, directories,
      and git pathspec/glob metacharacters (`: * ? [` and control chars).
      Callers must feed git `:(literal)<path>` — never a raw/glob pathspec.
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $fp = $Path.Trim() -replace '\\', '/'
    $fp = $fp -replace '^\./+', ''
    if ([string]::IsNullOrWhiteSpace($fp) -or $fp -eq '.') { return $null }
    if ($fp.EndsWith('/')) { return $null }
    if ($fp -match '(^|/)\.\.(/|$)' -or $fp -match '(?i)(^|/)\.git(/|$)') { return $null }
    if ($fp.StartsWith('/') -or $fp -match '^[A-Za-z]:') { return $null }
    if ($fp -match '[:*?\[\x00-\x1F\x7F]') { return $null }
    $win = $fp -replace '/', [IO.Path]::DirectorySeparatorChar
    if (Test-Path -LiteralPath $win -PathType Container) { return $null }
    return $fp
}

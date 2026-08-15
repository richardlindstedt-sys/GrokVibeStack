<#
.SYNOPSIS
    Decide pre-push review profile + git range from hook stdin.
.DESCRIPTION
    Version tags (refs/tags/v1.2.3 or refs/tags/1.2.3) use profile=strict and
    a single-commit parent..tip diff — never the new-branch 20-commit walk.
    Any other tag also uses parent..tip (fast) so annotated/lightweight tags
    do not dump history into the reviewer brief.
#>

function Test-VibeVersionTagRef {
    param([string]$Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $false }
    return [bool]($Ref -match '^refs/tags/v?\d')
}

function Test-VibeTagRef {
    param([string]$Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $false }
    return [bool]($Ref -match '^refs/tags/')
}

function Get-VibePushReviewPlan {
    <#
      Returns hashtable:
        Profile      fast|strict
        AutoProfile  bool (off for version tags so docs-only cannot downgrade)
        Ranges       list of "a..b" or "NEW:sha" or "TAG:sha"
        Notes        human labels
        HasRefLines  true when git sent at least one 4-field ref line.
                     Empty Ranges is not empty stdin (delete-only / create-ref).
    #>
    param([string]$StdinText)

    $gateProfile = 'fast'
    $auto = $true
    $ranges = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $hasRefLines = $false

    if ([string]::IsNullOrWhiteSpace($StdinText)) {
        return @{
            Profile     = $gateProfile
            AutoProfile = $auto
            Ranges      = @()
            Notes       = @('no-stdin')
            HasRefLines = $false
        }
    }

    foreach ($line in ($StdinText -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $parts = $line -split '\s+'
        if ($parts.Count -lt 4) { continue }
        $hasRefLines = $true
        $localRef = $parts[0]
        $localSha = $parts[1]
        $remoteSha = $parts[3]

        if ($localSha -match '^0+$') {
            [void]$notes.Add("delete:$($parts[2])")
            continue
        }
        if ($localSha -notmatch '^[0-9a-fA-F]{7,64}$') { continue }

        if (Test-VibeTagRef $localRef) {
            if (Test-VibeVersionTagRef $localRef) {
                $gateProfile = 'strict'
                $auto = $false
                [void]$notes.Add("version-tag:$localRef->strict")
            } else {
                [void]$notes.Add("tag:$localRef")
            }
            [void]$ranges.Add("TAG:$localSha")
            continue
        }

        if ($remoteSha -match '^0+$') {
            [void]$ranges.Add("NEW:$localSha")
            [void]$notes.Add("new-branch:$localSha")
        } else {
            [void]$ranges.Add("$remoteSha..$localSha")
            [void]$notes.Add("$remoteSha..$localSha")
        }
    }

    return @{
        Profile     = $gateProfile
        AutoProfile = $auto
        Ranges      = @($ranges)
        Notes       = @($notes)
        HasRefLines = $hasRefLines
    }
}

function Get-VibePushTipShas {
    # Local SHAs being pushed (not the current checkout). Hex only.
    param($Ranges)
    $tips = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($Ranges)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if ($r.StartsWith('NEW:') -or $r.StartsWith('TAG:')) {
            $sha = $r.Substring(4).Trim()
            if ($sha -match '^[0-9a-fA-F]{7,64}$') { [void]$tips.Add($sha) }
            continue
        }
        if ($r -match '\.\.([^\.]+)$') {
            $sha = $Matches[1].Trim()
            if ($sha -match '^[0-9a-fA-F]{7,64}$') { [void]$tips.Add($sha) }
        }
    }
    return @($tips | Select-Object -Unique)
}

function Get-TagCommitDiff {
    <#
      Single-commit patch for a tag object or commit SHA.
    #>
    param(
        [string]$Sha,
        [scriptblock]$Flatten
    )
    if (-not $Flatten) {
        $Flatten = {
            param($raw)
            if ($null -eq $raw) { return $null }
            $s = if ($raw -is [string]) { $raw } else { (@($raw) | ForEach-Object { "$_" }) -join "`n" }
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            return $s
        }
    }
    $Sha = "$Sha".Trim()
    if ($Sha -notmatch '^[0-9a-fA-F]{7,64}$') { return $null }
    $commit = $null
    try { $commit = (git rev-parse --verify --quiet "$Sha^{commit}" 2>$null | Select-Object -First 1) } catch {}
    $commit = "$commit".Trim()
    if ($commit -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { return $null }
    $parent = $null
    try { $parent = (git rev-parse --verify --quiet "$commit^" 2>$null | Select-Object -First 1) } catch {}
    $parent = "$parent".Trim()
    if ($parent -and $parent -match '^[0-9a-f]{40}([0-9a-f]{24})?$' -and $parent -notmatch '^0+$') {
        return & $Flatten (git diff --no-color "$parent..$commit" 2>$null)
    }
    $root = & $Flatten (git diff-tree -p --root --no-color $commit 2>$null)
    if ($root) { return $root }
    return & $Flatten (git show --no-color --pretty=format: -p $commit 2>$null)
}

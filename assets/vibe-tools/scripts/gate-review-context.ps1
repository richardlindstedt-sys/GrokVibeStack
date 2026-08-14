<#
.SYNOPSIS
    Reviewer brief extras: stated intent, blast-radius hints, strict full-file reads.
#>

function Get-StatedIntent {
    if (-not [string]::IsNullOrWhiteSpace($env:VIBE_INTENT)) {
        return $env:VIBE_INTENT.Trim()
    }
    $gitDir = $null
    try { $gitDir = (git rev-parse --git-dir 2>$null | Select-Object -First 1) } catch {}
    if ($gitDir) {
        $msgFile = Join-Path $gitDir 'COMMIT_EDITMSG'
        if (Test-Path -LiteralPath $msgFile) {
            $raw = Get-Content -LiteralPath $msgFile -Raw -ErrorAction SilentlyContinue
            if ($raw) {
                $kept = foreach ($ln in ($raw -split "`r?`n")) {
                    if ($ln -match '^\s*#') { continue }
                    $ln
                }
                $t = ($kept -join "`n").Trim()
                if ($t) { return $t }
            }
        }
    }
    try {
        $head = (git log -1 --format=%B 2>$null)
        if ($head -isnot [string]) { $head = (@($head) -join "`n") }
        if (-not [string]::IsNullOrWhiteSpace($head)) { return $head.Trim() }
    } catch {}
    return ''
}

function Get-ChangedPathsFromDiff([string]$Diff) {
    $paths = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Diff)) { return @() }
    foreach ($line in ($Diff -split "`n")) {
        if ($line -match '^\+\+\+ b/(.+)$') {
            $p = $Matches[1].Trim()
            if ($p -and $p -ne '/dev/null') { [void]$paths.Add($p) }
        } elseif ($line -match '^diff --git a/(.+) b/(.+)$') {
            $p = $Matches[2].Trim()
            if ($p) { [void]$paths.Add($p) }
        }
    }
    return @($paths | Select-Object -Unique)
}

function Get-ChangedSymbolHints([string]$Diff) {
    $names = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Diff)) { return @() }
    $rx = [regex]'(?x)
        ^\+\s*
        (?:export\s+)?(?:async\s+)?
        (?:function|def|func|sub|proc|method)
        \s+([A-Za-z_][A-Za-z0-9_]{2,})
    '
    foreach ($line in ($Diff -split "`n")) {
        if ($line -notmatch '^\+[^+]') { continue }
        $m = $rx.Match($line)
        if ($m.Success) {
            $n = $m.Groups[1].Value
            if ($n -notin @('Get', 'Set', 'New', 'Test', 'Invoke', 'Write', 'Read')) {
                [void]$names.Add($n)
            }
        }
    }
    return @($names | Select-Object -Unique)
}

function Get-BlastRadiusNotes {
    param(
        [string]$Diff,
        [string[]]$ChangedPaths = @(),
        [int]$MaxSymbols = 10,
        [int]$MaxHits = 8
    )
    $sb = New-Object System.Text.StringBuilder
    $names = @(Get-ChangedSymbolHints $Diff | Select-Object -First $MaxSymbols)
    if ($names.Count -eq 0) { return '' }

    $changed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($ChangedPaths)) {
        if ($p) { [void]$changed.Add(($p -replace '\\', '/')) }
    }

    $hasRg = [bool](Get-Command rg -ErrorAction SilentlyContinue)
    $hasSg = [bool](Get-Command sg -ErrorAction SilentlyContinue)
    if (-not $hasRg -and -not $hasSg) {
        [void]$sb.AppendLine('## BLAST RADIUS')
        [void]$sb.AppendLine(('Changed symbols (no rg/sg): {0}' -f ($names -join ', ')))
        return $sb.ToString()
    }

    [void]$sb.AppendLine('## BLAST RADIUS (callers / other hits — heuristic, not a full call graph)')
    $total = 0
    foreach ($n in $names) {
        $hits = @()
        try {
            if ($hasRg) {
                $hits = @(rg -n -m 8 --glob '!node_modules' --glob '!.git' --glob '!venv' --glob '!.venv' --glob '!.serena' -- "\b$n\(" 2>$null)
            } elseif ($hasSg) {
                $hits = @(sg --pattern $n --json=stream 2>$null | Select-Object -First 8)
            }
        } catch { $hits = @() }
        $shown = 0
        foreach ($h in @($hits)) {
            $line = "$h"
            $pathPart = ($line -split ':')[0]
            $norm = ($pathPart -replace '\\', '/')
            $skip = $false
            foreach ($c in $changed) {
                if ($norm.EndsWith($c) -or $norm -eq $c) { $skip = $true; break }
            }
            if ($skip) { continue }
            if ($shown -eq 0) {
                [void]$sb.AppendLine(('### {0}' -f $n))
            }
            [void]$sb.AppendLine(('- {0}' -f $line))
            $shown++
            $total++
            if ($shown -ge 4 -or $total -ge $MaxHits) { break }
        }
        if ($total -ge $MaxHits) { break }
    }
    if ($total -eq 0) {
        [void]$sb.AppendLine(('No extra-file hits for: {0}' -f ($names -join ', ')))
    }
    [void]$sb.AppendLine('')
    return $sb.ToString()
}

function Get-StrictFullFileAppendix {
    param(
        [string[]]$Paths,
        [int]$MaxFiles = 8,
        [int]$PerFileChars = 12000
    )
    if (-not $Paths -or $Paths.Count -eq 0) { return '' }
    $root = $null
    try { $root = (git rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch {}
    if (-not $root) { $root = (Get-Location).Path }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## STRICT FULL FILE READS (second-pass context; truncated per file)')
    $n = 0
    foreach ($rel in @($Paths)) {
        if ($n -ge $MaxFiles) { break }
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if ($rel -match '(?i)\.(png|jpe?g|gif|webp|ico|pdf|zip|exe|dll|woff2?|bin)$') { continue }
        $full = $rel
        if (-not [IO.Path]::IsPathRooted($rel)) { $full = Join-Path $root $rel }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if (-not $item -or $item.Length -gt 400000) { continue }
        $text = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { continue }
        $n++
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('### FILE {0} ({1} chars)' -f $rel, $text.Length))
        if ($text.Length -gt $PerFileChars) {
            $text = $text.Substring(0, $PerFileChars) + "`n... [file truncated for brief] ..."
        }
        [void]$sb.AppendLine($text)
    }
    if ($n -eq 0) { return '' }
    [void]$sb.AppendLine('')
    return $sb.ToString()
}

function Add-ReviewContext {
    param(
        [string]$Brief,
        [string]$RawDiff,
        [string]$ProfileName,
        [int]$Round = 1
    )
    $sb = New-Object System.Text.StringBuilder
    $intent = Get-StatedIntent
    [void]$sb.AppendLine('## STATED INTENT')
    if ($intent) {
        [void]$sb.AppendLine($intent)
    } else {
        [void]$sb.AppendLine('(none — infer from the diff; do not invent a product goal)')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Intent check: advisory if staged diff clearly does not match this intent (extra unrelated files, missing promised change). Blocker if the message claims a security/correctness fix but the diff is unrelated or empty of that fix.')
    [void]$sb.AppendLine('')

    $paths = @(Get-ChangedPathsFromDiff $RawDiff)
    $blast = Get-BlastRadiusNotes -Diff $RawDiff -ChangedPaths $paths
    if ($blast) { [void]$sb.AppendLine($blast) }

    if ($Brief) { [void]$sb.AppendLine($Brief) }

    $wantFull = ($ProfileName -eq 'strict') -and ($Round -ge 2 -or $env:VIBE_STRICT_FULL_FILES -eq '1')
    # First strict round also gets full files when the brief was compressed.
    if ($ProfileName -eq 'strict' -and $RawDiff -and $Brief -and $Brief.Length -lt $RawDiff.Length) {
        $wantFull = $true
    }
    if ($wantFull) {
        $full = Get-StrictFullFileAppendix -Paths $paths
        if ($full) { [void]$sb.AppendLine($full) }
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
    Isolated git worktree for the implementer fix pass.
.DESCRIPTION
    Fixer edits HEAD + staged patch in a detached worktree so unstaged
    user work in the main tree is not mixed into the auto-fix. Changed
    files are copied back and the worktree is removed.
    Fail-open: if worktree add fails, caller should fix in-place.
#>

function New-FixerWorktree {
    param([string]$MainRoot)
    if (-not $MainRoot) {
        try { $MainRoot = (git rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch {}
    }
    if (-not $MainRoot) { return $null }
    $tmp = Join-Path $env:TEMP ('vibe-fix-' + [guid]::NewGuid().ToString('n').Substring(0, 10))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        git -C $MainRoot worktree add --detach $tmp HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $tmp '.git'))) {
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
            return $null
        }
        $patch = git -C $MainRoot diff --cached --binary --no-color 2>$null
        if ($patch) {
            $text = if ($patch -is [string]) { $patch } else { (@($patch) | ForEach-Object { "$_" }) -join "`n" }
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $patchFile = Join-Path $tmp '.vibe-staged.patch'
                $utf8 = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($patchFile, $text, $utf8)
                git -C $tmp apply --check --whitespace=nowarn --binary -- $patchFile 2>$null | Out-Null
                $checkOk = ($LASTEXITCODE -eq 0)
                if ($checkOk) {
                    git -C $tmp apply --whitespace=nowarn --binary -- $patchFile 2>$null | Out-Null
                }
                $applyOk = $checkOk -and ($LASTEXITCODE -eq 0)
                Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
                if (-not $applyOk) {
                    Remove-FixerWorktree @{ Root = $tmp; MainRoot = $MainRoot }
                    return $null
                }
            }
        }
        return @{ Root = $tmp; MainRoot = $MainRoot }
    } catch {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            try { git -C $MainRoot worktree remove --force $tmp 2>$null | Out-Null } catch {}
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $null
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-WorktreeFileFingerprints {
    param([string]$Root)
    $map = @{}
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return $map }
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.git([\\/]|$)' -and $_.Name -ne '.vibe-staged.patch'
        } |
        ForEach-Object {
            $rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
            $rel = $rel -replace '\\', '/'
            try {
                $map[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            } catch {}
        }
    return $map
}

function Copy-FixerWorktreeBack {
    param(
        [hashtable]$Worktree,
        [hashtable]$BeforeHashes
    )
    if (-not $Worktree -or -not $Worktree.Root -or -not $Worktree.MainRoot) { return @() }
    $after = Get-WorktreeFileFingerprints -Root $Worktree.Root
    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $after.Keys) {
        $newHash = $after[$rel]
        $oldHash = $null
        if ($BeforeHashes -and $BeforeHashes.ContainsKey($rel)) { $oldHash = $BeforeHashes[$rel] }
        if ($oldHash -eq $newHash) { continue }
        $src = Join-Path $Worktree.Root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $dst = Join-Path $Worktree.MainRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $dstDir = Split-Path $dst -Parent
        if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        [void]$copied.Add($rel)
    }
    # deletions in worktree vs before
    if ($BeforeHashes) {
        foreach ($rel in @($BeforeHashes.Keys)) {
            if ($after.ContainsKey($rel)) { continue }
            $dst = Join-Path $Worktree.MainRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $dst -PathType Leaf) {
                Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
                [void]$copied.Add($rel)
            }
        }
    }
    return @($copied)
}

function Remove-FixerWorktree {
    param([hashtable]$Worktree)
    if (-not $Worktree -or -not $Worktree.Root) { return }
    try {
        git -C $Worktree.MainRoot worktree remove --force $Worktree.Root 2>$null | Out-Null
    } catch {}
    if (Test-Path -LiteralPath $Worktree.Root) {
        Remove-Item -LiteralPath $Worktree.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Shared scan-pass cache helpers (Full-scope only authorizes Full skip).
.NOTES
    Dot-sourced by run-vibe-scans.ps1 and run-vibe-pre-push.ps1.
    Cache hit requires: matching treeHash, matching cwd, cached scope Full, within TTL.
    Missing scope/cwd fields are treated as miss (fail closed).
#>

if (-not $script:ScanPassCacheFile) {
    $script:ScanPassCacheFile = Join-Path $env:USERPROFILE '.grok\vibe-tools\cache\scan-pass-cache.json'
}
if (-not $script:ScanPassTtlSec -or $script:ScanPassTtlSec -le 0) {
    $script:ScanPassTtlSec = 7200
}

function Get-TreeHashForScanCache {
    $h = $null
    try { $h = (git write-tree 2>$null | Select-Object -First 1) } catch {}
    if (-not $h) {
        try { $h = (git rev-parse 'HEAD^{tree}' 2>$null | Select-Object -First 1) } catch {}
    }
    if ($h) { return "$h".Trim() }
    return $null
}

function Test-ScanPathsWholeTree([string[]]$Paths) {
    if ($null -eq $Paths -or @($Paths).Count -eq 0) { return $true }
    foreach ($p in @($Paths)) {
        $t = ("$p").Trim().TrimEnd('\', '/')
        if ($t -and $t -ne '.' -and $t -ne './') { return $false }
    }
    return $true
}

function Normalize-ScanCacheCwd([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/').ToLowerInvariant()
    } catch {
        return ("$Path".TrimEnd('\', '/')).ToLowerInvariant()
    }
}

function Save-ScanPassCache {
    param(
        [string]$TreeHash,
        [string]$ScopeUsed,
        [string]$Cwd,
        [string[]]$Paths = @()
    )
    # Only a Full-tree pass may authorize a later Full skip.
    if ($ScopeUsed -ne 'Full') { return }
    if (-not (Test-ScanPathsWholeTree $Paths)) { return }
    if (-not $TreeHash) { return }
    if (-not $Cwd) { $Cwd = (Get-Location).Path }
    try {
        $dir = Split-Path $script:ScanPassCacheFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $obj = [ordered]@{
            treeHash = $TreeHash
            scope    = 'Full'
            passedAt = (Get-Date -Format 'o')
            cwd      = $Cwd
        }
        ($obj | ConvertTo-Json -Compress) | Set-Content -Path $script:ScanPassCacheFile -Encoding utf8
    } catch {}
}

function Test-ScanPassCache {
    <#
      Returns $true only when cache authorizes skipping a Full scan:
      treeHash match + cwd match + cached scope is Full + within TTL.
      Missing scope or cwd => miss.
    #>
    param(
        [string]$TreeHash,
        [string]$Cwd,
        [string]$RequiredScope = 'Full',
        [int]$TtlSec = 0
    )
    if ($TtlSec -le 0) { $TtlSec = [int]$script:ScanPassTtlSec }
    if (-not $TreeHash -or -not $Cwd) { return $false }
    if (-not (Test-Path -LiteralPath $script:ScanPassCacheFile)) { return $false }
    # Only Full consumers are supported for skip (Staged/Auto must never skip Full).
    if ($RequiredScope -ne 'Full') { return $false }
    try {
        $e = Get-Content -LiteralPath $script:ScanPassCacheFile -Raw | ConvertFrom-Json
        if (-not $e) { return $false }
        if ("$($e.treeHash)".Trim() -ne "$TreeHash".Trim()) { return $false }

        # Missing scope => miss (legacy/forged weak entries cannot authorize Full).
        $cachedScope = "$($e.scope)".Trim()
        if (-not $cachedScope -or $cachedScope -ne 'Full') { return $false }

        $cachedCwd = Normalize-ScanCacheCwd ([string]$e.cwd)
        $wantCwd = Normalize-ScanCacheCwd $Cwd
        if (-not $cachedCwd -or -not $wantCwd -or $cachedCwd -ne $wantCwd) { return $false }

        if (-not $e.passedAt) { return $false }
        $when = [datetime]::Parse([string]$e.passedAt)
        if (((Get-Date) - $when).TotalSeconds -gt $TtlSec) { return $false }

        $script:ScanPassCacheAgeSec = [math]::Round(((Get-Date) - $when).TotalSeconds, 0)
        return $true
    } catch {
        return $false
    }
}

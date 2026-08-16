<#
.SYNOPSIS
    Multi-reviewer AI quality gate with fix -> re-review loop (vibe coding core).

.DESCRIPTION
    Innovative quality loop for Grok vibe coding:

      1) Static scans (optional)
      2) Reviewer panel (profile-dependent) + arbiter
      3) On blockers: implementer fixes (unless -NoFix) then re-review
      4) Writes MD+HTML report under ~/.grok/vibe-tools/reports/
      5) Diff-hash cache: identical diff+profile+model+schema that already PASSED can skip AI

    Profiles (also env VIBE_GATE_PROFILE):
      fast     - 1 reviewer (correctness), 1 round, no fix, effort medium (push / docs)
      standard - 3 reviewers, 2 rounds, fix on, effort high (commit / vibe-review)
      strict   - 3 reviewers, 3 rounds, fix on, effort high, higher turn budgets

    -AutoProfile: path-aware adjust (docs-only -> fast; sensitive paths add security on fast).

    Fail-closed: missing grok, empty/unparseable panel or arbiter output,
    or exhausted rounds still carrying blockers.
#>
[CmdletBinding()]
param(
    [switch]$NoScans,
    [string]$DiffOverride,
    [string]$Model = 'grok-via-headroom',
    # Empty = use profile default (fast=medium, standard/strict=high)
    [string]$ReasoningEffort = '',
    [int]$ProxyPort = 8787,
    # fast | standard | strict (default standard; push hook uses fast)
    # Named GateProfile (not Profile) — $Profile is a PowerShell automatic variable.
    [Alias('Profile')]
    [ValidateSet('fast', 'standard', 'strict', '')]
    [string]$GateProfile = '',
    # Adjust profile/roles from changed paths (docs-only, sensitive)
    [switch]$AutoProfile,
    # Full vibe loop (default). -NoFix = review-only panel + arbiter (no implementer).
    [switch]$NoFix,
    [ValidateRange(1, 5)]
    [int]$MaxRounds = 0,
    # Run reviewers as background jobs (faster). Off = sequential (easier debug).
    [switch]$SequentialReviewers,
    [int]$ReviewerMaxTurns = 0,
    [int]$ArbiterMaxTurns = 0,
    [int]$FixerMaxTurns = 0,
    [string]$WorkDir = '',
    # Skip diff-hash pass cache
    [switch]$NoCache,
    # Do not write report files
    [switch]$NoReport
)

$ErrorActionPreference = 'Continue'
$vibeScripts = Split-Path $MyInvocation.MyCommand.Path -Parent
$runScans = Join-Path $vibeScripts 'run-vibe-scans.ps1'
$pathParse = Join-Path $vibeScripts 'gate-path-parse.ps1'
if (-not (Test-Path -LiteralPath $pathParse)) {
    Write-Host "[GATE FAIL] missing gate-path-parse.ps1 next to grok-ai-review.ps1" -ForegroundColor Red
    exit 1
}
. $pathParse
foreach ($helperName in @('gate-schema.ps1', 'gate-review-context.ps1', 'gate-fixer-worktree.ps1')) {
    $hp = Join-Path $vibeScripts $helperName
    if (-not (Test-Path -LiteralPath $hp)) {
        Write-Host "[GATE FAIL] missing $helperName next to grok-ai-review.ps1" -ForegroundColor Red
        exit 1
    }
    . $hp
}
$progressPs1 = Join-Path $vibeScripts 'gate-progress.ps1'
if (Test-Path -LiteralPath $progressPs1) { . $progressPs1 }
$vibeRoot = Split-Path $vibeScripts -Parent
$reportsRoot = Join-Path $vibeRoot 'reports'
$cacheDir = Join-Path $vibeRoot 'cache'
$cacheFile = Join-Path $cacheDir 'gate-pass-cache.json'

function Resolve-GateProfile {
    param([string]$Name)
    $n = $Name
    if (-not $n) { $n = $env:VIBE_GATE_PROFILE }
    if (-not $n) { $n = 'standard' }
    $n = $n.ToLowerInvariant().Trim()
    if ($n -notin @('fast', 'standard', 'strict')) { $n = 'standard' }

    switch ($n) {
        'fast' {
            return @{
                Name              = 'fast'
                Roles             = @('correctness')
                MaxRounds         = 1
                NoFixDefault      = $true
                SequentialDefault = $true
                ReviewerMaxTurns  = 8
                ArbiterMaxTurns   = 6
                FixerMaxTurns     = 20
                ReasoningEffort   = 'medium'
                Description       = '1 reviewer (correctness), 1 round, no auto-fix, medium effort'
            }
        }
        'strict' {
            return @{
                Name              = 'strict'
                Roles             = @('correctness', 'security', 'simplicity')
                MaxRounds         = 3
                NoFixDefault      = $false
                SequentialDefault = $false
                ReviewerMaxTurns  = 16
                ArbiterMaxTurns   = 10
                FixerMaxTurns     = 50
                ReasoningEffort   = 'high'
                Description       = '3 reviewers, 3 rounds, fix loop, higher budgets'
            }
        }
        default {
            return @{
                Name              = 'standard'
                Roles             = @('correctness', 'security', 'simplicity')
                MaxRounds         = 2
                NoFixDefault      = $false
                SequentialDefault = $false
                ReviewerMaxTurns  = 12
                ArbiterMaxTurns   = 8
                FixerMaxTurns     = 40
                ReasoningEffort   = 'high'
                Description       = '3 reviewers, 2 rounds, fix loop'
            }
        }
    }
}

function Get-GateChangedPaths {
    param([string]$DiffOverride)
    $paths = [System.Collections.Generic.List[string]]::new()
    # Explicit DiffOverride (e.g. push range) wins over staged index noise.
    # Quoted headers and both rename sides live in Get-PathsFromDiffText.
    if (-not [string]::IsNullOrWhiteSpace($DiffOverride)) {
        $fromDiff = @(Get-PathsFromDiffText $DiffOverride)
        if ($fromDiff.Count -gt 0) {
            return $fromDiff
        }
    }
    # name-status: include deletes + rename old/new (name-only drops the old path)
    try {
        $stagedNs = @(git -c core.quotepath=false diff --cached --name-status --diff-filter=ACMRD 2>$null | Where-Object { $_ })
        foreach ($line in $stagedNs) { Add-NameStatusLineToList $paths $line }
    } catch {}
    if ($paths.Count -eq 0) {
        try {
            $wtNs = @(git -c core.quotepath=false diff --name-status --diff-filter=ACMRD 2>$null | Where-Object { $_ })
            foreach ($line in $wtNs) { Add-NameStatusLineToList $paths $line }
        } catch {}
    }
    return @($paths | Select-Object -Unique)
}

function Test-PathIsDocOnly([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $true }
    # True doc / media allowlist only — never treat *.json/*.yaml/*.yml/*.toml as docs-only
    # (workflows, compose, chart values, appsettings are gate-relevant config/IaC).
    if ($p -match '(?i)(^|/)(LICENSE|CHANGELOG|README)(\.|$)') { return $true }
    if ($p -match '(?i)(^|/)docs?/') { return $true }
    # No .lock / go.sum — lockfiles are supply-chain surface, not docs
    if ($p -match '(?i)\.(md|markdown|txt|rst|csv|svg|png|jpe?g|gif|webp|ico|drawio)$') { return $true }
    return $false
}

function Test-PathIsSensitive([string]$p) {
    if ($p -match '(?i)(^|/)(.*lock.*|go\.sum|Cargo\.lock|poetry\.lock|Gemfile\.lock|composer\.lock|pnpm-lock\.yaml|package-lock\.json|yarn\.lock)(\.|$)') {
        return $true
    }
    return [bool]($p -match '(?i)(auth|secret|pass|token|crypto|hook|install|security|credential|oauth|jwt|cert|private.?key)')
}

function Apply-PathAwareProfile {
    param($BaseProfile, [string[]]$Paths)
    $name = $BaseProfile.Name
    $roles = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($BaseProfile.Roles)) { [void]$roles.Add([string]$r) }

    if (-not $Paths -or $Paths.Count -eq 0) {
        return @{ ProfileName = $name; Roles = @($roles); Note = 'no paths' }
    }

    $allDoc = $true
    $anySensitive = $false
    foreach ($p in $Paths) {
        if (Test-PathIsSensitive $p) { $anySensitive = $true }
        if (-not (Test-PathIsDocOnly $p)) { $allDoc = $false }
    }

    $note = @()
    if ($allDoc -and -not $anySensitive -and $name -ne 'strict') {
        $name = 'fast'
        $roles.Clear()
        [void]$roles.Add('correctness')
        $note += 'docs-only->fast'
    }
    if ($anySensitive -and $roles -notcontains 'security') {
        [void]$roles.Add('security')
        $note += 'sensitive+security'
    }
    return @{
        ProfileName = $name
        Roles       = @($roles)
        Note        = ($note -join ', ')
        Sensitive   = $anySensitive
    }
}

# Resolve base profile name first
$baseName = $GateProfile
if (-not $baseName) { $baseName = $env:VIBE_GATE_PROFILE }
if (-not $baseName) { $baseName = 'standard' }

$pathNote = ''
if ($AutoProfile -or $env:VIBE_GATE_AUTO_PROFILE -eq '1') {
    $changedPaths = Get-GateChangedPaths -DiffOverride $DiffOverride
    $tmpProf = Resolve-GateProfile -Name $baseName
    $adj = Apply-PathAwareProfile -BaseProfile $tmpProf -Paths $changedPaths
    if ($adj.ProfileName -ne $baseName) {
        Write-Host ("[AutoProfile] {0} -> {1} ({2})" -f $baseName, $adj.ProfileName, $adj.Note) -ForegroundColor DarkCyan
        $baseName = $adj.ProfileName
    } elseif ($adj.Note) {
        Write-Host ("[AutoProfile] keep {0} ({1})" -f $baseName, $adj.Note) -ForegroundColor DarkCyan
    }
    $pathNote = $adj.Note
    $script:PathAwareRoles = @($adj.Roles)
    $script:PathAwareSensitive = [bool]$adj.Sensitive
} else {
    $script:PathAwareRoles = $null
    $script:PathAwareSensitive = $false
}

$script:ResolvedProfile = Resolve-GateProfile -Name $baseName
if ($script:PathAwareRoles -and $script:PathAwareRoles.Count -gt 0) {
    $script:ResolvedProfile.Roles = @($script:PathAwareRoles)
}
if ($MaxRounds -le 0) { $MaxRounds = [int]$script:ResolvedProfile.MaxRounds }
if ($ReviewerMaxTurns -le 0) { $ReviewerMaxTurns = [int]$script:ResolvedProfile.ReviewerMaxTurns }
if ($ArbiterMaxTurns -le 0) { $ArbiterMaxTurns = [int]$script:ResolvedProfile.ArbiterMaxTurns }
if ($FixerMaxTurns -le 0) { $FixerMaxTurns = [int]$script:ResolvedProfile.FixerMaxTurns }
if ([string]::IsNullOrWhiteSpace($ReasoningEffort)) {
    $ReasoningEffort = [string]$script:ResolvedProfile.ReasoningEffort
    if (-not $ReasoningEffort) { $ReasoningEffort = 'high' }
}
# Large diffs: compress into brief (below). Slight turn headroom for panel JSON only.
if (-not $PSBoundParameters.ContainsKey('ReviewerMaxTurns')) {
    try {
        $probe = git diff --cached --no-color 2>$null
        if (-not $probe) { $probe = git diff --no-color 2>$null }
        $n = if ($probe) { $probe.Length } else { 0 }
        if ($n -gt 60000 -and $ReviewerMaxTurns -lt 16) { $ReviewerMaxTurns = 16 }
        if ($n -gt 60000 -and $ArbiterMaxTurns -lt 10) { $ArbiterMaxTurns = 10 }
    } catch {}
}
if (-not $PSBoundParameters.ContainsKey('NoFix') -and $script:ResolvedProfile.NoFixDefault) {
    $NoFix = $true
}
if (-not $PSBoundParameters.ContainsKey('SequentialReviewers') -and $script:ResolvedProfile.SequentialDefault) {
    $SequentialReviewers = $true
}
# Multi-role (e.g. fast + security on hook/install) must not serialize; NOW stays silent.
if (-not $PSBoundParameters.ContainsKey('SequentialReviewers') -and @($script:ResolvedProfile.Roles).Count -gt 1) {
    $SequentialReviewers = $false
}
if ($script:PathAwareSensitive -and [string]$ReasoningEffort -eq 'medium') {
    $ReasoningEffort = 'high'
    Write-Host '[AutoProfile] sensitive paths -> high effort' -ForegroundColor DarkCyan
}
if ($env:VIBE_GATE_NO_CACHE -eq '1') { $NoCache = $true }

$script:GateRun = [ordered]@{
    startedAt     = (Get-Date -Format 'o')
    profile       = $script:ResolvedProfile.Name
    model         = $Model
    effort        = $ReasoningEffort
    autoProfile   = [bool]$AutoProfile
    pathNote      = $pathNote
    noFix         = [bool]$NoFix
    maxRounds     = $MaxRounds
    roles         = @($script:ResolvedProfile.Roles)
    rounds        = @()
    diffHash      = ''
    cacheHit      = $false
    verdict       = ''
    passed        = $false
    elapsedSec    = 0
    workDir       = ''
    reportDir     = ''
    failReason    = ''
    schemaVersion = $(Get-GateSchemaVersion)
    promptChars   = 0
    outputChars   = 0
    tokenEstimate = 0
}

# --- helpers ---

function Write-GateFail([string]$msg) {
    Write-Host ""
    Write-Host "[GATE FAIL] $msg" -ForegroundColor Red
    Write-Host "Commit/push blocked. Emergency only: git commit|push --no-verify" -ForegroundColor DarkGray
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        Write-GateProgress ("FAIL: {0}" -f $msg) -Now ("Blocked: $msg") -Phase 'fail'
    }
    if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
        if ("$script:GateNow" -notmatch 'GATE DONE') {
            Write-GateDone -Summary $msg
        }
    }
}

function Write-Phase([string]$msg) {
    Write-Host ""
    Write-Host $msg -ForegroundColor Yellow
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        Write-GateProgress $msg -Now $msg -Phase $msg
    }
}

function Test-PortListening([int]$p) {
    try {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        return $null -ne $c
    } catch {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect('127.0.0.1', $p, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(400)
            if ($ok -and $client.Connected) { $client.Close(); return $true }
            $client.Close(); return $false
        } catch { return $false }
    }
}

function Resolve-GrokExe {
    $cmd = Get-Command grok -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $fallback = Join-Path $env:USERPROFILE '.grok\bin\grok.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

function Test-VanillaHatchEndpoint {
    # Quoted table + non-loopback https base_url. Listing `grok models` is not enough.
    $cfg = Join-Path $env:USERPROFILE '.grok\config.toml'
    if (-not (Test-Path -LiteralPath $cfg)) { return $false }
    $txt = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($txt)) { return $false }
    $sec = [regex]::Match($txt, '(?ms)^\s*\[model\."grok-4\.6-direct"\]\s*$(.*?)(?=^\s*\[|\z)')
    if (-not $sec.Success) { return $false }
    $url = [regex]::Match($sec.Groups[1].Value, 'base_url\s*=\s*"(https://[^"]+)"')
    if (-not $url.Success) { return $false }
    return ($url.Groups[1].Value -notmatch '127\.0\.0\.1|localhost')
}

function Test-ReviewPreflight {
    param([string]$ModelName, [int]$Port)
    $exe = Resolve-GrokExe
    if (-not $exe) {
        Write-GateFail "grok.exe not found on PATH or ~/.grok/bin."
        return $null
    }
    $resolvedModel = $ModelName
    $hatch = 'grok-4.6-direct'
    $needsProxy = ($ModelName -match 'headroom|8787') -or ($ModelName -eq 'grok-4.6')
    if ($needsProxy) {
        if (-not (Test-PortListening $Port)) {
            $startGrok = Join-Path $env:USERPROFILE '.grok\token-saving\scripts\start-grok.ps1'
            if (Test-Path -LiteralPath $startGrok) {
                Write-Host "Headroom proxy not on :$Port - starting via start-grok -ProxyOnly ..." -ForegroundColor Yellow
                try { & $startGrok -ProxyOnly 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } } catch {}
            }
        }
        if (-not (Test-PortListening $Port)) {
            # Unquoted [model.grok-4.6-direct] never registers (TOML nest).
            # Require quoted table with its own official https base_url (not loopback).
            if (-not (Test-VanillaHatchEndpoint)) {
                Write-GateFail "Headroom proxy down and vanilla hatch '$hatch' has no official base_url. Quote [model.`"$hatch`"] in ~/.grok/config.toml (re-run installer). Do not use grok-4.6 (Headroom)."
                return $null
            }
            Write-Host "Proxy still down - falling back to model $hatch (official endpoint)." -ForegroundColor Yellow
            $resolvedModel = $hatch
        }
    }
    return @{ Exe = $exe; Model = $resolvedModel }
}

function Get-MachineVerdict([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $verdictMatches = [regex]::Matches($text, '(?im)^\s*VERDICT\s*:\s*(STRONG_APPROVE|APPROVE_WITH_CHANGES|APPROVE|BLOCK)\s*$')
    if ($verdictMatches.Count -gt 0) {
        return $verdictMatches[$verdictMatches.Count - 1].Groups[1].Value.ToUpperInvariant()
    }
    return $null
}

function ConvertFrom-JsonLoose([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    # Prefer fenced json block
    $m = [regex]::Match($text, '(?s)```(?:json)?\s*(\{.*?\})\s*```')
    $candidates = @()
    if ($m.Success) { $candidates += $m.Groups[1].Value }
    # Whole text / last balanced-ish object
    $candidates += $text.Trim()
    $objMatch = [regex]::Matches($text, '(?s)\{(?:[^{}]|(?<open>\{)|(?<-open>\}))+(?(open)(?!))\}')
    if ($objMatch.Count -gt 0) {
        $candidates += $objMatch[$objMatch.Count - 1].Value
    }
    foreach ($c in $candidates) {
        try {
            return ($c | ConvertFrom-Json -ErrorAction Stop)
        } catch {}
    }
    return $null
}

function Limit-DiffText([string]$diff, [int]$maxChars = 160000) {
    if (-not $diff) { return $diff }
    if ($diff.Length -le $maxChars) { return $diff }
    $head = $diff.Substring(0, [int]($maxChars * 0.7))
    $tail = $diff.Substring($diff.Length - [int]($maxChars * 0.25))
    return $head + "`n`n... [diff truncated for gate size] ...`n`n" + $tail
}

function Get-DiffFileStats([string]$diff) {
    # Returns list of @{ Path; Added; Deleted; Hunk }
    $files = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($diff)) { return @() }
    $cur = $null
    $hunk = New-Object System.Text.StringBuilder
    $add = 0; $del = 0
    foreach ($rawLine in ($diff -split "`n")) {
        $line = $rawLine.TrimEnd("`r")
        $sides = Split-DiffGitPaths $line
        if ($sides) {
            if ($null -ne $cur) {
                [void]$files.Add([pscustomobject]@{
                        Path    = $cur
                        Added   = $add
                        Deleted = $del
                        Hunk    = $hunk.ToString()
                    })
            }
            $cur = if ($sides.B -and $sides.B -ne '/dev/null') { $sides.B } else { $sides.A }
            $hunk = New-Object System.Text.StringBuilder
            $add = 0; $del = 0
            continue
        }
        if ($line -match '^\+\+\+ (?:"b/(.+)"|b/(.+))$') {
            $nb = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            if ($nb) { $cur = $nb.Trim() }
            continue
        }
        if ($line -match '^--- /dev/null') { continue }
        if ($null -eq $cur) { continue }
        [void]$hunk.AppendLine($line)
        if ($line -match '^\+[^+]') { $add++ }
        elseif ($line -match '^-[^-]') { $del++ }
    }
    if ($null -ne $cur) {
        [void]$files.Add([pscustomobject]@{
                Path    = $cur
                Added   = $add
                Deleted = $del
                Hunk    = $hunk.ToString()
            })
    }
    return @($files)
}

function Compress-DiffForReview {
    <#
      Large diffs burn reviewer max-turns (agents try to chunk the blob).
      Build a bounded brief: file list + hotspots + per-file sample hunks.
    #>
    param(
        [string]$Diff,
        [int]$MaxChars = 48000,
        [int]$PerFileHunkChars = 2800,
        [int]$MaxFilesWithHunks = 40
    )
    if ([string]::IsNullOrWhiteSpace($Diff)) { return $Diff }
    if ($Diff.Length -le $MaxChars) {
        return $Diff
    }

    $files = @(Get-DiffFileStats $Diff)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('### GATE DIFF BRIEF (compressed — full raw diff omitted to fit turn budget)')
    [void]$sb.AppendLine(('Original diff size: {0} chars across {1} file(s).' -f $Diff.Length, $files.Count))
    [void]$sb.AppendLine('Review THIS brief only. Do NOT open tools to re-read or chunk the diff. Emit JSON immediately.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## FILES CHANGED')
    foreach ($f in $files) {
        [void]$sb.AppendLine(('- {0}  (+{1}/-{2})' -f $f.Path, $f.Added, $f.Deleted))
    }

    # Hotspot lines (secrets / dangerous APIs) from added lines
    $hotPatterns = @(
        '(?i)(api[_-]?key|secret|password|token|bearer|authorization)\s*[=:]\s*\S+',
        '(?i)(AKIA[0-9A-Z]{16}|xai-[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,})',
        '(?i)(Invoke-Expression|DownloadString|FromBase64String|eval\(|child_process|exec\(|os\.system)',
        '(?i)(password_hash|crypto\.createCipher|MD5|sha1\()',
        '(?i)(bypassPermissions|always-approve|--no-verify)'
    )
    $hots = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        $ln = 0
        foreach ($line in ($f.Hunk -split "`n")) {
            $ln++
            if ($line -notmatch '^\+[^+]') { continue }
            $body = $line.Substring(1)
            foreach ($pat in $hotPatterns) {
                if ($body -match $pat) {
                    # Redact secret-looking values before shipping brief to the LLM
                    $snip = if ($body.Length -gt 120) { $body.Substring(0, 120) + '...' } else { $body }
                    $snip = [regex]::Replace($snip, '(?i)(xai-|sk-|ghp_|github_pat_|AKIA)[A-Za-z0-9/+=_-]{8,}', '$1[REDACTED]')
                    $snip = [regex]::Replace($snip, '(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*\S+', '$1=[REDACTED]')
                    [void]$hots.Add(('{0}: {1}' -f $f.Path, $snip))
                    break
                }
            }
            if ($hots.Count -ge 40) { break }
        }
        if ($hots.Count -ge 40) { break }
    }
    if ($hots.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## HOTSPOT LINES (heuristic)')
        foreach ($h in $hots) { [void]$sb.AppendLine(('- {0}' -f $h)) }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## DIFF SAMPLES (truncated per file)')
    # Prefer security-sensitive + largest files first
    $ordered = $files | Sort-Object {
        $score = $_.Added + $_.Deleted
        if ($_.Path -match '(?i)(auth|secret|pass|token|crypto|hook|install|review|scan|security)') { $score + 500 } else { $score }
    } -Descending

    $n = 0
    foreach ($f in $ordered) {
        if ($n -ge $MaxFilesWithHunks) { break }
        $n++
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('### {0}  (+{1}/-{2})' -f $f.Path, $f.Added, $f.Deleted))
        $h = [string]$f.Hunk
        if ($h.Length -gt $PerFileHunkChars) {
            $h = $h.Substring(0, $PerFileHunkChars) + "`n... [hunk truncated] ..."
        }
        [void]$sb.AppendLine($h)
        if ($sb.Length -gt $MaxChars) { break }
    }

    if ($files.Count -gt $MaxFilesWithHunks) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('... {0} more file(s) listed above without hunk samples.' -f ($files.Count - $MaxFilesWithHunks)))
    }

    $out = $sb.ToString()
    if ($out.Length -gt ($MaxChars + 4000)) {
        $out = $out.Substring(0, $MaxChars) + "`n... [brief hard-capped] ..."
    }
    return $out
}

function ConvertTo-SinglePatchText($raw) {
    # git.exe on Windows PowerShell 5.1 returns string[] for multi-line patches.
    # Returning the array makes .Length = line count and briefs collapse to a stub.
    if ($null -eq $raw) { return $null }
    $s = if ($raw -is [string]) { $raw } else { (@($raw) | ForEach-Object { "$_" }) -join "`n" }
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

function Get-GitDiffText {
    param([string]$Override)
    if ($Override) { return (ConvertTo-SinglePatchText $Override) }
    $staged = ConvertTo-SinglePatchText (git diff --cached --no-color 2>$null)
    if ($staged) {
        Write-Host "Using staged diff (what will be committed)." -ForegroundColor Green
        return $staged
    }
    $wt = ConvertTo-SinglePatchText (git diff --no-color 2>$null)
    if ($wt) {
        Write-Host "Using working tree diff (no staged changes)." -ForegroundColor Yellow
        return $wt
    }
    Write-Host "No changes detected - limited whole-tree review context." -ForegroundColor DarkGray
    return "No diff available. Review the current project state for quality, security, and incomplete features."
}

function Save-Text([string]$Path, [string]$Text) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Invoke-GrokHeadless {
    param(
        [Parameter(Mandatory)][string]$GrokExe,
        [Parameter(Mandatory)][string]$ModelName,
        [Parameter(Mandatory)][string]$PromptFile,
        [Parameter(Mandatory)][string]$Label,
        [string]$Effort = 'high',
        [int]$MaxTurns = 12,
        [switch]$AllowWrites,
        [string]$OutLog,
        [string]$WorkingDirectory = ''
    )

    $argList = [System.Collections.Generic.List[string]]::new()
    [void]$argList.Add('--prompt-file')
    [void]$argList.Add($PromptFile)
    [void]$argList.Add('-m')
    [void]$argList.Add($ModelName)
    [void]$argList.Add('--reasoning-effort')
    [void]$argList.Add($Effort)
    [void]$argList.Add('--max-turns')
    [void]$argList.Add("$MaxTurns")
    [void]$argList.Add('--permission-mode')
    [void]$argList.Add('bypassPermissions')
    # Headless single-shot style still allows multi-turn agent loop via max-turns
    if ($AllowWrites) {
        [void]$argList.Add('--yolo')
    } else {
        # Read-oriented reviewers: no edits / no shell side effects
        [void]$argList.Add('--disallowed-tools')
        [void]$argList.Add('search_replace,write,Write,run_terminal_command,run_terminal_cmd,Bash,bash')
    }

    $writeFlag = [bool]$AllowWrites
    Write-Host ("  -> {0} (model={1}, turns<={2}, write={3})" -f $Label, $ModelName, $MaxTurns, $writeFlag) -ForegroundColor DarkGray
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        Write-GateProgress ("start {0} model={1} turns<={2}" -f $Label, $ModelName, $MaxTurns)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = $null
    $code = 0
    $pushed = $false
    try {
        if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushed = $true
        }
        $output = & $GrokExe @($argList.ToArray()) 2>&1
        $code = $LASTEXITCODE
    } catch {
        $sw.Stop()
        if ($pushed) { Pop-Location }
        return @{ Ok = $false; Text = "$_"; ExitCode = -1; Seconds = $sw.Elapsed.TotalSeconds }
    }
    if ($pushed) { Pop-Location }
    $sw.Stop()
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        Write-GateProgress ("done {0} {1:n0}s exit={2}" -f $Label, $sw.Elapsed.TotalSeconds, $code)
    }
    $text = if ($output) { ($output | ForEach-Object { "$_" }) -join "`n" } else { '' }
    if ($OutLog) { Save-Text $OutLog $text }
    try {
        $pc = 0
        if (Test-Path -LiteralPath $PromptFile) { $pc = [int](Get-Item -LiteralPath $PromptFile).Length }
        $script:GateRun.promptChars = [int]$script:GateRun.promptChars + $pc
        $script:GateRun.outputChars = [int]$script:GateRun.outputChars + $text.Length
        $script:GateRun.tokenEstimate = [int][math]::Round(($script:GateRun.promptChars + $script:GateRun.outputChars) / 4.0)
    } catch {}
    $ok = ($code -eq 0 -or $null -eq $code) -and -not [string]::IsNullOrWhiteSpace($text)
    return @{ Ok = $ok; Text = $text; ExitCode = $code; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function New-ReviewerPrompt {
    param([string]$Role, [string]$DiffText, [int]$Round, [string]$PriorBlockers)
    $focusCorrectness = @(
        'ROLE: CORRECTNESS reviewer (bugs, logic, edge cases, races, error handling, tests).',
        'You vote BLOCK only for real correctness defects that would break behavior or corrupt data.',
        'Style/nits = advisory. Missing nice-to-have tests for trivial changes = advisory unless risk is high.'
    ) -join "`n"
    $focusSecurity = @(
        'ROLE: SECURITY reviewer (secrets, injection, authz, path traversal, unsafe deserialization, SSRF, supply chain).',
        'You vote BLOCK for exploitable or secret-leak issues. Theoretical hardening without exploit path = advisory.'
    ) -join "`n"
    $focusSimplicity = @(
        'ROLE: SIMPLICITY / QUALITY reviewer (duplication, dead code, unwired features, complexity, naming, incomplete stubs).',
        'You vote BLOCK for unwired/half-implemented features, dead dangerous paths, or complexity that hides bugs.',
        'Pure style preference = advisory.'
    ) -join "`n"
    $focus = switch ($Role) {
        'correctness' { $focusCorrectness }
        'security' { $focusSecurity }
        'simplicity' { $focusSimplicity }
        default { 'ROLE: general reviewer.' }
    }

    $prior = ''
    if ($PriorBlockers) {
        $prior = "`nPRIOR ROUND BLOCKERS (verify fixed or still open):`n$PriorBlockers`n"
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("You are one member of a 3-reviewer quality panel for a git gate (round $Round).")
    [void]$sb.AppendLine($focus)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Rules:')
    [void]$sb.AppendLine('- Be specific: file path + line when possible.')
    [void]$sb.AppendLine('- severity must be exactly "blocker" or "advisory".')
    [void]$sb.AppendLine('- Do NOT edit files. Tools that write or run shell are disabled.')
    [void]$sb.AppendLine('- Do NOT spend turns chunking, grepping, or re-reading the diff. The brief below is complete.')
    [void]$sb.AppendLine('- Emit the JSON object as your FIRST substantive response (ideally only response).')
    [void]$sb.AppendLine('- Independent judgment - do not soften blockers to be nice.')
    [void]$sb.AppendLine('- vote must be one of: STRONG_APPROVE | APPROVE | APPROVE_WITH_CHANGES | BLOCK')
    [void]$sb.AppendLine('  - BLOCK if you have any blocker findings')
    [void]$sb.AppendLine('  - APPROVE_WITH_CHANGES if only advisories')
    [void]$sb.AppendLine('  - APPROVE / STRONG_APPROVE if clean')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Return ONLY a single JSON object (no markdown fences if possible) with this shape:')
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine("  `"reviewer_id`": `"$Role`",")
    [void]$sb.AppendLine('  "summary": "one paragraph",')
    [void]$sb.AppendLine('  "vote": "BLOCK|APPROVE|APPROVE_WITH_CHANGES|STRONG_APPROVE",')
    [void]$sb.AppendLine('  "findings": [')
    [void]$sb.AppendLine('    {')
    [void]$sb.AppendLine("      `"id`": `"$Role-1`",")
    [void]$sb.AppendLine('      "severity": "blocker|advisory",')
    [void]$sb.AppendLine('      "file": "path or empty",')
    [void]$sb.AppendLine('      "line": 0,')
    [void]$sb.AppendLine('      "title": "short",')
    [void]$sb.AppendLine('      "detail": "why it matters",')
    [void]$sb.AppendLine('      "fix_hint": "how to fix"')
    [void]$sb.AppendLine('    }')
    [void]$sb.AppendLine('  ]')
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('If no findings, use "findings": [].')
    if ($prior) { [void]$sb.AppendLine($prior) }
    [void]$sb.AppendLine('DIFF/CONTEXT:')
    [void]$sb.AppendLine($DiffText)
    return $sb.ToString()
}

function New-ArbiterPrompt {
    param([string]$DiffText, [string]$PanelJson, [int]$Round)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("You are the ARBITER for a 3-reviewer quality panel (round $Round).")
    [void]$sb.AppendLine('Three specialized reviewers (correctness, security, simplicity) submitted independent findings and votes.')
    [void]$sb.AppendLine('Your job:')
    [void]$sb.AppendLine('1) Merge duplicate findings.')
    [void]$sb.AppendLine('2) RESOLVE DISPUTES on severity: when reviewers disagree blocker vs advisory, decide with explicit rationale.')
    [void]$sb.AppendLine('   - Prefer BLOCKER when a plausible production break or security issue exists.')
    [void]$sb.AppendLine('   - Never downgrade in-support data corruption, encoding/round-trip loss, or a fail-closed bypass to advisory.')
    [void]$sb.AppendLine('   - Prefer ADVISORY for style, optional refactors, or speculative issues without a clear failure mode.')
    [void]$sb.AppendLine('   - Panels may have 1-3 reviewers (fast can be correctness+security). Do not require three votes.')
    [void]$sb.AppendLine('3) Produce a final gate verdict.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Return ONLY JSON:')
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine('  "verdict": "STRONG_APPROVE|APPROVE|APPROVE_WITH_CHANGES|BLOCK",')
    [void]$sb.AppendLine('  "rationale": "short explanation of the consensus",')
    [void]$sb.AppendLine('  "disputes_resolved": [')
    [void]$sb.AppendLine('    {"topic": "...", "resolution": "blocker|advisory", "rationale": "..."}')
    [void]$sb.AppendLine('  ],')
    [void]$sb.AppendLine('  "blockers": [')
    [void]$sb.AppendLine('    {"id": "...", "file": "...", "line": 0, "title": "...", "detail": "...", "fix_hint": "...", "sources": ["correctness","security"]}')
    [void]$sb.AppendLine('  ],')
    [void]$sb.AppendLine('  "advisories": [')
    [void]$sb.AppendLine('    {"id": "...", "file": "...", "line": 0, "title": "...", "detail": "...", "fix_hint": "...", "sources": ["simplicity"]}')
    [void]$sb.AppendLine('  ]')
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Rules:')
    [void]$sb.AppendLine('- verdict MUST be BLOCK if blockers is non-empty.')
    [void]$sb.AppendLine('- verdict APPROVE_WITH_CHANGES if only advisories.')
    [void]$sb.AppendLine('- STRONG_APPROVE only if all three votes were approve-class and no advisories worth tracking.')
    [void]$sb.AppendLine('- Do not invent issues not grounded in reviewer findings or the diff brief.')
    [void]$sb.AppendLine('- Do not edit files or run shell. Emit JSON immediately; do not re-chunk the brief.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('PANEL OUTPUTS:')
    [void]$sb.AppendLine($PanelJson)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('DIFF/CONTEXT:')
    [void]$sb.AppendLine($DiffText)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Final line after the JSON (required):')
    [void]$sb.AppendLine('VERDICT: <same as verdict field>')
    return $sb.ToString()
}

function New-FixerPrompt {
    param([string]$DiffText, [string]$BlockersJson, [int]$Round)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("You are the IMPLEMENTER in a vibe-coding quality loop (round $Round).")
    [void]$sb.AppendLine('An arbiter panel found BLOCKER issues that must be fixed before commit.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Your job:')
    [void]$sb.AppendLine('1) Fix EVERY blocker in the working tree using your edit tools.')
    [void]$sb.AppendLine('2) Do not fix by deleting features unless the feature is clearly dead/unwired junk.')
    [void]$sb.AppendLine('3) Keep changes minimal and correct.')
    [void]$sb.AppendLine('4) After edits, briefly summarize what you changed.')
    [void]$sb.AppendLine('5) Do NOT commit. Do NOT push. Staging is handled by the gate script.')
    [void]$sb.AppendLine('6) Cwd may be an isolated git worktree of HEAD + staged patch. Edit only files here; do not touch other checkouts.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('BLOCKERS (JSON):')
    [void]$sb.AppendLine($BlockersJson)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('ORIGINAL DIFF (context - files may already partially match):')
    [void]$sb.AppendLine($DiffText)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('When done, end with:')
    [void]$sb.AppendLine('FIXES_APPLIED: <count>')
    [void]$sb.AppendLine('VERDICT: FIXED')
    return $sb.ToString()
}

function Get-DiffHash([string]$text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-RepoCacheKey {
    $root = ''
    try { $root = (git rev-parse --show-toplevel 2>$null) } catch {}
    if (-not $root) { $root = (Get-Location).Path }
    return $root.ToLowerInvariant()
}

function Test-GatePassCache {
    param([string]$DiffHash, [string]$ProfileName, [string]$ModelName)
    if ($NoCache) { return $null }
    if (-not (Test-Path -LiteralPath $cacheFile)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json
    } catch { return $null }
    $repo = Get-RepoCacheKey
    $entries = @($cache.entries)
    $wantSchema = Get-GateSchemaVersion
    foreach ($e in $entries) {
        $gotSchema = 0
        try { $gotSchema = [int]$e.schemaVersion } catch { $gotSchema = 0 }
        if ($gotSchema -ne $wantSchema) { continue }
        if ($e.diffHash -eq $DiffHash -and $e.profile -eq $ProfileName -and $e.model -eq $ModelName -and $e.repo -eq $repo -and $e.passed -eq $true) {
            return $e
        }
    }
    return $null
}

function Save-GatePassCache {
    param([string]$DiffHash, [string]$ProfileName, [string]$ModelName, [string]$Verdict, [string]$ReportDir)
    if ($NoCache) { return }
    try {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $cache = @{ version = 2; entries = @() }
        if (Test-Path -LiteralPath $cacheFile) {
            try { $cache = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json } catch {}
        }
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($e in @($cache.entries)) {
            if ($null -eq $e) { continue }
            # drop matching key so we replace
            if (-not ($e.diffHash -eq $DiffHash -and $e.profile -eq $ProfileName -and $e.model -eq $ModelName -and $e.repo -eq (Get-RepoCacheKey))) {
                [void]$list.Add($e)
            }
        }
        $schema = 0
        if (Get-Command Get-GateSchemaVersion -ErrorAction SilentlyContinue) { $schema = Get-GateSchemaVersion }
        [void]$list.Add([pscustomobject]@{
                diffHash      = $DiffHash
                profile       = $ProfileName
                model         = $ModelName
                repo          = Get-RepoCacheKey
                schemaVersion = $schema
                passed        = $true
                verdict       = $Verdict
                at            = (Get-Date -Format 'o')
                reportDir     = $ReportDir
            })
        # keep last 40
        while ($list.Count -gt 40) { $list.RemoveAt(0) }
        $out = @{ version = 2; entries = @($list.ToArray()) } | ConvertTo-Json -Depth 6
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($cacheFile, $out, $utf8)
    } catch {}
}

function Write-GateReport {
    param([hashtable]$Run, [int]$ExitCode)
    if ($NoReport) { return $null }
    try {
        New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $short = if ($Run.diffHash) { $Run.diffHash.Substring(0, 8) } else { 'nodiff' }
        $dir = Join-Path $reportsRoot ("{0}-{1}-{2}" -f $stamp, $Run.profile, $short)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $Run.reportDir = $dir
        $Run.finishedAt = (Get-Date -Format 'o')
        $Run.exitCode = $ExitCode

        $jsonPath = Join-Path $dir 'report.json'
        $mdPath = Join-Path $dir 'report.md'
        $htmlPath = Join-Path $dir 'report.html'
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($jsonPath, ($Run | ConvertTo-Json -Depth 12), $utf8)

        $md = New-Object System.Text.StringBuilder
        [void]$md.AppendLine('# Vibe gate report')
        [void]$md.AppendLine('')
        [void]$md.AppendLine(("- **Verdict:** {0}" -f $(if ($Run.verdict) { $Run.verdict } else { 'n/a' })))
        [void]$md.AppendLine(("- **Passed:** {0}" -f $Run.passed))
        [void]$md.AppendLine(("- **Profile:** {0}" -f $Run.profile))
        [void]$md.AppendLine(("- **Model:** {0}" -f $Run.model))
        [void]$md.AppendLine(("- **Elapsed:** {0}s" -f $Run.elapsedSec))
        [void]$md.AppendLine(("- **Token estimate:** ~{0} (prompt {1} + output {2} chars / 4)" -f $Run.tokenEstimate, $Run.promptChars, $Run.outputChars))
        [void]$md.AppendLine(("- **Gate schema:** {0}" -f $Run.schemaVersion))
        [void]$md.AppendLine(('- **Diff hash:** `{0}`' -f $Run.diffHash))
        [void]$md.AppendLine(("- **Cache hit:** {0}" -f $Run.cacheHit))
        [void]$md.AppendLine(("- **NoFix:** {0}" -f $Run.noFix))
        [void]$md.AppendLine(("- **Roles:** {0}" -f ($Run.roles -join ', ')))
        [void]$md.AppendLine(('- **Work dir:** `{0}`' -f $Run.workDir))
        if ($Run.failReason) { [void]$md.AppendLine(("- **Fail reason:** {0}" -f $Run.failReason)) }
        [void]$md.AppendLine('')
        $ri = 0
        foreach ($round in @($Run.rounds)) {
            $ri++
            [void]$md.AppendLine(("## Round {0}" -f $ri))
            [void]$md.AppendLine('')
            if ($round.panelVotes) {
                [void]$md.AppendLine('### Panel votes')
                foreach ($v in @($round.panelVotes)) {
                    [void]$md.AppendLine(("- **{0}:** {1} ({2} findings)" -f $v.role, $v.vote, $v.findings))
                }
                [void]$md.AppendLine('')
            }
            if ($round.verdict) {
                [void]$md.AppendLine(("- Arbiter verdict: **{0}**" -f $round.verdict))
                if ($round.rationale) { [void]$md.AppendLine(("  - {0}" -f $round.rationale)) }
            }
            if ($round.blockers) {
                [void]$md.AppendLine('')
                [void]$md.AppendLine('### Blockers')
                foreach ($b in @($round.blockers)) {
                    [void]$md.AppendLine(('- `{0}` {1}:{2} - {3}' -f $b.id, $b.file, $b.line, $b.title))
                    if ($b.detail) { [void]$md.AppendLine(("  - {0}" -f $b.detail)) }
                    if ($b.fix_hint) { [void]$md.AppendLine(("  - fix: {0}" -f $b.fix_hint)) }
                }
            }
            if ($round.advisories) {
                [void]$md.AppendLine('')
                [void]$md.AppendLine('### Advisories')
                foreach ($a in @($round.advisories)) {
                    [void]$md.AppendLine(('- `{0}` - {1}' -f $a.id, $a.title))
                }
            }
            if ($round.disputes) {
                [void]$md.AppendLine('')
                [void]$md.AppendLine('### Disputes resolved')
                foreach ($d in @($round.disputes)) {
                    [void]$md.AppendLine(("- {0} -> **{1}**: {2}" -f $d.topic, $d.resolution, $d.rationale))
                }
            }
            if ($round.fixerOk -ne $null) {
                [void]$md.AppendLine('')
                [void]$md.AppendLine(("- Fixer ok: {0} ({1}s)" -f $round.fixerOk, $round.fixerSeconds))
            }
            [void]$md.AppendLine('')
        }
        $mdText = $md.ToString()
        [System.IO.File]::WriteAllText($mdPath, $mdText, $utf8)

        $esc = [System.Net.WebUtility]::HtmlEncode($mdText)
        $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Vibe gate report</title>
<style>
body{font-family:ui-sans-serif,system-ui,Segoe UI,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem;line-height:1.45;color:#111}
pre{white-space:pre-wrap;background:#f6f8fa;padding:1rem;border-radius:8px}
.ok{color:#0a0}.bad{color:#a00}
h1{font-size:1.4rem}
</style></head>
<body>
<h1>Vibe gate report <span class="$(if($Run.passed){'ok'}else{'bad'})">$(if($Run.passed){'PASSED'}else{'FAILED'})</span></h1>
<p>Profile <b>$([System.Net.WebUtility]::HtmlEncode([string]$Run.profile))</b> · Verdict <b>$([System.Net.WebUtility]::HtmlEncode([string]$Run.verdict))</b> · $([System.Net.WebUtility]::HtmlEncode([string]$Run.elapsedSec))s</p>
<pre>$esc</pre>
</body></html>
"@
        [System.IO.File]::WriteAllText($htmlPath, $html, $utf8)

        # latest pointers
        Copy-Item $mdPath (Join-Path $reportsRoot 'latest.md') -Force
        Copy-Item $htmlPath (Join-Path $reportsRoot 'latest.html') -Force
        Copy-Item $jsonPath (Join-Path $reportsRoot 'latest.json') -Force

        Write-Host ""
        Write-Host "Report: $mdPath" -ForegroundColor Cyan
        Write-Host "        $htmlPath" -ForegroundColor Cyan
        Write-Host "Latest: $(Join-Path $reportsRoot 'latest.md')" -ForegroundColor DarkCyan
        return $dir
    } catch {
        Write-Host "Report write failed: $_" -ForegroundColor DarkYellow
        return $null
    }
}

function Publish-ReviewerVoteNow {
    param(
        [string]$Role,
        $Result,
        [string]$WaitingOn = ''
    )
    if (-not $script:VoteNowPublished) { $script:VoteNowPublished = @{} }
    if ($script:VoteNowPublished.ContainsKey($Role)) { return }
    $voteStr = 'FAIL'
    $reason = 'no parseable vote'
    $fc = 0
    if ($Result -and $Result.Ok) {
        $obj = ConvertFrom-JsonLoose $Result.Text
        if ($obj) {
            if (-not $obj.reviewer_id) { $obj | Add-Member -NotePropertyName reviewer_id -NotePropertyValue $Role -Force }
            $obj = Normalize-ReviewerVote $obj
        }
        if ($obj) {
            $voteStr = "$($obj.vote)"
            $fc = @($obj.findings).Count
            $reason = ''
            try { $reason = ([string]$obj.summary).Trim() } catch { $reason = '' }
            if (-not $reason) {
                $reason = ((@($obj.findings | ForEach-Object {
                                if ($_.title) { [string]$_.title } else { $null }
                            } | Where-Object { $_ } | Select-Object -First 3)) -join '; ')
            }
            $reason = ($reason -replace '[\r\n]+', ' ').Trim()
        }
    }
    if ($reason -and $reason.Length -gt 160) { $reason = $reason.Substring(0, 157) + '...' }
    $evt = if ($reason) {
        '{0}: {1} ({2} finding(s)) - {3}' -f $Role, $voteStr, $fc, $reason
    } else {
        '{0}: {1} ({2} finding(s))' -f $Role, $voteStr, $fc
    }
    $now = $evt
    if ($WaitingOn) { $now = '{0} | waiting: {1}' -f $evt, $WaitingOn }
    Write-Host ("    vote={0} findings={1}" -f $voteStr, $fc) -ForegroundColor Gray
    if (Get-Command Set-GateVote -ErrorAction SilentlyContinue) {
        Set-GateVote -Role $Role -Text $evt
    }
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        Write-GateProgress $evt -Now $now -Phase 'reviewers'
    }
    $script:VoteNowPublished[$Role] = $evt
}

function Invoke-ReviewerPanel {
    param(
        $GrokExe, $ModelName, $DiffText, $RoundDir, $Round, $PriorBlockers, $Sequential, $Effort, $MaxTurns,
        [string[]]$Roles
    )
    if (-not $Roles -or $Roles.Count -eq 0) { $Roles = @('correctness', 'security', 'simplicity') }
    $roles = @($Roles)
    $results = @{}
    $script:VoteNowPublished = @{}

    if ($Sequential) {
        $seqI = 0
        foreach ($role in $roles) {
            $seqI++
            $left = @($roles | Select-Object -Skip $seqI)
            $now = if ($left.Count -gt 0) {
                "Waiting on vibe-$role then $($left -join ', ')"
            } else {
                "Waiting on vibe-$role (last sequential)"
            }
            if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
                Write-GateProgress ("start sequential reviewer:{0} ({1}/{2})" -f $role, $seqI, $roles.Count) `
                    -Now $now -Phase 'reviewers'
            }
            $pf = Join-Path $RoundDir "reviewer-$role.prompt.txt"
            $lf = Join-Path $RoundDir "reviewer-$role.log.txt"
            Save-Text $pf (New-ReviewerPrompt -Role $role -DiffText $DiffText -Round $Round -PriorBlockers $PriorBlockers)
            $results[$role] = Invoke-GrokHeadless -GrokExe $GrokExe -ModelName $ModelName -PromptFile $pf -Label "reviewer:$role" -Effort $Effort -MaxTurns $MaxTurns -OutLog $lf
            Publish-ReviewerVoteNow -Role $role -Result $results[$role] -WaitingOn (($left | ForEach-Object { "vibe-$_" }) -join ', ')
        }
    } else {
        $jobs = @()
        foreach ($role in $roles) {
            $pf = Join-Path $RoundDir "reviewer-$role.prompt.txt"
            $lf = Join-Path $RoundDir "reviewer-$role.log.txt"
            Save-Text $pf (New-ReviewerPrompt -Role $role -DiffText $DiffText -Round $Round -PriorBlockers $PriorBlockers)
            $jobs += Start-Job -Name "vibe-$role" -ScriptBlock {
                param($Exe, $Model, $PromptFile, $LogFile, $Effort, $MaxTurns, $Role)
                $argList = @(
                    '--prompt-file', $PromptFile,
                    '-m', $Model,
                    '--reasoning-effort', $Effort,
                    '--max-turns', "$MaxTurns",
                    '--permission-mode', 'bypassPermissions',
                    '--disallowed-tools', 'search_replace,write,Write,run_terminal_command,run_terminal_cmd,Bash,bash'
                )
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $output = & $Exe @argList 2>&1
                    $code = $LASTEXITCODE
                } catch {
                    $sw.Stop()
                    return @{ Role = $Role; Ok = $false; Text = "$_"; ExitCode = -1; Seconds = $sw.Elapsed.TotalSeconds }
                }
                $sw.Stop()
                $text = if ($output) { ($output | ForEach-Object { "$_" }) -join "`n" } else { '' }
                [System.IO.File]::WriteAllText($LogFile, $text)
                @{
                    Role     = $Role
                    Ok       = (($code -eq 0 -or $null -eq $code) -and $text.Trim().Length -gt 0)
                    Text     = $text
                    ExitCode = $code
                    Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                }
            } -ArgumentList $GrokExe, $ModelName, $pf, $lf, $Effort, $MaxTurns, $role
        }
        Write-Host "  ... waiting for $($jobs.Count) reviewer jobs (votes publish as each finishes)" -ForegroundColor DarkGray
        $script:VoteNowPublished = @{}
        $pending = New-Object System.Collections.Generic.List[object]
        foreach ($j in $jobs) { [void]$pending.Add($j) }
        $swWait = [System.Diagnostics.Stopwatch]::StartNew()
        while ($pending.Count -gt 0) {
            $still = New-Object System.Collections.Generic.List[object]
            $justDone = New-Object System.Collections.Generic.List[object]
            foreach ($j in $pending) {
                if ($j.State -eq 'Running') { [void]$still.Add($j) } else { [void]$justDone.Add($j) }
            }
            foreach ($j in $justDone) {
                $r = Receive-Job $j -ErrorAction SilentlyContinue
                Remove-Job $j -Force -ErrorAction SilentlyContinue
                $roleName = $null
                if ($r -and $r.Role) {
                    $roleName = [string]$r.Role
                    $results[$roleName] = @{ Ok = $r.Ok; Text = $r.Text; ExitCode = $r.ExitCode; Seconds = $r.Seconds }
                } else {
                    $roleName = ([string]$j.Name) -replace '^vibe-', ''
                    $results[$roleName] = @{ Ok = $false; Text = ''; ExitCode = -1; Seconds = 0 }
                }
                $waitNames = (@($still | ForEach-Object { $_.Name })) -join ', '
                Publish-ReviewerVoteNow -Role $roleName -Result $results[$roleName] -WaitingOn $waitNames
            }
            $pending = $still
            if ($pending.Count -eq 0) { break }
            if ($swWait.Elapsed.TotalSeconds -ge 1200) {
                Write-GateProgress ('job timeout after {0:n0}s - stopping leftover jobs' -f $swWait.Elapsed.TotalSeconds)
                foreach ($j in $pending) { try { Stop-Job $j -ErrorAction SilentlyContinue } catch {} }
                break
            }
            $waitNames = (@($pending | ForEach-Object { $_.Name })) -join ', '
            $gotLines = @($script:VoteNowPublished.Values | Where-Object { $_ })
            $gotBit = if ($gotLines.Count) { ' | ' + ($gotLines -join ' || ') } else { '. none finished yet' }
            $elapsed = [int]$swWait.Elapsed.TotalSeconds
            if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
                Write-GateProgress ("waiting {0} ({1}s)" -f $waitNames, $elapsed) `
                    -Now ("Waiting on $waitNames (~${elapsed}s)$gotBit")
            }
            $null = Wait-Job -Job @($pending.ToArray()) -Timeout 15
        }
        foreach ($role in $roles) {
            if (-not $results.ContainsKey($role)) {
                $results[$role] = @{ Ok = $false; Text = ''; ExitCode = -1; Seconds = 0 }
            }
        }
    }

    $parsed = @()
    $rawBundle = [ordered]@{}
    $fail = @()
    foreach ($role in $roles) {
        $r = $results[$role]
        Write-Host ("  reviewer:{0} ok={1} {2}s exit={3}" -f $role, $r.Ok, $r.Seconds, $r.ExitCode) -ForegroundColor DarkCyan
        if (-not $r.Ok) { $fail += $role; continue }
        $obj = ConvertFrom-JsonLoose $r.Text
        if (-not $obj) {
            # Fail-closed: no vote-only / empty-findings APPROVE path (false confidence)
            Write-Host ("    unparseable JSON from {0} (fail-closed)" -f $role) -ForegroundColor Yellow
            $fail += $role
            continue
        }
        if (-not $obj.reviewer_id) { $obj | Add-Member -NotePropertyName reviewer_id -NotePropertyValue $role -Force }
        $obj = Normalize-ReviewerVote $obj
        if (-not $obj) {
            Write-Host ("    inconsistent vote/findings from {0} (fail-closed)" -f $role) -ForegroundColor Yellow
            $fail += $role
            continue
        }
        $parsed += $obj
        $rawBundle[$role] = $obj
        $voteStr = "$($obj.vote)"
        $fc = @($obj.findings).Count
        Write-Host ("    vote={0} findings={1}" -f $voteStr, $fc) -ForegroundColor Gray
        if (-not ($script:VoteNowPublished -and $script:VoteNowPublished.ContainsKey($role))) {
            Publish-ReviewerVoteNow -Role $role -Result $r
        }
    }

    if ($fail.Count -gt 0) {
        $failList = $fail -join ', '
        return @{ Ok = $false; Error = "Reviewers failed or unparseable: $failList"; Panel = $parsed; Bundle = $rawBundle }
    }
    if ($parsed.Count -lt $roles.Count) {
        return @{ Ok = $false; Error = "Expected $($roles.Count) reviewers, got $($parsed.Count)"; Panel = $parsed; Bundle = $rawBundle }
    }
    return @{ Ok = $true; Panel = $parsed; Bundle = $rawBundle; Error = $null }
}

function Get-FindingSeverity([object]$finding) {
    if (-not $finding) { return '' }
    try {
        return ("$($finding.severity)").ToLowerInvariant().Trim()
    } catch {
        return ''
    }
}

function Normalize-ReviewerVote {
    # Any severity=blocker forces vote=BLOCK. Unknown votes fail-closed.
    # BLOCK with zero findings fails. BLOCK with only non-blocker findings promotes them to blocker.
    param($obj)
    if (-not $obj) { return $null }
    $findings = @()
    if ($null -ne $obj.findings) { $findings = @($obj.findings) }
    $vote = ''
    try { $vote = ("$($obj.vote)").ToUpperInvariant().Trim() } catch { $vote = '' }
    $validVotes = @('STRONG_APPROVE', 'APPROVE', 'APPROVE_WITH_CHANGES', 'BLOCK')
    if ($validVotes -notcontains $vote) {
        Write-Host ("    normalize: {0} invalid/missing vote '{1}' (fail-closed)" -f $obj.reviewer_id, $vote) -ForegroundColor Yellow
        return $null
    }
    $blockerCount = 0
    foreach ($f in $findings) {
        if ((Get-FindingSeverity $f) -eq 'blocker') { $blockerCount++ }
    }
    if ($blockerCount -gt 0 -and $vote -ne 'BLOCK') {
        Write-Host ("    normalize: {0} vote {1} -> BLOCK ({2} blocker finding(s))" -f $obj.reviewer_id, $vote, $blockerCount) -ForegroundColor DarkYellow
        $obj | Add-Member -NotePropertyName vote -NotePropertyValue 'BLOCK' -Force
        $vote = 'BLOCK'
    }
    if ($vote -eq 'BLOCK' -and $blockerCount -eq 0) {
        if ($findings.Count -eq 0) {
            return $null
        }
        # Model said BLOCK but labeled findings advisory/unknown — promote so harvest cannot drop them
        Write-Host ("    normalize: {0} BLOCK with non-blocker findings -> promote severity=blocker" -f $obj.reviewer_id) -ForegroundColor DarkYellow
        $promoted = foreach ($f in $findings) {
            if (-not $f) { continue }
            try { $f | Add-Member -NotePropertyName severity -NotePropertyValue 'blocker' -Force } catch {}
            $f
        }
        $obj | Add-Member -NotePropertyName findings -NotePropertyValue @($promoted) -Force
    }
    return $obj
}

function Get-PanelBlockerFindings {
    param($Panel)
    $out = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($p in @($Panel)) {
        $role = 'reviewer'
        try { if ($p.reviewer_id) { $role = [string]$p.reviewer_id } } catch {}
        foreach ($f in @($p.findings)) {
            if (-not $f) { continue }
            if ((Get-FindingSeverity $f) -ne 'blocker') { continue }
            $id = $null
            try { $id = [string]$f.id } catch {}
            if (-not $id) {
                $title = ''
                $file = ''
                try { $title = [string]$f.title } catch {}
                try { $file = [string]$f.file } catch {}
                $id = 'panel-{0}-{1}' -f $role, (($file + '|' + $title).GetHashCode())
            }
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $out.Add([pscustomobject]@{
                    id        = $id
                    file      = $(try { [string]$f.file } catch { '' })
                    line      = $(try { [int]$f.line } catch { 0 })
                    title     = $(try { [string]$f.title } catch { 'blocker' })
                    detail    = $(try { [string]$f.detail } catch { '' })
                    fix_hint  = $(try { [string]$f.fix_hint } catch { '' })
                    sources   = @($role)
                })
        }
    }
    return @($out)
}

function Invoke-Arbiter {
    param($GrokExe, $ModelName, $DiffText, $Panel, $RoundDir, $Round, $Effort, $MaxTurns)
    $panelJson = ($Panel | ConvertTo-Json -Depth 10)
    $pf = Join-Path $RoundDir 'arbiter.prompt.txt'
    $lf = Join-Path $RoundDir 'arbiter.log.txt'
    Save-Text $pf (New-ArbiterPrompt -DiffText $DiffText -PanelJson $panelJson -Round $Round)
    Save-Text (Join-Path $RoundDir 'panel.json') $panelJson
    $r = Invoke-GrokHeadless -GrokExe $GrokExe -ModelName $ModelName -PromptFile $pf -Label 'arbiter' -Effort $Effort -MaxTurns $MaxTurns -OutLog $lf
    if (-not $r.Ok) {
        return @{ Ok = $false; Error = "Arbiter failed (exit $($r.ExitCode))"; Text = $r.Text }
    }
    $obj = ConvertFrom-JsonLoose $r.Text
    $verdict = $null
    if ($obj -and $obj.verdict) { $verdict = "$($obj.verdict)".ToUpperInvariant().Trim() }
    if (-not $verdict) { $verdict = Get-MachineVerdict $r.Text }
    if (-not $verdict) {
        return @{ Ok = $false; Error = 'Arbiter missing verdict'; Text = $r.Text; Result = $obj }
    }
    # Enforce: any arbiter blockers => BLOCK
    $blockers = [System.Collections.Generic.List[object]]::new()
    $seenIds = @{}
    if ($obj -and $obj.blockers) {
        foreach ($b in @($obj.blockers)) {
            if (-not $b) { continue }
            $bid = $(try { [string]$b.id } catch { '' })
            if ($bid -and $seenIds.ContainsKey($bid)) { continue }
            if ($bid) { $seenIds[$bid] = $true }
            $blockers.Add($b)
        }
    }
    # Harvest panel severity=blocker findings the arbiter dropped (no silent APPROVE)
    foreach ($pb in @(Get-PanelBlockerFindings -Panel $Panel)) {
        $bid = [string]$pb.id
        if ($bid -and $seenIds.ContainsKey($bid)) { continue }
        if ($bid) { $seenIds[$bid] = $true }
        $blockers.Add($pb)
    }
    if ($blockers.Count -gt 0) { $verdict = 'BLOCK' }
    return @{ Ok = $true; Verdict = $verdict; Result = $obj; Text = $r.Text; Blockers = @($blockers); Seconds = $r.Seconds }
}

function Invoke-Fixer {
    param($GrokExe, $ModelName, $DiffText, $Blockers, $RoundDir, $Round, $Effort, $MaxTurns)
    $bjson = ($Blockers | ConvertTo-Json -Depth 10)
    $pf = Join-Path $RoundDir 'fixer.prompt.txt'
    $lf = Join-Path $RoundDir 'fixer.log.txt'
    Save-Text $pf (New-FixerPrompt -DiffText $DiffText -BlockersJson $bjson -Round $Round)
    Save-Text (Join-Path $RoundDir 'blockers.json') $bjson

    $titles = @($Blockers | ForEach-Object { if ($_.title) { $_.title } else { $_.id } } | Where-Object { $_ })
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        Write-GateProgress ("fixer starting ({0} blocker(s)): {1}" -f @($Blockers).Count, ($titles -join '; ')) `
            -Now ("Auto-fixing {0} blocker(s)..." -f @($Blockers).Count) -Phase 'fixer'
    }
    $wt = $null
    $before = $null
    if (-not (Get-Command New-FixerWorktree -ErrorAction SilentlyContinue)) {
        Write-Host '  fixer worktree helper missing; refusing in-place edit' -ForegroundColor Red
        return @{ Ok = $false; Seconds = 0; ExitCode = 1; Text = 'fixer worktree helper missing' }
    }
    $wt = New-FixerWorktree
    if (-not $wt) {
        Write-Host '  fixer worktree unavailable; refusing in-place edit' -ForegroundColor Red
        return @{ Ok = $false; Seconds = 0; ExitCode = 1; Text = 'fixer worktree unavailable' }
    }
    $before = Get-WorktreeFileFingerprints -Root $wt.Root
    Write-Host ('  fixer worktree: {0}' -f $wt.Root) -ForegroundColor DarkCyan
    $wd = $wt.Root
    try {
        $r = Invoke-GrokHeadless -GrokExe $GrokExe -ModelName $ModelName -PromptFile $pf -Label 'implementer-fix' -Effort $Effort -MaxTurns $MaxTurns -AllowWrites -OutLog $lf -WorkingDirectory $wd
        if ($wt) {
            $copied = @(Copy-FixerWorktreeBack -Worktree $wt -BeforeHashes $before)
            Write-Host ('  fixer copied {0} file(s) back from worktree' -f $copied.Count) -ForegroundColor DarkCyan
            if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
                Write-GateProgress ("fixer copied {0} file(s) back" -f $copied.Count)
            }
        }
        return $r
    } finally {
        if ($wt) { Remove-FixerWorktree -Worktree $wt }
    }
}

function Update-GitStageAfterFix {
    # Re-stage blocker paths + prior-staged dirtied + tracked paths newly dirty since fix start.
    # Never blanket add-all or update-all (avoids pulling unrelated pre-existing dirty tracked files).
    param(
        $Blockers,
        [string[]]$PriorStaged = @(),
        [string[]]$PreFixDirty = @(),
        [string[]]$PreFixUntracked = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($b in @($Blockers)) {
            if (-not $b) { continue }
            $fp = $null
            try { $fp = [string]$b.file } catch { $fp = $null }
            $norm = Normalize-RestagePath $fp
            if ($norm) { [void]$paths.Add($norm) }
        }
        # Prior staged set: if worktree now differs from index, re-add those paths only
        foreach ($ps in @($PriorStaged)) {
            $norm = Normalize-RestagePath $ps
            if (-not $norm) { continue }
            $dirty = git diff --name-only -- (':(literal)' + $norm) 2>$null
            if ($dirty) { [void]$paths.Add($norm) }
        }
        # Tracked paths dirtied during fix (in post-dirty, not in pre-fix snapshot)
        $preSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($d in @($PreFixDirty)) {
            if ([string]::IsNullOrWhiteSpace($d)) { continue }
            [void]$preSet.Add(($d.Trim() -replace '\\', '/'))
        }
        try {
            $postDirty = @(git diff --name-only --diff-filter=ACMRD 2>$null | Where-Object { $_ })
            foreach ($pd in $postDirty) {
                $norm = Normalize-RestagePath $pd
                if (-not $norm) { continue }
                if (-not $preSet.Contains($norm)) { [void]$paths.Add($norm) }
            }
        } catch {}
        $preU = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($u in @($PreFixUntracked)) {
            $norm = Normalize-RestagePath $u
            if (-not $norm) { continue }
            [void]$preU.Add($norm)
        }
        try {
            $postU = @(git ls-files --others --exclude-standard 2>$null | Where-Object { $_ })
            foreach ($u in $postU) {
                $norm = Normalize-RestagePath $u
                if (-not $norm) { continue }
                if (-not $preU.Contains($norm)) { [void]$paths.Add($norm) }
            }
        } catch {}
        foreach ($rawPath in @($paths)) {
            if (-not $rawPath) { continue }
            $p = $rawPath -replace '/', [IO.Path]::DirectorySeparatorChar
            $spec = ':(literal)' + $rawPath
            $exists = Test-Path -LiteralPath $p -ErrorAction SilentlyContinue
            if (-not $exists) {
                $ls = git ls-files --error-unmatch -- $spec 2>$null
                if (-not $ls) { continue }
            }
            git add -- $spec 2>$null | Out-Null
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Write-ArbiterSummary($arb) {
    Write-Host ""
    Write-Host "-------- ARBITER --------" -ForegroundColor Magenta
    Write-Host "VERDICT: $($arb.Verdict)" -ForegroundColor $(if ($arb.Verdict -eq 'BLOCK') { 'Red' } else { 'Green' })
    if ($arb.Result -and $arb.Result.rationale) {
        Write-Host "Rationale: $($arb.Result.rationale)" -ForegroundColor Gray
    }
    $bs = @($arb.Blockers)
    $as = @()
    if ($arb.Result -and $arb.Result.advisories) { $as = @($arb.Result.advisories) }
    Write-Host "Blockers: $($bs.Count)  Advisories: $($as.Count)" -ForegroundColor Cyan
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        $arbNow = 'Arbiter: {0} - {1} blocker(s), {2} advisory(ies)' -f $arb.Verdict, $bs.Count, $as.Count
        Write-GateProgress ('arbiter {0}: {1} blocker(s), {2} advisory(ies)' -f $arb.Verdict, $bs.Count, $as.Count) -Now $arbNow -Phase 'arbiter'
        foreach ($b in $bs) {
            Write-GateProgress ("  BLOCKER $($b.id) $($b.title)")
        }
        foreach ($a in @($as | Select-Object -First 6)) {
            Write-GateProgress ("  advisory $($a.id) $($a.title)")
        }
    }
    foreach ($b in $bs) {
        $loc = @($b.file, $b.line) -ne $null -join ':'
        Write-Host "  [BLOCKER] $($b.id) $loc - $($b.title)" -ForegroundColor Red
        if ($b.detail) { Write-Host "            $($b.detail)" -ForegroundColor DarkRed }
        if ($b.fix_hint) { Write-Host "            fix: $($b.fix_hint)" -ForegroundColor Yellow }
    }
    foreach ($a in $as) {
        Write-Host "  [advisory] $($a.id) - $($a.title)" -ForegroundColor DarkYellow
    }
    if ($arb.Result -and $arb.Result.disputes_resolved) {
        foreach ($d in @($arb.Result.disputes_resolved)) {
            Write-Host "  dispute: $($d.topic) -> $($d.resolution) ($($d.rationale))" -ForegroundColor DarkCyan
        }
    }
}

# ===================== MAIN =====================

function Exit-Gate {
    param([int]$Code, [string]$Reason = '')
    if ($Reason) { $script:GateRun.failReason = $Reason }
    if ($script:overallSw) {
        $script:GateRun.elapsedSec = [math]::Round($script:overallSw.Elapsed.TotalSeconds, 1)
    }
    $script:GateRun.passed = ($Code -eq 0)
    if (-not $script:GateRun.verdict -and $Code -eq 0) { $script:GateRun.verdict = 'APPROVE' }
    if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
        if ("$script:GateNow" -notmatch 'GATE DONE') {
            if ($Code -eq 0) {
                Write-GateDone -Passed -Summary $(if ($script:GateRun.verdict) { $script:GateRun.verdict } else { 'ok' })
            } else {
                Write-GateDone -Summary $(if ($Reason) { $Reason } else { 'blocked' })
            }
        }
    }
    $rd = Write-GateReport -Run $script:GateRun -ExitCode $Code
    if ($Code -eq 0 -and $script:GateRun.diffHash -and -not $script:GateRun.cacheHit) {
        Save-GatePassCache -DiffHash $script:GateRun.diffHash -ProfileName $script:ResolvedProfile.Name `
            -ModelName $script:GateRun.model -Verdict $script:GateRun.verdict -ReportDir ([string]$rd)
    }
    exit $Code
}

$script:overallSw = [System.Diagnostics.Stopwatch]::StartNew()

if ($NoScans) {
    if (Get-Command Start-GateRun -ErrorAction SilentlyContinue) { Start-GateRun }
} elseif (Get-Command Reset-GateLiveLog -ErrorAction SilentlyContinue) {
    Reset-GateLiveLog
}
Write-Host "=== VIBE MULTI-REVIEWER QUALITY LOOP ===" -ForegroundColor Cyan
if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
    Write-GateProgress ("profile={0} roles={1}" -f $script:ResolvedProfile.Name, ($script:ResolvedProfile.Roles -join ',')) `
        -Now ("AI review starting (profile {0})" -f $script:ResolvedProfile.Name) -Phase 'review'
    Write-GateProgress 'Watch live: Get-Content ~/.grok/vibe-tools/reports/gate-status.txt -Wait'
}
Write-Host ("Profile: {0} - {1}" -f $script:ResolvedProfile.Name, $script:ResolvedProfile.Description) -ForegroundColor DarkCyan
Write-Host ("Roles: {0}" -f ($script:ResolvedProfile.Roles -join ', ')) -ForegroundColor DarkCyan
Write-Host ("MaxRounds={0}  Fix={1}  Parallel={2}  Cache={3}" -f $MaxRounds, (-not [bool]$NoFix), (-not [bool]$SequentialReviewers), (-not [bool]$NoCache)) -ForegroundColor DarkGray

if (-not $NoScans) {
    Write-Phase "Phase 0: Static scans"
    Write-Host "+==========================================================+" -ForegroundColor Magenta
    Write-Host "|   VIBE GATE : SCANS + MULTI-REVIEWER LOOP                |" -ForegroundColor Magenta
    Write-Host "+==========================================================+" -ForegroundColor Magenta
    & $runScans -Quiet:$false
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        Write-GateFail "Static scans exited $LASTEXITCODE"
        Exit-Gate -Code 1 -Reason "static scans exit $LASTEXITCODE"
    }
} else {
    Write-Phase "Phase 0: static scans already ran in hook step 1 (not re-running)"
}

Write-Phase "Phase 1: Preflight"
$pre = Test-ReviewPreflight -ModelName $Model -Port $ProxyPort
if (-not $pre) { Exit-Gate -Code 1 -Reason 'preflight failed (grok/proxy)' }
$grokExe = $pre.Exe
$useModel = $pre.Model
$script:GateRun.model = $useModel
Write-Host "  grok=$grokExe" -ForegroundColor DarkGray
Write-Host "  model=$useModel  effort=$ReasoningEffort" -ForegroundColor DarkGray

if (-not $WorkDir) {
    $WorkDir = Join-Path $env:TEMP ("vibe-review-" + [guid]::NewGuid().ToString('n').Substring(0, 10))
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$script:GateRun.workDir = $WorkDir
Write-Host "  workdir=$WorkDir" -ForegroundColor DarkGray

# Initial diff + compress large payloads so reviewers don't burn turns chunking.
# Compress on RAW unified diff only — never Limit-DiffText first (head/tail splice
# is not valid input for Get-DiffFileStats and drops middle files on huge commits).
$rawDiff = Get-GitDiffText -Override $DiffOverride
$rawLen = if ($rawDiff) { $rawDiff.Length } else { 0 }
$initialDiff = Compress-DiffForReview $rawDiff
if (Get-Command Add-ReviewContext -ErrorAction SilentlyContinue) {
    $initialDiff = Add-ReviewContext -Brief $initialDiff -RawDiff $rawDiff -ProfileName $script:ResolvedProfile.Name -Round 1
}
$diffHash = Get-DiffHash $rawDiff
$script:GateRun.diffHash = $diffHash
$script:GateRun.rawDiffChars = $rawLen
$script:GateRun.reviewDiffChars = $(if ($initialDiff) { $initialDiff.Length } else { 0 })
Write-Host ("  diffHash={0}... raw={1} reviewCtx={2}" -f $diffHash.Substring(0, [Math]::Min(12, $diffHash.Length)), $rawLen, $script:GateRun.reviewDiffChars) -ForegroundColor DarkGray
if ($rawLen -gt 48000 -and $initialDiff.Length -lt $rawLen) {
    Write-Host "  large diff compressed to brief (file list + samples + hotspots)" -ForegroundColor DarkCyan
}

$cached = Test-GatePassCache -DiffHash $diffHash -ProfileName $script:ResolvedProfile.Name -ModelName $useModel
if ($cached) {
    $script:GateRun.cacheHit = $true
    $script:GateRun.verdict = $cached.verdict
    $script:GateRun.passed = $true
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host (" GATE CACHE HIT - {0} (same diff+profile already passed)" -f $cached.verdict) -ForegroundColor Green
    Write-Host (" prior report: {0}" -f $cached.reportDir) -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Green
    if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
        Write-GateDone -Passed -Summary ("cache hit ({0})" -f $cached.verdict)
    }
    Exit-Gate -Code 0
}

$script:lastArbiter = $null
$priorBlockersText = ''
$roles = @($script:ResolvedProfile.Roles)

for ($round = 1; $round -le $MaxRounds; $round++) {
    Write-Host ""
    Write-Host "############################################################" -ForegroundColor Magenta
    Write-Host ("# ROUND {0} / {1}  [{2}]" -f $round, $MaxRounds, $script:ResolvedProfile.Name) -ForegroundColor Magenta
    Write-Host "############################################################" -ForegroundColor Magenta

    $roundDir = Join-Path $WorkDir "round-$round"
    New-Item -ItemType Directory -Force -Path $roundDir | Out-Null

    $diff = if ($round -eq 1) {
        $initialDiff
    } else {
        $rawRound = Get-GitDiffText -Override $null
        $next = Compress-DiffForReview $rawRound
        if (Get-Command Add-ReviewContext -ErrorAction SilentlyContinue) {
            Add-ReviewContext -Brief $next -RawDiff $rawRound -ProfileName $script:ResolvedProfile.Name -Round $round
        } else {
            $next
        }
    }
    Save-Text (Join-Path $roundDir 'diff.patch') $diff

    $roundRec = [ordered]@{
        number      = $round
        panelVotes  = @()
        verdict     = ''
        rationale   = ''
        blockers    = @()
        advisories  = @()
        disputes    = @()
        fixerOk     = $null
        fixerSeconds = $null
    }

    Write-Phase ("Round {0} - reviewer panel ({1})" -f $round, $roles.Count)
    $panel = Invoke-ReviewerPanel -GrokExe $grokExe -ModelName $useModel -DiffText $diff -RoundDir $roundDir -Round $round -PriorBlockers $priorBlockersText -Sequential:$SequentialReviewers -Effort $ReasoningEffort -MaxTurns $ReviewerMaxTurns -Roles $roles
    if (-not $panel.Ok) {
        Write-GateFail $panel.Error
        Write-Host "Partial logs under $roundDir" -ForegroundColor DarkGray
        Write-Host "Tip: check proxy (start-grok), model access, and reviewer logs in workdir." -ForegroundColor Yellow
        Exit-Gate -Code 1 -Reason $panel.Error
    }
    foreach ($p in @($panel.Panel)) {
        $roundRec.panelVotes += [pscustomobject]@{
            role     = $p.reviewer_id
            vote     = $p.vote
            findings = @($p.findings).Count
        }
    }

    Write-Phase ("Round {0} - arbiter (merge + severity disputes)" -f $round)
    $arb = Invoke-Arbiter -GrokExe $grokExe -ModelName $useModel -DiffText $diff -Panel $panel.Panel -RoundDir $roundDir -Round $round -Effort $ReasoningEffort -MaxTurns $ArbiterMaxTurns
    if (-not $arb.Ok) {
        Write-GateFail $arb.Error
        if ($arb.Text) { Write-Host $arb.Text }
        Exit-Gate -Code 1 -Reason $arb.Error
    }
    $script:lastArbiter = $arb
    Save-Text (Join-Path $roundDir 'arbiter.result.json') (($arb.Result | ConvertTo-Json -Depth 12))
    Write-ArbiterSummary $arb

    $roundRec.verdict = $arb.Verdict
    if ($arb.Result -and $arb.Result.rationale) { $roundRec.rationale = [string]$arb.Result.rationale }
    $roundRec.blockers = @($arb.Blockers)
    if ($arb.Result -and $arb.Result.advisories) { $roundRec.advisories = @($arb.Result.advisories) }
    if ($arb.Result -and $arb.Result.disputes_resolved) { $roundRec.disputes = @($arb.Result.disputes_resolved) }

    $passVotes = @('STRONG_APPROVE', 'APPROVE', 'APPROVE_WITH_CHANGES')
    if ($passVotes -contains $arb.Verdict) {
        $script:GateRun.rounds = @($script:GateRun.rounds) + @($roundRec)
        $script:GateRun.verdict = $arb.Verdict
        $script:overallSw.Stop()
        $elapsed = [math]::Round($script:overallSw.Elapsed.TotalSeconds, 1)
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host (" GATE PASSED - {0} after {1} round(s) in {2}s [{3}]" -f $arb.Verdict, $round, $elapsed, $script:ResolvedProfile.Name) -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        if ($arb.Result -and @($arb.Result.advisories).Count -gt 0) {
            Write-Host "Advisories remain (non-blocking). Consider follow-ups." -ForegroundColor Yellow
        }
        Write-Host "Artifacts: $WorkDir" -ForegroundColor DarkGray
        $nAdv = @($arb.Result.advisories).Count
        $nBlk = @($arb.Blockers).Count
        $fixNote = if ($round -gt 1) { 'after auto-fix + re-review' } else { 'no auto-fix needed' }
        if (Get-Command Write-GateDone -ErrorAction SilentlyContinue) {
            Write-GateDone -Passed -Summary ("{0} in {1}s; {2} blocker(s), {3} advisory(ies); {4}" -f $arb.Verdict, $elapsed, $nBlk, $nAdv, $fixNote)
        }
        Exit-Gate -Code 0
    }

    # BLOCK path
    $blockers = @($arb.Blockers)
    if ($blockers.Count -eq 0) {
        $script:GateRun.rounds = @($script:GateRun.rounds) + @($roundRec)
        Write-GateFail "Verdict BLOCK but arbiter returned zero blockers (inconsistent)."
        Exit-Gate -Code 1 -Reason 'BLOCK with zero blockers'
    }

    $priorBlockersText = ($blockers | ConvertTo-Json -Depth 8)

    if ($NoFix) {
        $script:GateRun.rounds = @($script:GateRun.rounds) + @($roundRec)
        $script:GateRun.verdict = 'BLOCK'
        Write-GateFail ("BLOCK with {0} blocker(s). Fix loop disabled (profile={1} or -NoFix)." -f $blockers.Count, $script:ResolvedProfile.Name)
        Write-Host "Artifacts: $WorkDir" -ForegroundColor DarkGray
        Exit-Gate -Code 1 -Reason ("BLOCK x{0} no-fix" -f $blockers.Count)
    }

    if ($round -ge $MaxRounds) {
        $script:GateRun.rounds = @($script:GateRun.rounds) + @($roundRec)
        $script:GateRun.verdict = 'BLOCK'
        Write-GateFail ("BLOCK after {0} round(s); blockers remain. Human intervention required." -f $MaxRounds)
        Write-Host "Artifacts: $WorkDir" -ForegroundColor DarkGray
        Exit-Gate -Code 1 -Reason ("BLOCK after max rounds ({0})" -f $MaxRounds)
    }

    Write-Phase ("Round {0} - implementer fix pass ({1} blockers)" -f $round, $blockers.Count)
    # Snapshot before fixer so restage can pick helper/shared edits without git add -u
    $preFixDirty = @()
    try { $preFixDirty = @(git diff --name-only --diff-filter=ACMRD 2>$null | Where-Object { $_ }) } catch {}
    $preFixUntracked = @()
    try { $preFixUntracked = @(git ls-files --others --exclude-standard 2>$null | Where-Object { $_ }) } catch {}
    $priorStaged = @()
    try { $priorStaged = @(git diff --cached --name-only --diff-filter=ACMRD 2>$null | Where-Object { $_ }) } catch {}
    $fix = Invoke-Fixer -GrokExe $grokExe -ModelName $useModel -DiffText $diff -Blockers $blockers -RoundDir $roundDir -Round $round -Effort $ReasoningEffort -MaxTurns $FixerMaxTurns
    Write-Host ("  fixer finished ok={0} {1}s exit={2}" -f $fix.Ok, $fix.Seconds, $fix.ExitCode) -ForegroundColor DarkCyan
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        $fixNow = if ($fix.Ok) { 'Fixer finished. Restaging + next review round...' } else { 'Fixer failed' }
        Write-GateProgress ('fixer finished ok={0} {1}s - restaging then re-review' -f $fix.Ok, $fix.Seconds) -Now $fixNow
    }
    $roundRec.fixerOk = [bool]$fix.Ok
    $roundRec.fixerSeconds = $fix.Seconds
    if ($fix.Text) {
        $tail = if ($fix.Text.Length -gt 2000) { $fix.Text.Substring($fix.Text.Length - 2000) } else { $fix.Text }
        Write-Host "  --- fixer tail ---" -ForegroundColor DarkGray
        Write-Host $tail
    }
    $script:GateRun.rounds = @($script:GateRun.rounds) + @($roundRec)
    if (-not $fix.Ok) {
        Write-GateFail "Implementer fix pass failed or produced empty output."
        Exit-Gate -Code 1 -Reason 'fixer failed'
    }

    Write-Host "  Re-staging changes for next review round..." -ForegroundColor DarkGray
    Update-GitStageAfterFix -Blockers $blockers -PriorStaged $priorStaged -PreFixDirty $preFixDirty -PreFixUntracked $preFixUntracked
    # refresh hash baseline after fix for next round cache (optional)
    $nextRound = $round + 1
    Write-Host ("  Continuing to round {0}..." -f $nextRound) -ForegroundColor Cyan
    if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
        Write-GateProgress ("re-review round {0} after fixer" -f $nextRound) `
            -Now ("Round {0}: re-review after auto-fix" -f $nextRound) -Phase 're-review'
    }
}

Write-GateFail "Loop ended without pass."
Exit-Gate -Code 1 -Reason 'loop ended without pass'

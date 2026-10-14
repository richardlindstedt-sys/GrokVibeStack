#Requires -Version 5.1
<#
.SYNOPSIS
    Shared gate-chat helpers (monitor, Stop hook, prompt inject).
#>

function ConvertTo-GatePlainText([string]$Text) {
    # Status files are rewritten by Windows PowerShell 5.1. Non-ASCII (em dash,
    # nbsp thousands separator) is read as ANSI and written back as UTF-8, so
    # one dash grows into a new garbage line every heartbeat.
    # Same body as gate-progress.ps1. watch-gate-now loads this file, not that one.
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $s = $s -replace '[\u2010-\u2015\u2212]', '-'
    $s = $s -replace '[\u00A0\u202F\u2007\u2009]', ' '
    $sb = New-Object System.Text.StringBuilder $s.Length
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 9 -or ($c -ge 32 -and $c -le 126)) { [void]$sb.Append($ch) }
    }
    return (($sb.ToString() -replace '\s+', ' ').Trim())
}

function Get-GateNowTickKey([string]$NowLine) {
    $s = "$NowLine"
    $s = $s -replace '\s*\(~\d+s\)', ''
    # Heartbeats rewrite "490s" and "out 0B". Those are not new content.
    $s = $s -replace '\b\d+s\b', ''
    $s = $s -replace '\bout\s+\d+B\b', 'out'
    $s = $s -replace '\berr\s+\d+B\b', 'err'
    $s = $s -replace '\s{2,}', ' '
    $s = $s -replace '\s+\|\s+\|', ' |'
    return $s.Trim()
}

function Test-IsGateWaitNow([string]$NowLine) {
    $s = (Get-GateNowTickKey $NowLine) -replace '^NOW:\s+', ''
    # "reviewer:correctness 12s | ... | waiting on model" does not start with Waiting.
    return [bool]($s -match '(?i)(^Waiting on\b|waiting on model|no output yet)')
}

function Get-GateFileRun([string[]]$Lines) {
    $run = ($Lines | Where-Object { $_ -match '^RUN:\s+\S+' } | Select-Object -First 1)
    if ($run -and $run -match '^RUN:\s+(\S+)') { return $Matches[1] }
    return ''
}

function Get-VibeStateDir {
    if (-not [string]::IsNullOrWhiteSpace($env:VIBE_STATE_DIR)) {
        return $env:VIBE_STATE_DIR.Trim()
    }
    return (Join-Path $env:USERPROFILE '.grok\vibe-tools\state')
}

function Get-GateOpenAdvisoriesFile {
    if (-not [string]::IsNullOrWhiteSpace($env:VIBE_OPEN_ADVISORIES_FILE)) {
        return $env:VIBE_OPEN_ADVISORIES_FILE.Trim()
    }
    Join-Path $env:USERPROFILE '.grok\vibe-tools\reports\gate-open-advisories.json'
}

function Format-GateOpenAdvisoriesInject {
    param([string]$Cwd)
    if (-not $Cwd) { return '' }
    $path = Get-GateOpenAdvisoriesFile
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    } catch { return '' }
    $want = ''
    try { $want = [System.IO.Path]::GetFullPath($Cwd).TrimEnd('\', '/').ToLowerInvariant() } catch { $want = "$Cwd".TrimEnd('\', '/').ToLowerInvariant() }
    $open = @($doc.items | Where-Object {
            if (-not $_) { return $false }
            if ([string]$_.status -eq 'resolved') { return $false }
            $oc = [string]$_.cwd
            if (-not $oc) { return $false }
            try {
                $ocn = [System.IO.Path]::GetFullPath($oc).TrimEnd('\', '/').ToLowerInvariant()
            } catch { $ocn = $oc.TrimEnd('\', '/').ToLowerInvariant() }
            return $ocn -eq $want
        })
    if ($open.Count -eq 0) { return '' }
    $fmt = {
        param($a)
        $id = (([string]$a.id) -replace '[\r\n\t]', ' ').Trim()
        $title = (([string]$a.title) -replace '[\r\n\t]', ' ').Trim()
        if ($id.Length -gt 80) { $id = $id.Substring(0, 80) }
        if ($title.Length -gt 200) { $title = $title.Substring(0, 200) }
        $loc = if ($a.file) { ' ' + ((([string]$a.file) -replace '[\r\n\t]', ' ').Trim()) } else { '' }
        if ($loc.Length -gt 120) { $loc = $loc.Substring(0, 120) }
        "- $id$loc - $title"
    }
    $isLater = {
        param($a)
        $b = [string]$a.bucket
        if (-not $b) { $b = [string]$a.severity }
        return ($b -eq 'later')
    }
    $next = @($open | Where-Object { -not (& $isLater $_) })
    $later = @($open | Where-Object { & $isLater $_ })
    $out = [System.Collections.Generic.List[string]]::new()
    if ($next.Count -gt 0) {
        [void]$out.Add('OPEN NEXT (must fix in this commit; do not drop or wait for auto-fix - there is none):')
        foreach ($a in $next) { [void]$out.Add((& $fmt $a)) }
    }
    if ($later.Count -gt 0) {
        [void]$out.Add(("LATER backlog ({0} items, not blocking; doctor lists; fix when cheap):" -f $later.Count))
        foreach ($a in @($later | Select-Object -First 5)) { [void]$out.Add((& $fmt $a)) }
        if ($later.Count -gt 5) {
            [void]$out.Add(('- ... {0} more later (see doctor / gate-open-advisories.json)' -f ($later.Count - 5)))
        }
    }
    if ($out.Count -eq 0) { return '' }
    return ($out -join "`n")
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Shared gate-chat helpers (monitor, Stop hook, prompt inject).
#>

function Get-GateNowTickKey([string]$NowLine) {
    $s = "$NowLine"
    $s = $s -replace '\s*\(~\d+s\)', ''
    $s = $s -replace '\s{2,}', ' '
    return $s.Trim()
}

function Test-IsGateWaitNow([string]$NowLine) {
    $s = (Get-GateNowTickKey $NowLine) -replace '^NOW:\s+', ''
    return [bool]($s -match '(?i)^Waiting on\b')
}

function Get-GateFileRun([string[]]$Lines) {
    $run = ($Lines | Where-Object { $_ -match '^RUN:\s+\S+' } | Select-Object -First 1)
    if ($run -and $run -match '^RUN:\s+(\S+)') { return $Matches[1] }
    return ''
}

function Get-GateOpenAdvisoriesFile {
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
    $open = @($doc.items | Where-Object {
            $_ -and [string]$_.status -ne 'resolved' -and [string]$_.cwd -eq $Cwd
        })
    if ($open.Count -eq 0) { return '' }
    $lines = foreach ($a in $open) {
        $id = (([string]$a.id) -replace '[\r\n\t]', ' ').Trim()
        $title = (([string]$a.title) -replace '[\r\n\t]', ' ').Trim()
        if ($id.Length -gt 80) { $id = $id.Substring(0, 80) }
        if ($title.Length -gt 200) { $title = $title.Substring(0, 200) }
        $loc = if ($a.file) { ' ' + ((([string]$a.file) -replace '[\r\n\t]', ' ').Trim()) } else { '' }
        if ($loc.Length -gt 120) { $loc = $loc.Substring(0, 120) }
        "- $id$loc - $title"
    }
    return (@(
            'OPEN ADVISORIES (must fix in the next commit; do not drop or wait for auto-fix - there is none):'
            $lines
        ) -join "`n")
}

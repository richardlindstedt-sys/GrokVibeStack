#Requires -Version 5.1
<#
.SYNOPSIS
  Print project test commands, optionally narrowed to changed paths.

.PARAMETER Root
  Repo root (default: cwd).

.PARAMETER Paths
  Changed files. If omitted, uses `git diff --name-only HEAD` (plus unstaged).

.PARAMETER Run
  Execute the planned commands (timeout 180s each). Default: print only.

.PARAMETER Json
  Emit JSON instead of text.
#>
[CmdletBinding()]
param(
    [string]$Root = '.',
    [string[]]$Paths = @(),
    [switch]$Run,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'

try {
    $Root = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
} catch {
    Write-Error "Root not found: $Root"
    exit 1
}

$pt = Join-Path $PSScriptRoot 'run-vibe-project-tools.ps1'
if (-not (Test-Path -LiteralPath $pt)) {
    $pt = Join-Path $env:USERPROFILE '.grok\vibe-tools\scripts\run-vibe-project-tools.ps1'
}
if (-not (Test-Path -LiteralPath $pt)) {
    Write-Error "run-vibe-project-tools.ps1 missing"
    exit 1
}
. $pt

if (-not $Paths -or $Paths.Count -eq 0) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $Paths = @(
            git -C $Root diff --name-only HEAD 2>$null
            git -C $Root diff --name-only 2>$null
            git -C $Root diff --name-only --cached 2>$null
        ) | Where-Object { $_ } | Select-Object -Unique
    }
}

$plan = @(Get-VibeProjectTestPlan -Root $Root)
$rows = New-Object System.Collections.Generic.List[object]

function Add-Row([string]$Label, [string]$FilePath, [string[]]$Args) {
    if (-not $FilePath) { return }
    $cmd = $FilePath
    if ($Args -and $Args.Count) { $cmd = $FilePath + ' ' + ($Args -join ' ') }
    [void]$rows.Add([pscustomobject]@{
            Label    = $Label
            FilePath = $FilePath
            Args     = @($Args)
            Command  = $cmd
        })
}

foreach ($item in $plan) {
    Add-Row -Label ([string]$item.Label) -FilePath ([string]$item.FilePath) -Args @($item.Args)
}

# Narrow extra cmds when paths look like tests or nearby sources.
$relPaths = @($Paths | ForEach-Object {
        $p = [string]$_
        if (-not $p) { return }
        if ([System.IO.Path]::IsPathRooted($p)) {
            try {
                $full = [System.IO.Path]::GetFullPath($p)
                if ($full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
                    return $full.Substring($Root.Length).TrimStart('\', '/')
                }
            } catch {}
        }
        return ($p -replace '/', '\')
    } | Where-Object { $_ } | Select-Object -Unique)

$pyTests = New-Object System.Collections.Generic.List[string]
$goDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$rsCrate = $false
foreach ($rel in $relPaths) {
    $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
    $leaf = [System.IO.Path]::GetFileName($rel)
    if ($ext -eq '.py') {
        $cand = Join-Path $Root $rel
        if ($leaf -match '^(test_.*|.*_test)\.py$') {
            if (Test-Path -LiteralPath $cand) { [void]$pyTests.Add($cand) }
        } else {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
            foreach ($t in @(
                    (Join-Path $Root ("test_{0}.py" -f $stem)),
                    (Join-Path $Root ("{0}_test.py" -f $stem)),
                    (Join-Path $Root ("tests\test_{0}.py" -f $stem))
                )) {
                if (Test-Path -LiteralPath $t) { [void]$pyTests.Add($t) }
            }
        }
    } elseif ($ext -eq '.go') {
        $dir = Split-Path $rel -Parent
        if (-not $dir) { $dir = '.' }
        [void]$goDirs.Add($dir.Replace('\', '/'))
    } elseif ($ext -eq '.rs') {
        $rsCrate = $true
    }
}

$pytestExe = Resolve-VibeCommandPath 'pytest'
$py = Get-VibeProjectPythonExe $Root
if ($pyTests.Count -gt 0) {
    $uniq = @($pyTests | Select-Object -Unique)
    if ($py) {
        Add-Row -Label 'pytest (affected)' -FilePath $py -Args (@('-m', 'pytest', '-q', '--tb=line') + $uniq)
    } elseif ($pytestExe) {
        Add-Row -Label 'pytest (affected)' -FilePath $pytestExe -Args (@('-q', '--tb=line') + $uniq)
    }
}

$go = Resolve-VibeCommandPath 'go'
if ($go -and $goDirs.Count -gt 0) {
    $pkgs = @($goDirs | ForEach-Object { if ($_ -eq '.' -or $_ -eq '') { './...' } else { './' + $_ } })
    Add-Row -Label 'go test (affected)' -FilePath $go -Args (@('test') + $pkgs)
}

$cargo = Resolve-VibeCommandPath 'cargo'
if ($cargo -and $rsCrate -and (Test-Path -LiteralPath (Join-Path $Root 'Cargo.toml'))) {
    Add-Row -Label 'cargo test (crate)' -FilePath $cargo -Args @('test', '--quiet')
}

# Dedup by Command
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$final = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
    if ($seen.Add([string]$r.Command)) { [void]$final.Add($r) }
}

if ($Json) {
    $final | ConvertTo-Json -Depth 6
} else {
    if ($final.Count -eq 0) {
        Write-Host 'No project tests detected (no cargo/go/pytest/npm/dotnet/mvn/gradle suite).'
    } else {
        foreach ($r in $final) {
            Write-Host ("{0}: {1}" -f $r.Label, $r.Command)
        }
    }
}

if (-not $Run) { exit 0 }

$code = 0
foreach ($r in $final) {
    $timeout = Get-VibeTimeoutSec -Name 'VIBE_PROJECT_TEST_TIMEOUT' -Default 180
    Write-Host ("RUN {0}" -f $r.Label) -ForegroundColor Cyan
    $res = Invoke-VibeTimedCommand -FilePath $r.FilePath -ArgumentList @($r.Args) -WorkingDirectory $Root -TimeoutSec $timeout
    if ($res.TimedOut) {
        Write-Host ("TIMEOUT {0}" -f $r.Label) -ForegroundColor Red
        $code = 1
    } elseif ([int]$res.ExitCode -ne 0) {
        Write-Host ("FAIL {0} exit {1}" -f $r.Label, $res.ExitCode) -ForegroundColor Red
        $code = 1
    } else {
        Write-Host ("OK {0}" -f $r.Label) -ForegroundColor Green
    }
}
exit $code

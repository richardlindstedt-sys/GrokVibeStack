# checkov metadata pins asteval==1.0.6 (sandbox escape). Requirements pin 1.0.10,
# which does not solve in the same pip invocation. Solve with 1.0.6, then
# force-install 1.0.10 --no-deps. Plain pip install -r stays fail-closed.

if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    function Write-Info { param($Message) }
}
if (-not (Get-Command Write-Fail -ErrorAction SilentlyContinue)) {
    function Write-Fail { param($Message) }
}
if (-not (Get-Command Write-Ok -ErrorAction SilentlyContinue)) {
    function Write-Ok { param($Message) }
}

function Test-AstevalOverrideFileLock {
    param([string]$Text)
    if (Get-Command Test-PipFileLockText -ErrorAction SilentlyContinue) {
        return [bool](Test-PipFileLockText -Text $Text)
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [bool]($Text -match '(?i)(WinError\s*32|WinError\s*5|sharing violation|being used by another process|cannot access the file|kan inte komma |g.r inte att komma |det g.r inte att komma)')
}

function Get-CheckovAstevalInstallPlan {
    param([string]$ReqFile)
    $raw = [System.IO.File]::ReadAllText($ReqFile)
    $force = ($raw -match '(?m)^checkov(==|>=|~=)') -and ($raw -match '(?m)^asteval==1\.0\.10\s*$')
    if (-not $force) {
        return [pscustomobject]@{ SolveFile = $ReqFile; Temp = $false; ForceAsteval = $false }
    }
    $solve = [regex]::Replace($raw, '(?m)^asteval==1\.0\.10\s*$', 'asteval==1.0.6')
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('grok-vibe-req-' + [guid]::NewGuid().ToString('n') + '.txt')
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $solve, $utf8)
    return [pscustomobject]@{ SolveFile = $tmp; Temp = $true; ForceAsteval = $true }
}

function Clear-CheckovAstevalInstallPlan {
    param($Plan)
    if ($Plan -and $Plan.Temp -and $Plan.SolveFile -and (Test-Path -LiteralPath $Plan.SolveFile)) {
        Remove-Item -LiteralPath $Plan.SolveFile -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-AstevalOverrideAttempt {
    param(
        [bool]$ForcedOk,
        [int]$Attempt,
        [int]$MaxTries,
        [string]$OverrideText
    )
    if ($ForcedOk) { return 'ok' }
    if ((Test-AstevalOverrideFileLock -Text $OverrideText) -and $Attempt -lt $MaxTries) { return 'retry' }
    return 'rollback'
}

function Install-ForcedAsteval {
    param(
        [string]$PyExe,
        [ref]$PipText
    )
    Write-Info "force-install asteval==1.0.10 --no-deps (checkov metadata pins 1.0.6)"
    $ov = & $PyExe -m pip install --no-deps --upgrade 'asteval==1.0.10' 2>&1
    $code = $LASTEXITCODE
    $text = ($ov | Out-String)
    if ($PSBoundParameters.ContainsKey('PipText')) { $PipText.Value = $text }
    if ($code -ne 0) {
        Write-Fail "asteval==1.0.10 override failed (exit $code)"
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-Host $text
        }
        return $false
    }
    $probe = & $PyExe -c "import importlib.metadata as m; print(m.version('asteval'))" 2>&1
    $probeCode = $LASTEXITCODE
    $verLines = @($probe | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
    if ($probeCode -ne 0 -or $verLines.Count -ne 1 -or $verLines[0] -ne '1.0.10') {
        Write-Fail "asteval version probe failed (exit $probeCode, lines=$($verLines.Count))"
        return $false
    }
    Write-Ok "asteval 1.0.10"
    return $true
}

function Get-AstevalSitePath {
    param([string]$PyExe)
    $siteOut = & $PyExe -c "import site; print(site.getsitepackages()[0])" 2>&1
    $siteCode = $LASTEXITCODE
    if ($siteCode -ne 0) { return $null }
    $lines = @($siteOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($lines.Count -ne 1) { return $null }
    $site = $lines[0]
    if (-not (Test-Path -LiteralPath $site)) { return $null }
    return [System.IO.Path]::GetFullPath($site)
}

function Test-AstevalGone {
    param(
        [string]$PyExe,
        [string]$Site
    )
    if ([string]::IsNullOrWhiteSpace($Site) -or -not (Test-Path -LiteralPath $Site)) { return $false }
    $left = @(Get-ChildItem -LiteralPath $Site -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'asteval*' })
    if ($left.Count -gt 0) { return $false }
    $absentProbe = 'import importlib.metadata as m; exec("try:\n print(m.version(''asteval''))\nexcept m.PackageNotFoundError:\n print(''ABSENT'')")'
    $probe = & $PyExe -c $absentProbe 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { return $false }
    $lines = @($probe | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    return ($lines.Count -eq 1 -and $lines[0] -eq 'ABSENT')
}

function Remove-AstevalDist {
    param(
        [string]$PyExe,
        [string]$VenvRoot
    )
    $site = Get-AstevalSitePath -PyExe $PyExe
    if (-not $site) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($VenvRoot)) {
        $root = [System.IO.Path]::GetFullPath($VenvRoot)
        if (-not $root.EndsWith('\')) { $root = $root + '\' }
        if (-not $site.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $hits = @(Get-ChildItem -LiteralPath $site -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'asteval*' })
    foreach ($hit in $hits) {
        $full = [System.IO.Path]::GetFullPath($hit.FullName)
        if (-not $full.StartsWith($site, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $full) { return $false }
    }
    $left = @(Get-ChildItem -LiteralPath $site -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'asteval*' })
    return ($left.Count -eq 0)
}

function Undo-AstevalSolvePin {
    param(
        [string]$PyExe,
        [scriptblock]$Prepare,
        [string]$VenvRoot,
        [int]$MaxTries = 4
    )
    $lastText = ''
    $lastCode = 1
    for ($i = 1; $i -le $MaxTries; $i++) {
        if ($Prepare) { & $Prepare }
        $out = & $PyExe -m pip uninstall -y asteval 2>&1
        $lastCode = $LASTEXITCODE
        $lastText = ($out | Out-String)
        $site = Get-AstevalSitePath -PyExe $PyExe
        if ($site) { Remove-AstevalDist -PyExe $PyExe -VenvRoot $VenvRoot | Out-Null }
        if ($site -and (Test-AstevalGone -PyExe $PyExe -Site $site)) { return $true }
        if ($i -lt $MaxTries) { Start-Sleep -Seconds 1 }
    }
    if (-not [string]::IsNullOrWhiteSpace($lastText)) { Write-Host $lastText }
    Write-Fail "asteval uninstall failed (exit $lastCode); absence not proven"
    return $false
}

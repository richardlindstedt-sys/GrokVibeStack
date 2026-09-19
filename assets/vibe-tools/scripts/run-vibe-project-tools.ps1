<#
.SYNOPSIS
    Detect-and-run project compilers/tests when the toolchain is already on PATH.
.DESCRIPTION
    No SDKs are installed. Missing cargo/go/dotnet/tsc/pytest/mvn/gradle/Pester = skip that runner.
    Compile/tests need a full tree (not a staged-file snapshot).
    If a test layout exists but tests were skipped (env skip, timeout 0, or no runner),
    the gate FAILS unless VIBE_ALLOW_SKIP_TESTS=1.
    Timeout / skip env:
      VIBE_SKIP_PROJECT_TOOLS=1     skip compile + tests (FAIL if tests exist)
      VIBE_SKIP_PROJECT_COMPILE=1
      VIBE_SKIP_PROJECT_TESTS=1     FAIL if tests exist unless VIBE_ALLOW_SKIP_TESTS=1
      VIBE_ALLOW_SKIP_TESTS=1       override fail-closed skip
      VIBE_PROJECT_COMPILE_TIMEOUT  seconds (default 120; 0 = skip compile)
      VIBE_PROJECT_TEST_TIMEOUT     seconds (default 180; 0 = skip tests)
    Dot-source from run-vibe-scans.ps1 and run-vibe-on-edit.ps1.
#>

function Test-VibeEnvTruthy([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $false }
    return $v -match '^(?i)(1|true|yes)$'
}

function Get-VibeTimeoutSec {
    param([string]$Name, [int]$Default)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    $n = 0
    if ([int]::TryParse($raw, [ref]$n) -and $n -ge 0) { return $n }
    return $Default
}

function Resolve-VibeCommandPath([string]$Name) {
    # Start-Process needs a Win32 image. Node's npm.ps1/tsc.ps1 shims fail CreateProcess.
    $apps = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($c in $apps) {
        $src = [string]$c.Source
        if ($src -match '\.(exe|cmd|bat)$') { return $src }
    }
    $any = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $any -or -not $any.Source) { return $null }
    $src = [string]$any.Source
    if ($src -match '\.ps1$') {
        foreach ($ext in @('.cmd', '.exe', '.bat')) {
            $sib = [System.IO.Path]::ChangeExtension($src, $ext)
            if (Test-Path -LiteralPath $sib) { return $sib }
        }
        return $null
    }
    return $src
}

function Test-VibeRepoHasFile {
    param(
        [string]$Root,
        [string]$Filter,
        [int]$Depth = 4
    )
    $skip = '\\(\.git|node_modules|\.venv|venv|\.serena|dist|build|__pycache__)\\'
    $hit = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter -Depth $Depth -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $skip } |
        Select-Object -First 1
    return [bool]$hit
}

function Get-VibeNpmTestInvocation {
    <#
      Returns @{ FilePath; Args } or $null when the test script is missing,
      a placeholder, watch-mode, or an e2e runner we will not launch.
    #>
    param([string]$Root)
    $pkgPath = Join-Path $Root 'package.json'
    if (-not (Test-Path -LiteralPath $pkgPath)) { return $null }
    $npm = Resolve-VibeCommandPath 'npm'
    if (-not $npm) { return $null }
    try {
        $pkg = Get-Content -LiteralPath $pkgPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $null
    }
    $script = $null
    if ($pkg.scripts -and $pkg.scripts.test) { $script = [string]$pkg.scripts.test }
    if ([string]::IsNullOrWhiteSpace($script)) { return $null }
    if ($script -match '(?i)no test specified') { return $null }
    if ($script -match '(?i)\b(cypress|playwright|nightwatch|webdriver)\b') { return $null }
    if ($script -match '(?i)\bwatch\b' -and $script -notmatch '(?i)watchAll\s*=\s*false' -and $script -notmatch '(?i)\brun\b') {
        return $null
    }
    $args = @('test')
    if ($script -match '(?i)\bvitest\b' -and $script -notmatch '(?i)\brun\b') {
        $args = @('test', '--', 'run')
    } elseif ($script -match '(?i)\bjest\b' -and $script -notmatch '(?i)watchAll') {
        $args = @('test', '--', '--watchAll=false', '--ci')
    }
    return @{ FilePath = $npm; Args = $args; Label = 'npm test' }
}

function Get-VibeProjectPythonExe([string]$Root) {
    foreach ($rel in @('.venv\Scripts\python.exe', 'venv\Scripts\python.exe')) {
        $p = Join-Path $Root $rel
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return Resolve-VibeCommandPath 'python'
}

function Test-VibeHasPytestLayout([string]$Root) {
    # Python markers only. A bare tests/ dir is Go/Rust/JS-normal and must not schedule pytest.
    if (Test-Path -LiteralPath (Join-Path $Root 'pytest.ini')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Root 'conftest.py')) { return $true }
    $pyproject = Join-Path $Root 'pyproject.toml'
    if (Test-Path -LiteralPath $pyproject) {
        try {
            $raw = Get-Content -LiteralPath $pyproject -Raw -ErrorAction Stop
            if ($raw -match '(?m)^\[tool\.pytest') { return $true }
        } catch {}
    }
    $setupCfg = Join-Path $Root 'setup.cfg'
    if (Test-Path -LiteralPath $setupCfg) {
        try {
            $raw = Get-Content -LiteralPath $setupCfg -Raw -ErrorAction Stop
            if ($raw -match '(?m)^\[tool:pytest') { return $true }
        } catch {}
    }
    $toxIni = Join-Path $Root 'tox.ini'
    if (Test-Path -LiteralPath $toxIni) {
        try {
            $raw = Get-Content -LiteralPath $toxIni -Raw -ErrorAction Stop
            if ($raw -match '(?m)^\[pytest\]') { return $true }
        } catch {}
    }
    if (Test-VibeRepoHasFile -Root $Root -Filter 'conftest.py' -Depth 4) { return $true }
    if (Test-VibeRepoHasFile -Root $Root -Filter 'test_*.py' -Depth 4) { return $true }
    if (Test-VibeRepoHasFile -Root $Root -Filter '*_test.py' -Depth 4) { return $true }
    return $false
}

function Test-VibeCargoClippy {
    $cargo = Resolve-VibeCommandPath 'cargo'
    if (-not $cargo) { return $false }
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $null = & $cargo clippy -V 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-VibeProjectCompilePlan {
    param([string]$Root)
    $plan = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return @() }

    if (Test-Path -LiteralPath (Join-Path $Root 'Cargo.toml')) {
        $cargo = Resolve-VibeCommandPath 'cargo'
        if ($cargo) {
            if (Test-VibeCargoClippy) {
                [void]$plan.Add(@{ Label = 'cargo clippy'; FilePath = $cargo; Args = @('clippy', '--quiet', '--all-targets') })
            } else {
                [void]$plan.Add(@{ Label = 'cargo check'; FilePath = $cargo; Args = @('check', '--quiet', '--all-targets') })
            }
        }
    }

    if (Test-Path -LiteralPath (Join-Path $Root 'go.mod')) {
        $go = Resolve-VibeCommandPath 'go'
        if ($go) {
            [void]$plan.Add(@{ Label = 'go vet'; FilePath = $go; Args = @('vet', './...') })
        }
    }

    $tsconfig = Join-Path $Root 'tsconfig.json'
    if (Test-Path -LiteralPath $tsconfig) {
        $tsc = Resolve-VibeCommandPath 'tsc'
        if ($tsc) {
            [void]$plan.Add(@{ Label = 'tsc --noEmit'; FilePath = $tsc; Args = @('--noEmit', '--pretty', 'false', '-p', $tsconfig) })
        }
    }

    $sln = Get-ChildItem -LiteralPath $Root -Filter '*.sln' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $csproj = $null
    if (-not $sln) {
        $csproj = Get-ChildItem -LiteralPath $Root -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    $dotnet = Resolve-VibeCommandPath 'dotnet'
    if ($dotnet -and ($sln -or $csproj)) {
        $proj = if ($sln) { $sln.FullName } else { $csproj.FullName }
        [void]$plan.Add(@{ Label = 'dotnet build'; FilePath = $dotnet; Args = @('build', $proj, '--nologo', '-v', 'q') })
    }

    $mvnWrapper = Join-Path $Root 'mvnw.cmd'
    if (-not (Test-Path -LiteralPath $mvnWrapper)) { $mvnWrapper = Join-Path $Root 'mvnw' }
    $pom = Join-Path $Root 'pom.xml'
    if (Test-Path -LiteralPath $pom) {
        $mvn = $null
        if (Test-Path -LiteralPath $mvnWrapper) { $mvn = $mvnWrapper }
        else { $mvn = Resolve-VibeCommandPath 'mvn' }
        if ($mvn) {
            [void]$plan.Add(@{ Label = 'mvn compile'; FilePath = $mvn; Args = @('-q', '-DskipTests', 'compile') })
        }
    }

    $gw = Join-Path $Root 'gradlew.bat'
    if (-not (Test-Path -LiteralPath $gw)) { $gw = Join-Path $Root 'gradlew' }
    $buildGradle = $false
    foreach ($g in @('build.gradle', 'build.gradle.kts')) {
        if (Test-Path -LiteralPath (Join-Path $Root $g)) { $buildGradle = $true; break }
    }
    if ($buildGradle) {
        $gradle = $null
        if (Test-Path -LiteralPath $gw) { $gradle = $gw }
        else { $gradle = Resolve-VibeCommandPath 'gradle' }
        if ($gradle) {
            [void]$plan.Add(@{ Label = 'gradle classes'; FilePath = $gradle; Args = @('classes', '-q') })
        }
    }

    return @($plan)
}

function Get-VibeProjectTestPlan {
    param([string]$Root)
    $plan = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return @() }

    if (Test-Path -LiteralPath (Join-Path $Root 'Cargo.toml')) {
        $cargo = Resolve-VibeCommandPath 'cargo'
        if ($cargo) {
            [void]$plan.Add(@{ Label = 'cargo test'; FilePath = $cargo; Args = @('test', '--quiet') })
        }
    }

    if (Test-Path -LiteralPath (Join-Path $Root 'go.mod')) {
        $go = Resolve-VibeCommandPath 'go'
        if ($go) {
            [void]$plan.Add(@{ Label = 'go test'; FilePath = $go; Args = @('test', './...') })
        }
    }

    if (Test-VibeHasPytestLayout $Root) {
        $py = Get-VibeProjectPythonExe $Root
        $pytestExe = Resolve-VibeCommandPath 'pytest'
        $usePyMod = $false
        if ($py) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $null = & $py -c 'import pytest' 2>&1
                $usePyMod = ($LASTEXITCODE -eq 0)
            } catch { $usePyMod = $false }
            finally { $ErrorActionPreference = $prev }
        }
        if ($usePyMod) {
            [void]$plan.Add(@{ Label = 'pytest'; FilePath = $py; Args = @('-m', 'pytest', '-q', '--tb=line') })
        } elseif ($pytestExe) {
            [void]$plan.Add(@{ Label = 'pytest'; FilePath = $pytestExe; Args = @('-q', '--tb=line') })
        }
    }

    $npmInv = Get-VibeNpmTestInvocation -Root $Root
    if ($npmInv) { [void]$plan.Add($npmInv) }

    $sln = Get-ChildItem -LiteralPath $Root -Filter '*.sln' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $csproj = $null
    if (-not $sln) {
        $csproj = Get-ChildItem -LiteralPath $Root -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    $dotnet = Resolve-VibeCommandPath 'dotnet'
    if ($dotnet -and ($sln -or $csproj)) {
        $proj = if ($sln) { $sln.FullName } else { $csproj.FullName }
        [void]$plan.Add(@{ Label = 'dotnet test'; FilePath = $dotnet; Args = @('test', $proj, '--nologo', '-v', 'q') })
    }

    $mvnWrapper = Join-Path $Root 'mvnw.cmd'
    if (-not (Test-Path -LiteralPath $mvnWrapper)) { $mvnWrapper = Join-Path $Root 'mvnw' }
    if (Test-Path -LiteralPath (Join-Path $Root 'pom.xml')) {
        $mvn = $null
        if (Test-Path -LiteralPath $mvnWrapper) { $mvn = $mvnWrapper }
        else { $mvn = Resolve-VibeCommandPath 'mvn' }
        if ($mvn) {
            [void]$plan.Add(@{ Label = 'mvn test'; FilePath = $mvn; Args = @('-q', 'test') })
        }
    }

    $gw = Join-Path $Root 'gradlew.bat'
    if (-not (Test-Path -LiteralPath $gw)) { $gw = Join-Path $Root 'gradlew' }
    $buildGradle = $false
    foreach ($g in @('build.gradle', 'build.gradle.kts')) {
        if (Test-Path -LiteralPath (Join-Path $Root $g)) { $buildGradle = $true; break }
    }
    if ($buildGradle) {
        $gradle = $null
        if (Test-Path -LiteralPath $gw) { $gradle = $gw }
        else { $gradle = Resolve-VibeCommandPath 'gradle' }
        if ($gradle) {
            [void]$plan.Add(@{ Label = 'gradle test'; FilePath = $gradle; Args = @('test', '-q') })
        }
    }

    $pTest = Get-ChildItem -LiteralPath $Root -Recurse -Include *.Tests.ps1,*Spec.ps1 -File -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(?i)[\\/](node_modules|\.git|venv|\.venv|\.serena)[\\/]' } |
        Select-Object -First 1
    if ($pTest -and (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        $hostExe = $null
        try { $hostExe = (Get-Process -Id $PID).Path } catch { $hostExe = $null }
        if (-not $hostExe) { $hostExe = Join-Path $PSHOME 'pwsh.exe' }
        if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = Join-Path $PSHOME 'powershell.exe' }
        if (-not (Test-Path -LiteralPath $hostExe)) {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($pwsh) { $hostExe = $pwsh.Source }
        }
        if (-not (Test-Path -LiteralPath $hostExe)) {
            $ps = Get-Command powershell.exe -ErrorAction SilentlyContinue
            if ($ps) { $hostExe = $ps.Source }
        }
        if ($hostExe -and (Test-Path -LiteralPath $hostExe)) {
            $esc = $Root.Replace("'", "''")
            $cmd = "`$ErrorActionPreference='Continue'; Import-Module Pester -ErrorAction Stop; `$c=New-PesterConfiguration; `$c.Run.Path='$esc'; `$c.Run.Exit=`$true; `$c.Output.Verbosity='Normal'; Invoke-Pester -Configuration `$c"
            [void]$plan.Add(@{ Label = 'pester'; FilePath = $hostExe; Args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) })
        }
    }

    return @($plan)
}

function Test-VibeRepoHasTestLayout {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Root 'Cargo.toml')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Root 'go.mod')) { return $true }
    if (Test-VibeHasPytestLayout $Root) { return $true }
    if (Get-VibeNpmTestInvocation -Root $Root) { return $true }
    if (Get-ChildItem -LiteralPath $Root -Filter '*.sln' -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true }
    if (Get-ChildItem -LiteralPath $Root -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Root 'pom.xml')) { return $true }
    foreach ($g in @('build.gradle', 'build.gradle.kts')) {
        if (Test-Path -LiteralPath (Join-Path $Root $g)) { return $true }
    }
    $pTest = Get-ChildItem -LiteralPath $Root -Recurse -Include *.Tests.ps1,*Spec.ps1 -File -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(?i)[\\/](node_modules|\.git|venv|\.venv|\.serena)[\\/]' } |
        Select-Object -First 1
    if ($pTest) { return $true }
    return $false
}

function Invoke-VibeTimedCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [int]$TimeoutSec,
        [int]$TailLines = 40
    )
    $result = @{ ExitCode = -1; TimedOut = $false; Output = @() }
    if (-not (Test-Path -LiteralPath $FilePath) -and -not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        $result.ExitCode = 127
        $result.Output = @("missing executable: $FilePath")
        return $result
    }
    $outDir = Join-Path ([System.IO.Path]::GetTempPath()) ('vibe-pt-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
    New-Item -ItemType Directory -Path $outDir | Out-Null
    $stdout = Join-Path $outDir 'out.txt'
    $stderr = Join-Path $outDir 'err.txt'
    $argList = @($ArgumentList)
    $timeoutMs = [Math]::Max(1, $TimeoutSec) * 1000
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $argList -WorkingDirectory $WorkingDirectory `
            -NoNewWindow -PassThru -Wait:$false -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not $p) {
            $result.ExitCode = 127
            $result.Output = @("failed to start: $FilePath")
            return $result
        }
        if (-not $p.WaitForExit($timeoutMs)) {
            $result.TimedOut = $true
            try {
                $tk = Get-Command taskkill.exe -ErrorAction SilentlyContinue
                if ($tk) {
                    $null = & $tk.Source /PID $p.Id /T /F 2>&1
                } else {
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            try { $p.WaitForExit(3000) | Out-Null } catch {}
            $result.ExitCode = 124
        } else {
            $result.ExitCode = [int]$p.ExitCode
        }
        $lines = @()
        foreach ($f in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $f) {
                $lines += @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)
            }
        }
        if ($lines.Count -gt $TailLines) {
            $result.Output = @($lines | Select-Object -Last $TailLines)
        } else {
            $result.Output = @($lines)
        }
    } catch {
        $result.ExitCode = 1
        $result.Output = @("$_")
    } finally {
        $ErrorActionPreference = $prev
        Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Invoke-VibeProjectToolPlan {
    param(
        [object[]]$Plan,
        [string]$Root,
        [int]$TimeoutSec,
        [switch]$Quiet,
        [string]$Kind
    )
    $failed = 0
    $advisory = 0
    foreach ($item in @($Plan)) {
        if (-not $item) { continue }
        $label = [string]$item.Label
        if (-not $Quiet) {
            Write-Host ("`n[{0}] {1}" -f $Kind, $label) -ForegroundColor Cyan
        }
        if (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
            Write-GateProgress ("{0}: {1}..." -f $Kind, $label) -Now ("$Kind : $label") -Phase 'scans'
        }
        $run = Invoke-VibeTimedCommand -FilePath $item.FilePath -ArgumentList $item.Args `
            -WorkingDirectory $Root -TimeoutSec $TimeoutSec
        if (-not $Quiet -and $run.Output) {
            @($run.Output) | ForEach-Object { $_ }
        }
        if ($run.TimedOut) {
            $failed++
            if (-not $Quiet) {
                $toEnv = 'VIBE_PROJECT_COMPILE_TIMEOUT'
                if ($Kind -eq 'test') { $toEnv = 'VIBE_PROJECT_TEST_TIMEOUT' }
                Write-Host ("[{0}] timed out after {1}s (FAIL; raise {2})" -f $label, $TimeoutSec, $toEnv) -ForegroundColor Yellow
            }
        } elseif ($run.ExitCode -ne 0) {
            $failed++
            if (-not $Quiet) {
                Write-Host ("[{0}] exited {1}" -f $label, $run.ExitCode) -ForegroundColor Yellow
            }
        } elseif (Get-Command Write-GateProgress -ErrorAction SilentlyContinue) {
            Write-GateProgress ("{0}: {1} ok" -f $Kind, $label)
        }
    }
    return @{ Failed = $failed; Advisory = $advisory }
}

function Invoke-VibeProjectCompileAndTests {
    <#
      Returns @{ Failed; Advisory }. Caller adds those to $script:failed / $script:advisory.
    #>
    param(
        [string]$Root,
        [ValidateSet('Compile', 'Test', 'Both')]
        [string]$Mode = 'Both',
        [switch]$Quiet
    )
    $failed = 0
    $advisory = 0
    $wantTests = ($Mode -eq 'Test' -or $Mode -eq 'Both')
    $hasLayout = $wantTests -and (Test-VibeRepoHasTestLayout $Root)
    $allowSkip = Test-VibeEnvTruthy 'VIBE_ALLOW_SKIP_TESTS'
    if (Test-VibeEnvTruthy 'VIBE_SKIP_PROJECT_TOOLS') {
        if ($hasLayout -and -not $allowSkip) {
            if (-not $Quiet) { Write-Host '[project-tools] FAIL: tests exist but VIBE_SKIP_PROJECT_TOOLS (set VIBE_ALLOW_SKIP_TESTS=1 to override)' -ForegroundColor Yellow }
            return @{ Failed = 1; Advisory = 0 }
        }
        if (-not $Quiet) { Write-Host '[project-tools] skipped (VIBE_SKIP_PROJECT_TOOLS)' -ForegroundColor DarkGray }
        return @{ Failed = 0; Advisory = 0 }
    }
    $doCompile = ($Mode -eq 'Compile' -or $Mode -eq 'Both') -and -not (Test-VibeEnvTruthy 'VIBE_SKIP_PROJECT_COMPILE')
    $doTest = $wantTests -and -not (Test-VibeEnvTruthy 'VIBE_SKIP_PROJECT_TESTS')
    $compileTimeout = Get-VibeTimeoutSec 'VIBE_PROJECT_COMPILE_TIMEOUT' 120
    $testTimeout = Get-VibeTimeoutSec 'VIBE_PROJECT_TEST_TIMEOUT' 180
    if ($compileTimeout -le 0) { $doCompile = $false }
    if ($testTimeout -le 0) { $doTest = $false }

    if ($doCompile) {
        $cPlan = @(Get-VibeProjectCompilePlan -Root $Root)
        if ($cPlan.Count -eq 0) {
            if (-not $Quiet) { Write-Host '[compile] no project toolchain detected (skip)' -ForegroundColor DarkGray }
        } else {
            $r = Invoke-VibeProjectToolPlan -Plan $cPlan -Root $Root -TimeoutSec $compileTimeout -Quiet:$Quiet -Kind 'compile'
            $failed += [int]$r.Failed
            $advisory += [int]$r.Advisory
        }
    }
    if ($doTest) {
        $tPlan = @(Get-VibeProjectTestPlan -Root $Root)
        if ($tPlan.Count -eq 0) {
            if ($hasLayout -and -not $allowSkip) {
                $failed++
                if (-not $Quiet) { Write-Host '[test] FAIL: test layout present but no runner on PATH (set VIBE_ALLOW_SKIP_TESTS=1 to override)' -ForegroundColor Yellow }
            } elseif (-not $Quiet) {
                Write-Host '[test] no project test runner detected (skip)' -ForegroundColor DarkGray
            }
        } else {
            $r = Invoke-VibeProjectToolPlan -Plan $tPlan -Root $Root -TimeoutSec $testTimeout -Quiet:$Quiet -Kind 'test'
            $failed += [int]$r.Failed
            $advisory += [int]$r.Advisory
        }
    } elseif ($hasLayout -and -not $allowSkip) {
        $failed++
        if (-not $Quiet) { Write-Host '[test] FAIL: tests exist but skipped (VIBE_SKIP_PROJECT_TESTS or timeout 0). Set VIBE_ALLOW_SKIP_TESTS=1 to override.' -ForegroundColor Yellow }
    }
    return @{ Failed = $failed; Advisory = $advisory }
}

function Invoke-VibeOnEditFileLinters {
    <#
      Cheap per-file linters when the binary exists. Returns string[] findings.
    #>
    param([string]$FullPath)
    $hits = New-Object System.Collections.ArrayList
    if (-not $FullPath -or -not (Test-Path -LiteralPath $FullPath)) { return @() }
    $ext = [System.IO.Path]::GetExtension($FullPath).ToLowerInvariant()

    if ($ext -eq '.rs') {
        $rf = Resolve-VibeCommandPath 'rustfmt'
        if ($rf) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $out = & $rf --check --edition 2021 $FullPath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $msg = "[rustfmt] $FullPath needs format"
                    [void]$hits.Add($msg)
                    if ($out) { @($out | Select-Object -First 6) | ForEach-Object { [void]$hits.Add("[rustfmt] $_") } }
                }
            } finally { $ErrorActionPreference = $prev }
        }
    }

    if ($ext -eq '.go') {
        $gofmt = Resolve-VibeCommandPath 'gofmt'
        if ($gofmt) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $listed = & $gofmt -l $FullPath 2>&1
                if ("$listed".Trim()) {
                    [void]$hits.Add("[gofmt] $FullPath needs format")
                }
            } finally { $ErrorActionPreference = $prev }
        }
        $go = Resolve-VibeCommandPath 'go'
        if ($go) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $vet = & $go vet $FullPath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    [void]$hits.Add("[go vet] $FullPath")
                    @($vet | Select-Object -First 8) | ForEach-Object { [void]$hits.Add("[go vet] $_") }
                }
            } finally { $ErrorActionPreference = $prev }
        }
    }

    if ($ext -in @('.cs')) {
        $dotnet = Resolve-VibeCommandPath 'dotnet'
        if ($dotnet) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $out = & $dotnet format --include $FullPath --verify-no-changes --severity warn 2>&1
                if ($LASTEXITCODE -ne 0) {
                    [void]$hits.Add("[dotnet format] $FullPath")
                    @($out | Select-Object -First 6) | ForEach-Object { [void]$hits.Add("[dotnet format] $_") }
                }
            } finally { $ErrorActionPreference = $prev }
        }
    }

    foreach ($d in @(Get-VibeOnEditDiagnostics -FullPath $FullPath)) {
        [void]$hits.Add($d)
    }

    return @($hits | Select-Object -First 10)
}

function Get-VibeOnEditDiagnostics {
    <#
      Cheap parse/type diagnostics for the edited path. Cap 10 lines. Fail-open.
      Serena MCP stays in-session; this hook uses language parsers so the agent sees errors next prompt.
    #>
    param([string]$FullPath)
    $hits = New-Object System.Collections.ArrayList
    if (-not $FullPath -or -not (Test-Path -LiteralPath $FullPath)) { return @() }
    $ext = [System.IO.Path]::GetExtension($FullPath).ToLowerInvariant()
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($ext -in @('.ps1', '.psm1', '.psd1')) {
            $tok = $null
            $err = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($FullPath, [ref]$tok, [ref]$err)
            foreach ($e in @($err | Select-Object -First 8)) {
                $ln = 0
                try { $ln = [int]$e.Extent.StartLineNumber } catch {}
                [void]$hits.Add(('[psparse] {0}:{1} {2}' -f $FullPath, $ln, [string]$e.Message))
            }
        }
        if ($ext -eq '.py') {
            $py = Get-VibeProjectPythonExe (Split-Path -Parent $FullPath)
            if (-not $py) { $py = Resolve-VibeCommandPath 'python' }
            if ($py) {
                $out = & $py -m py_compile $FullPath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    foreach ($l in @($out | Select-Object -First 6)) {
                        [void]$hits.Add("[py_compile] $l")
                    }
                }
            }
        }
        if ($ext -in @('.js', '.mjs', '.cjs')) {
            $node = Resolve-VibeCommandPath 'node'
            if ($node) {
                $out = & $node --check $FullPath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    foreach ($l in @($out | Select-Object -First 6)) {
                        [void]$hits.Add("[node --check] $l")
                    }
                }
            }
        }
    } catch {}
    finally { $ErrorActionPreference = $prev }
    return @($hits | Select-Object -First 10)
}

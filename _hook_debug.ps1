$ErrorActionPreference = 'Continue'
$hooksDir = Join-Path $env:USERPROFILE '.grok\hooks'
Write-Host "=== LIVE HOOKS ==="
Get-ChildItem $hooksDir -Filter *.json | ForEach-Object {
    Write-Host "`n---- $($_.Name) ----"
    Get-Content $_.FullName -Raw
}

Write-Host "`n=== TEST serena wrap on read_file ==="
$wrap = Join-Path $env:USERPROFILE '.grok\token-saving\scripts\run-serena-hook.ps1'
"wrap exists: $(Test-Path $wrap)"
$payload = @{
    hookEventName  = 'pre_tool_use'
    sessionId      = 'debug-session-1'
    cwd            = (Get-Location).Path
    workspaceRoot  = (Get-Location).Path
    permissionMode = 'always-approve'
    toolName       = 'read_file'
    toolInput      = @{ target_file = 'README.md'; path = 'README.md' }
    timestamp      = (Get-Date -Format o)
} | ConvertTo-Json -Compress -Depth 6

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$wrap`" -Action remind -Client grok"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$p = [Diagnostics.Process]::Start($psi)
$p.StandardInput.Write($payload)
$p.StandardInput.Close()
$out = $p.StandardOutput.ReadToEnd()
$err = $p.StandardError.ReadToEnd()
$ok = $p.WaitForExit(15000)
"waited=$ok exit=$($p.ExitCode)"
"stdout=[$out]"
"stderr=[$err]"

Write-Host "`n=== TEST bare serena (control) ==="
$exe = Join-Path $env:USERPROFILE '.local\bin\serena-hooks.exe'
$psi2 = New-Object System.Diagnostics.ProcessStartInfo
$psi2.FileName = $exe
$psi2.Arguments = 'remind --client=grok'
$psi2.RedirectStandardInput = $true
$psi2.RedirectStandardOutput = $true
$psi2.RedirectStandardError = $true
$psi2.UseShellExecute = $false
$p2 = [Diagnostics.Process]::Start($psi2)
$p2.StandardInput.Write($payload)
$p2.StandardInput.Close()
$o2 = $p2.StandardOutput.ReadToEnd()
$e2 = $p2.StandardError.ReadToEnd()
$p2.WaitForExit(15000) | Out-Null
"bare exit=$($p2.ExitCode) stdout=[$o2] stderr=[$e2]"

Write-Host "`n=== ALL PreToolUse matchers that hit read_file ==="
Get-ChildItem $hooksDir -Filter *.json | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $pre = $j.hooks.PreToolUse
    if ($pre) {
        foreach ($g in @($pre)) {
            "file=$($_.Name) matcher=$($g.matcher) cmd=$($g.hooks[0].command) timeout=$($g.hooks[0].timeout)"
        }
    }
}

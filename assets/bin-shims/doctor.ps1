<#
Convenience launcher.
Runs stack doctor (proxy, hooks, gate profile hints, latest report).
#>
& "$env:USERPROFILE\.grok\token-saving\scripts\doctor.ps1" @args
exit $LASTEXITCODE

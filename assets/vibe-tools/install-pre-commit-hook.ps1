<#
Convenience shim.
Installs vibe hooks (pre-commit + pre-push + Grok on-edit) into the target repo.
#>
& "$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1" @args
exit $LASTEXITCODE

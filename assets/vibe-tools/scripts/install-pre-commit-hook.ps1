<#
.SYNOPSIS
    Installs vibe git hooks (pre-commit + pre-push) and Grok on-edit hook.
.DESCRIPTION
    Compatibility entrypoint. Delegates to install-vibe-hooks.ps1.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$RepoPath = '.'
)

& "$PSScriptRoot\install-vibe-hooks.ps1" -RepoPath $RepoPath

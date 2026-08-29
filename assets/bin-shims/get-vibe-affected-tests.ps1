<# Convenience launcher: print (or -Run) tests for this repo / changed paths. #>
& "$env:USERPROFILE\.grok\vibe-tools\scripts\Get-VibeAffectedTests.ps1" @args
exit $LASTEXITCODE

# Thin shim - real logic lives under token-saving/scripts
& "$env:USERPROFILE\.grok\token-saving\scripts\start-grok.ps1" @args
exit $LASTEXITCODE
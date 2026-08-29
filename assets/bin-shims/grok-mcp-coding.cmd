@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.grok\token-saving\scripts\Enable-GrokCodingMcp.ps1" %*
exit /b %ERRORLEVEL%

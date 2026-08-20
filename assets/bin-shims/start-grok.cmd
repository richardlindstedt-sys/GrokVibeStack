@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.grok\token-saving\scripts\start-grok.ps1" %*
exit /b %ERRORLEVEL%

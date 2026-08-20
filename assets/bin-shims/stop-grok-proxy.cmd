@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.grok\token-saving\scripts\start-grok.ps1" -StopProxy
exit /b %ERRORLEVEL%

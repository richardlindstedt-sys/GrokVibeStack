@echo off
set "SCRIPTS=%USERPROFILE%\.grok\token-saving\venv\Scripts"
set "PATH=%SCRIPTS%;%PATH%"
"%SCRIPTS%\headroom.exe" mcp serve %*

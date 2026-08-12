@echo off
REM Drive checkov via vibe-tools venv python (upstream checkov.cmd picks PATH python and breaks).
set "VIBE_PY=%USERPROFILE%\.grok\vibe-tools\venv\Scripts\python.exe"
if not exist "%VIBE_PY%" (
  echo checkov: missing %VIBE_PY% 1>&2
  exit /b 1
)
set "LAUNCHER=%TEMP%\vibe-checkov-run-%RANDOM%%RANDOM%.py"
> "%LAUNCHER%" echo import sys
>>"%LAUNCHER%" echo from checkov.main import Checkov
>>"%LAUNCHER%" echo sys.argv[0] = "checkov"
>>"%LAUNCHER%" echo raise SystemExit(Checkov().run())
"%VIBE_PY%" "%LAUNCHER%" %*
set "EC=%ERRORLEVEL%"
del "%LAUNCHER%" >nul 2>&1
exit /b %EC%

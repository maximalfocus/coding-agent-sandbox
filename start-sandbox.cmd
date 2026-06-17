@echo off
setlocal
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0run.ps1"
if errorlevel 1 (
  echo.
  echo Sandbox start failed. Read the message above, then run setup-windows.cmd if this is the first run.
  pause
)

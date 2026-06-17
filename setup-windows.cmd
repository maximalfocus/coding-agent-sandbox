@echo off
setlocal
cd /d "%~dp0"

REM Installing WSL2 + Docker Desktop needs administrator rights. If we're not elevated,
REM relaunch this script through UAC so a fresh machine is truly one-click.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  powershell -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1" -InstallPrereqs
if errorlevel 1 (
  echo.
  echo Setup failed. Read the message above, then run this file again.
  pause
) else (
  echo.
  echo Done. This window can be closed.
  pause
)

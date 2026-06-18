@echo off
setlocal
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0skills-setup.ps1" %*
if errorlevel 1 (
  echo.
  echo Skills setup failed. Read the message above, then try again.
  pause
)

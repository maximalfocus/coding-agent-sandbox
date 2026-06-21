@echo off
setlocal
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0gh-login.ps1"
if errorlevel 1 (
  echo.
  echo GitHub CLI login failed. Read the message above, then try again.
  pause
)

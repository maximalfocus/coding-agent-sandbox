@echo off
setlocal
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0codex-login.ps1"
if errorlevel 1 (
  echo.
  echo Codex login failed. Read the message above, then try again.
  pause
)

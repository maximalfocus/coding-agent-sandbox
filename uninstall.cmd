@echo off
setlocal
cd /d "%~dp0"

REM Remove sandbox-owned Docker resources while preserving this repository checkout.
REM Uninstalling Docker Desktop itself needs administrator rights; the script will tell you to
REM re-run from an elevated prompt if engine removal is requested without it. All other teardown
REM (containers/images/volumes/network) works without elevation.
REM Pass flags straight through, e.g.:  uninstall.cmd -Yes   |   uninstall.cmd -KeepDockerEngine
powershell -ExecutionPolicy Bypass -File "%~dp0uninstall-windows.ps1" %*
if errorlevel 1 (
  echo.
  echo Uninstall reported a problem. Read the message above.
  pause
)

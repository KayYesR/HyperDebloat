@echo off
rem Double-click to run HyperDebloat. Keep this file next to HyperDebloat.ps1.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0HyperDebloat.ps1" %*
echo.
pause

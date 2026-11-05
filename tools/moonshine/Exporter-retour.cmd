@echo off
setlocal
set "OPI5_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "OPI5_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%OPI5_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bootstrap.ps1" -Action Export
echo.
pause
endlocal

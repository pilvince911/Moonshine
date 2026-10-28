@echo off
setlocal DisableDelayedExpansion
set "OPI5_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "OPI5_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "OPI5_BOOT=%~dp0Bootstrap.ps1"
if not exist "%OPI5_BOOT%" set "OPI5_BOOT=%LOCALAPPDATA%\OPi5\VibeShine-Xbox\Packages\1.0.0\Bootstrap.ps1"
if not exist "%OPI5_BOOT%" (
  echo Programme incomplet. Reextraire tout le ZIP OPi5 1.0.0.
  pause
  exit /b 1
)
start "" "%OPI5_PS%" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%OPI5_BOOT%" -Action Desktop
endlocal

@echo off
setlocal
if not exist "%~dp0Moonshine.exe" (
  echo Extraire le ZIP Moonshine au complet, puis ouvrir Moonshine.exe.
  pause
  exit /b 1
)
start "" "%~dp0Moonshine.exe"
endlocal

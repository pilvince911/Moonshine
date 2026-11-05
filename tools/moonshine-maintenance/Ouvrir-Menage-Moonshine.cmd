@echo off
setlocal
set "MOONSHINE_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "MOONSHINE_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "MOONSHINE_CLEANUP=%~dp0Nettoyer-Moonshine.ps1"
"%MOONSHINE_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; $script=$env:MOONSHINE_CLEANUP; if ($script.Contains([char]34)) { throw 'Chemin invalide.' }; $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File '+[char]34+$script+[char]34+' -OwnerSid '+$owner; try { $p=Start-Process -FilePath $env:MOONSHINE_PS -ArgumentList $arguments -Verb RunAs -Wait -PassThru; exit $p.ExitCode } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 pause
endlocal

#Requires -Version 5.1
param([Parameter(Mandatory=$true)][ValidateSet('Install','Start','Stop','Drivers','Remove')][string]$Action,[Parameter(Mandatory=$true)][ValidatePattern('^S-1-(5-21|12-1)-[0-9-]+$')][string]$OwnerSid,[switch]$Migrate,[switch]$Automatic)
$ErrorActionPreference='Stop';$lock=$null
try {
    . (Join-Path $PSScriptRoot 'Installation.ps1')
    . (Join-Path $PSScriptRoot 'Pilotes.ps1')
    Assert-MoonshineAdmin
    $lock=[IO.File]::Open((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine.setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    switch ($Action) {
        'Install' { $null=Install-MoonshineZip $PSScriptRoot $OwnerSid -Migrate:$Migrate -Automatic:$Automatic }
        'Stop' { Stop-MoonshineSelectedService $OwnerSid }
        'Start' { $receipt=Read-MoonshineServiceReceipt;if ($receipt.owner_sid -cne $OwnerSid) {throw 'Compte different de celui de l installation.'};Start-MoonshineService }
        'Drivers' { $null=Install-MoonshineDrivers $OwnerSid }
        'Remove' {
            $receipt=Read-MoonshineServiceReceipt
            if ($receipt.owner_sid -cne $OwnerSid) { throw 'Compte different de celui de l installation.' }
            Assert-MoonshineSetupIdle;Remove-MoonshineService
            $link=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Moonshine.lnk'
            if ([IO.File]::Exists($link)) {
                $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($link)
                if ($shortcut.TargetPath -ieq (Join-Path $script:MoonshineServiceRoot 'Kit\Ouvrir-Moonshine.cmd')) { Remove-Item -LiteralPath $link -Force }
            }
        }
    }
} catch {
    Add-Type -AssemblyName PresentationFramework
    $null=[Windows.MessageBox]::Show($_.Exception.Message,'Moonshine - operation suspendue',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning)
    exit 1
} finally { if ($lock) { $lock.Dispose() } }

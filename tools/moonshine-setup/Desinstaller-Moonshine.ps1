#Requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
try {
    . (Join-Path $PSScriptRoot 'Installation.ps1')
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $admin=(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { & (Join-Path $PSScriptRoot 'Gestion-Moonshine.ps1') -Uninstall;return }
    # Windows Installed Apps may already have elevated its uninstaller.
    # No elevated tray is kept alive; bind only to the protected installed receipt.
    $receipt=Read-MoonshineServiceReceipt
    if ([Windows.MessageBox]::Show('Desinstaller Moonshine? Terminer les streams et arreter son service avant de continuer. Une sauvegarde privee sera verifiee. Bibliotheque et pilotes seront conserves.','Moonshine',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -ne [Windows.MessageBoxResult]::Yes) { return }
    $result=Uninstall-MoonshineInstalled $receipt.owner_sid
    $null=[Windows.MessageBox]::Show(('Moonshine est desinstalle. Archive privee : '+$result.path),'Moonshine')
} catch {$null=[Windows.MessageBox]::Show($_.Exception.Message,'Moonshine - retrait suspendu',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning);exit 1}

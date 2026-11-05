#Requires -Version 5.1
param([Parameter(Mandatory=$true)][ValidateSet('Install','Start','Stop','Return')][string]$Action,[Parameter(Mandatory=$true)][ValidatePattern('^S-1-(5-21|12-1)-[0-9-]+$')][string]$OwnerSid,[ValidatePattern('^[a-f0-9]{32}$')][string]$TrialId)
$ErrorActionPreference='Stop'
$setupLock=$null
try {
    . (Join-Path $PSScriptRoot 'Service-Setup.ps1')
    Assert-MoonshineAdmin
    $setupLock=[IO.File]::Open((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine-Preview.setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if ($Action -ne 'Install') {
        $receipt=Read-MoonshineServiceReceipt
        if ($receipt.owner_sid -cne $OwnerSid) { throw 'Ce service appartient à un autre compte Windows.' }
    }
    switch ($Action) {
        'Install' { $null=Install-MoonshineService $PSScriptRoot $OwnerSid $TrialId;Start-MoonshineService }
        'Start' { Start-MoonshineService }
        'Stop' { Stop-MoonshineService }
        'Return' { Remove-MoonshineService -ReturnToVibeShine }
    }
} catch {
    Add-Type -AssemblyName PresentationFramework
    $null=[Windows.MessageBox]::Show($_.Exception.Message,'Moonshine Service — action suspendue',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning)
    exit 1
} finally { if ($setupLock) { $setupLock.Dispose() } }

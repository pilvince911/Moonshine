#Requires -Version 5.1
param([Parameter(Mandatory=$true)][ValidateSet('Install','Repair','Start','Stop','Drivers','Backup','Diagnostic','Uninstall','Remove')][string]$Action,[Parameter(Mandatory=$true)][ValidatePattern('^S-1-(5-21|12-1)-[0-9-]+$')][string]$OwnerSid,[ValidatePattern('^[a-f0-9]{32}$')][string]$OperationId,[switch]$Migrate,[switch]$Automatic)
$ErrorActionPreference='Stop';$lock=$null;$operationFolder=$null;$outcome=$null;$exitCode=0
try {
    . (Join-Path $PSScriptRoot 'Installation.ps1')
    . (Join-Path $PSScriptRoot 'Pilotes.ps1')
    Assert-MoonshineAdmin
    [Environment]::CurrentDirectory=$env:WINDIR;Set-Location -LiteralPath $env:WINDIR
    if ($OperationId) { $operationFolder=Initialize-MoonshineOperation $OwnerSid $OperationId }
    $script:MoonshineSetupProgress={param([int]$Percent,[string]$Message) if ($operationFolder) { Write-MoonshineOperation $operationFolder $OwnerSid $OperationId $Action 'running' $Percent $Message }}
    & $script:MoonshineSetupProgress 2 'Verification des conditions de l operation...'
    $lock=[IO.File]::Open((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine.setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    switch ($Action) {
        'Install' { $receipt=Install-MoonshineZip $PSScriptRoot $OwnerSid -Migrate:$Migrate -Automatic:$Automatic;$outcome=@{version=$receipt.version} }
        'Repair' {
            $receipt=Read-MoonshineServiceReceipt
            if ($receipt.owner_sid -cne $OwnerSid) { throw 'Cette installation appartient a un autre compte.' }
            $service=Get-MoonshineOwnedService;$automaticMode=$service -and $service.StartMode -eq 'Auto'
            $receipt=Install-MoonshineZip $PSScriptRoot $OwnerSid -Automatic:$automaticMode;$outcome=@{version=$receipt.version}
        }
        'Stop' { & $script:MoonshineSetupProgress 30 'Arret propre du service et restauration de l affichage...';Stop-MoonshineSelectedService $OwnerSid }
        'Start' { $receipt=Read-MoonshineServiceReceipt;if ($receipt.owner_sid -cne $OwnerSid) {throw 'Compte different de celui de l installation.'};& $script:MoonshineSetupProgress 30 'Verification du programme et demarrage du service...';Start-MoonshineService }
        'Drivers' { $outcome=Install-MoonshineDrivers $OwnerSid }
        'Backup' { & $script:MoonshineSetupProgress 20 'Copie privee et verification des empreintes...';$outcome=Backup-MoonshineInstalled $OwnerSid }
        'Diagnostic' { if (-not $operationFolder) {throw 'Cette operation doit etre lancee depuis l icone Moonshine.'};& $script:MoonshineSetupProgress 30 'Preparation du diagnostic sans identifiants...';$outcome=Export-MoonshineSetupDiagnostic $OwnerSid $operationFolder }
        'Uninstall' { & $script:MoonshineSetupProgress 15 'Sauvegarde privee avant le retrait...';$outcome=Uninstall-MoonshineInstalled $OwnerSid }
        'Remove' { $receipt=Read-MoonshineServiceReceipt;if($receipt.owner_sid -cne $OwnerSid){throw 'Compte different.'};Assert-MoonshineSetupIdle;Remove-MoonshineService }
    }
    if ($operationFolder) { Write-MoonshineOperation $operationFolder $OwnerSid $OperationId $Action 'completed' 100 'Operation terminee.' $outcome }
} catch {
    $exitCode=1
    if ($operationFolder) { try { Write-MoonshineOperation $operationFolder $OwnerSid $OperationId $Action 'failed' 0 $_.Exception.Message } catch { } }
    Add-Type -AssemblyName PresentationFramework
    $null=[Windows.MessageBox]::Show($_.Exception.Message,'Moonshine - operation suspendue',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning)
} finally { $script:MoonshineSetupProgress=$null;if ($lock) {$lock.Dispose()} }
exit $exitCode

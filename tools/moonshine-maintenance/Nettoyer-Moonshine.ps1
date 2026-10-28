#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$OwnerSid)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Maintenance-Core.ps1')
$locks=$null;$globalLock=$null
try {
    $context=Get-MMContext $OwnerSid
    while ($true) {
        Clear-Host
        Write-Host 'Moonshine - preparation et menage' -ForegroundColor Cyan
        Write-Host '1  Analyser seulement'
        Write-Host '2  Sauvegarder les anciennes donnees (hotes arretes)'
        Write-Host '3  Archiver les anciennes versions devenues inutilisees'
        Write-Host '0  Quitter'
        $choice=Read-Host 'Choix'
        if ($choice -eq '0') { break }
        if ($choice -notin @('1','2','3')) { continue }
        try {
            $candidates=@(Get-MMCandidates $context);$references=@(Get-MMReferences $context);$tasks=@(Get-MMTasks $context $candidates)
            $plan=@(Get-MMPlan $candidates $references $tasks)
            if (-not $plan.Count) { Write-Host 'Aucune ancienne installation reconnue.' }
            else { $plan | Select-Object @{n='Dossier';e={$_.path}},@{n='Etat';e={if ($_.removable) {'Archivable'} else {'A conserver'}}},@{n='Raison';e={$_.reason}} | Format-List | Out-Host }
            Write-Host 'VibeShine, les pilotes et les jeux installes ne sont pas desinstalles par ce script.'
            if ($choice -eq '1') { $null=Read-Host 'Entree pour revenir';continue }
            if ($choice -eq '3' -and @($plan | Where-Object { $_.removable }).Count -eq 0) { throw 'Tout est encore utilise ou non reconnu. Aucune suppression possible avec la configuration actuelle.' }
            if ($choice -eq '3') {
                Write-Host 'Les dossiers archivables et leurs taches reconnues seront retires de leur emplacement actuel.' -ForegroundColor Yellow
                Write-Host 'Une sauvegarde verifiee et une archive locale seront conservees. Les profils encore utilises restent en place.'
                if ((Read-Host 'Taper ARCHIVER pour appliquer ce plan') -cne 'ARCHIVER') { continue }
            }
            Assert-MMIdle
            Set-MMPrivateDirectory $context.BackupBase
            $globalLock=[IO.File]::Open((Join-Path $context.BackupBase 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $locks=Get-MMLocks $candidates
            $backup=New-MMBackup $context $candidates $plan $tasks
            if ($choice -eq '3') {
                # Closed cooperative locks must not prevent an atomic directory move.
                foreach ($held in $locks) { $held.Dispose() };$locks=$null
                Invoke-MMCleanup $context $candidates $plan $tasks $backup
            }
            Write-Host ('Sauvegarde verifiee : '+$backup.root) -ForegroundColor Green
            Write-Host 'Elle contient des donnees privees et reste reservee aux administrateurs Windows.'
        } catch { Write-Host ('Action suspendue : '+$_.Exception.Message) -ForegroundColor Yellow }
        finally { if ($locks) { foreach ($held in $locks) { $held.Dispose() };$locks=$null };if ($globalLock) { $globalLock.Dispose();$globalLock=$null } }
        $null=Read-Host 'Entree pour revenir'
    }
} catch { Write-Host $_.Exception.Message -ForegroundColor Red;$null=Read-Host 'Entree pour fermer';exit 1 }
finally { if ($locks) { foreach ($held in $locks) { $held.Dispose() } };if ($globalLock) { $globalLock.Dispose() } }

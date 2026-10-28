#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$OwnerSid)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Maintenance-Core.ps1')
. (Join-Path $PSScriptRoot 'Fresh-Core.ps1')
$locks=$null;$globalLock=$null
try {
    $context=Get-MMContext $OwnerSid
    $context.ExtraFolders=@()
    while ($true) {
        Clear-Host
        Write-Host 'Moonshine - menage des anciens essais 0.2.0' -ForegroundColor Cyan
        Write-Host '1  Analyser seulement'
        Write-Host '2  Sauvegarder les anciennes donnees (hotes arretes)'
        Write-Host '3  Archiver les anciennes versions devenues inutilisees'
        Write-Host '4  Repartir a neuf : retirer le service 0.9 et archiver les anciens essais'
        Write-Host '5  Ajouter un dossier de kits a examiner (facultatif)'
        Write-Host '0  Quitter'
        $choice=Read-Host 'Choix'
        if ($choice -eq '0') { break }
        if ($choice -notin @('1','2','3','4','5')) { continue }
        try {
            if ($choice -eq '5') {
                $path=(Read-Host 'Chemin du dossier contenant les anciens ZIP ou dossiers extraits').Trim().Trim('"')
                Assert-MMPlainPath $path
                if (-not [IO.Directory]::Exists($path)) { throw 'Dossier absent.' }
                $context.ExtraFolders+=@([IO.Path]::GetFullPath($path));continue
            }
            $fresh=$choice -eq '4'
            $candidates=@(Get-MMAllCandidates $context);$references=@(Get-MMEffectiveReferences $context -Fresh:$fresh);$tasks=@(Get-MMAllTasks $context $candidates)
            $plan=@(Get-MMPlan $candidates $references $tasks)
            if (-not $plan.Count) { Write-Host 'Aucune ancienne installation reconnue.' }
            else { $plan | Select-Object @{n='Dossier';e={$_.path}},@{n='Etat';e={if ($_.removable) {'Archivable'} else {'A conserver'}}},@{n='Raison';e={$_.reason}} | Format-List | Out-Host }
            Write-Host 'La nouvelle installation Moonshine, les pilotes et les jeux installes sont conserves.'
            if ($choice -eq '1') { $null=Read-Host 'Entree pour revenir';continue }
            if ($choice -in @('3','4') -and @($plan | Where-Object { $_.removable }).Count -eq 0) { throw 'Rien a archiver : les elements restants sont utilises ou non reconnus.' }
            if ($choice -in @('3','4')) {
                Write-Host 'Les dossiers archivables et leurs taches reconnues seront retires de leur emplacement actuel.' -ForegroundColor Yellow
                Write-Host 'Une sauvegarde verifiee et une archive locale seront conservees. Les profils encore utilises restent en place.'
                $confirmation=if ($fresh) {'REPARTIR'} else {'ARCHIVER'}
                if ($fresh) { Write-Host 'Le service 0.9 reconnu sera desenregistre. Son ancien appairage sera archive pour repartir a neuf.' -ForegroundColor Yellow }
                if ((Read-Host ('Taper '+$confirmation+' pour appliquer ce plan')) -cne $confirmation) { continue }
            }
            Assert-MMIdle
            Set-MMPrivateDirectory $context.BackupBase
            $globalLock=[IO.File]::Open((Join-Path $context.BackupBase 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $locks=Get-MMAllLocks $context $candidates
            $backup=New-MMBackup $context $candidates $plan $tasks
            if ($choice -in @('3','4')) {
                # Closed cooperative locks must not prevent an atomic directory move.
                foreach ($held in $locks) { $held.Dispose() };$locks=$null
                if ($fresh) { Invoke-MMRetirePreview $context $backup }
                Invoke-MMCleanup $context $candidates $plan $tasks $backup -Fresh:$fresh
            }
            Write-Host ('Sauvegarde verifiee : '+$backup.root) -ForegroundColor Green
            Write-Host 'Elle contient des donnees privees et reste reservee aux administrateurs Windows.'
        } catch { Write-Host ('Action suspendue : '+$_.Exception.Message) -ForegroundColor Yellow }
        finally { if ($locks) { foreach ($held in $locks) { $held.Dispose() };$locks=$null };if ($globalLock) { $globalLock.Dispose();$globalLock=$null } }
        $null=Read-Host 'Entree pour revenir'
    }
} catch { Write-Host $_.Exception.Message -ForegroundColor Red;$null=Read-Host 'Entree pour fermer';exit 1 }
finally { if ($locks) { foreach ($held in $locks) { $held.Dispose() } };if ($globalLock) { $globalLock.Dispose() } }

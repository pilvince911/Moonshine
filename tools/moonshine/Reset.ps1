#Requires -Version 5.1
function Get-ResetControl {
    $path=Join-Path $script:Data 'reset-control.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $control=Read-Json $path
    if ((Field $control 'schema') -ne 'opi5-xbox-reset-control/1' -or
        [string](Field $control 'backup_id') -notmatch '\Areset-\d{8}-\d{6}-[a-f0-9]{8}\z' -or
        (Field $control 'automatic_hold') -isnot [bool]) { throw 'Controle de remise a zero invalide; synchronisation bloquee, conserver ce fichier et joindre le diagnostic.' }
    return $control
}
function Reset-JournalPath($Control) {
    return Join-Path (Join-Path (Join-Path $script:Data 'Backups') $Control.backup_id) 'reset.json'
}
function Read-ResetJournal($Control) {
    $journal=Read-Json (Reset-JournalPath $Control)
    if ((Field $journal 'schema') -ne 'opi5-xbox-reset/1' -or
        (Field $journal 'backup_id') -ne $Control.backup_id -or
        (Field $journal 'status') -notin @('resetting','reset','restoring','restored') -or
        $journal.operations -isnot [array]) { throw 'Journal de remise a zero absent ou invalide; aucune ecriture.' }
    $seen=@{}
    foreach ($op in @($journal.operations)) {
        if (-not $op.key -or -not (Owned $op.before $op.key) -or $op.uuid -ne $op.before.uuid -or
            $seen.ContainsKey([string]$op.uuid) -or (Field $op 'deleted') -isnot [bool] -or
            (Field $op 'restored') -isnot [bool]) { throw 'Operation de remise a zero non verifiable; aucune ecriture.' }
        $seen[[string]$op.uuid]=$true
    }
    return $journal
}
function Get-ResetSummary {
    try {
        $control=Get-ResetControl
        if ($null -eq $control) { return $null }
        $journal=Read-ResetJournal $control
        return @{status=$journal.status;backup_id=$control.backup_id;automatic_hold=$control.automatic_hold;
            total=@($journal.operations).Count;deleted=@($journal.operations | Where-Object { $_.deleted }).Count;
            restored=@($journal.operations | Where-Object { $_.restored }).Count;version=$journal.version;created=$journal.created}
    } catch { return @{status='blocked';message=(Redact $_.Exception.Message)} }
}
function Get-ResetTargets($Apps) {
    foreach ($app in @($Apps)) {
        $key=[string](Field $app 'opi5-xbox-key')
        if (-not $key -or -not (Owned $app $key)) { continue }
        $sameId=@($Apps | Where-Object { (Field $_ 'uuid') -eq $app.uuid })
        if ($sameId.Count -ne 1) { throw 'UUID OPi5 duplique dans le catalogue; remise a zero bloquee.' }
        # Names and version paths are display information, never deletion proof.
        $version='inconnue'
        $m=[regex]::Match([string](Field $app 'working-dir'),'(?i)[\\/]versions[\\/](\d+\.\d+\.\d+)[\\/]?\z')
        if ($m.Success) { $version=$m.Groups[1].Value }
        @{uuid=[string]$app.uuid;key=$key;title=[string](Field $app 'name');version=$version;before=(Clean-App $app)}
    }
}
function Pause-ResetAutomation {
    if (Get-MoonshineTrialId) { return @{present=$false;was_enabled=$false} }
    $name=Task-Name
    $task=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq $name })
    if ($task.Count -gt 1) { throw 'Plusieurs taches OPi5 correspondantes; aucun retrait.' }
    if (-not $task) { return @{present=$false;was_enabled=$false} }
    $enabled=[bool]$task[0].Settings.Enabled
    if ($enabled) { $null=Disable-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop }
    $check=Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop
    if ([bool]$check.Settings.Enabled) { throw 'Impossible de mettre la tache OPi5 en pause; aucun retrait ne sera commence.' }
    return @{present=$true;was_enabled=$enabled}
}
function Reset-SnapshotState($Control) {
    $state=Read-Json (Join-Path (Split-Path -Parent (Reset-JournalPath $Control)) 'state-avant.json')
    if (-not (Test-StateShape $state)) { throw 'Sauvegarde de l etat du reset invalide; aucune ecriture.' }
    return State-Map $state
}
function Merge-ResetState($Current,$Snapshot,[bool]$Remove) {
    $result=State-Map $Current
    foreach ($name in @('managed','pending')) {
        foreach ($id in @(Keys $Snapshot[$name])) {
            $old=Field $Snapshot[$name] $id
            if ($result[$name].Contains($id) -and -not (Same (Field $result[$name] $id) $old)) {
                throw 'Etat modifie depuis la sauvegarde du reset; conservation des donnees, aucune fusion forcee.'
            }
            if ($Remove) { $result[$name].Remove($id) }
            else { $result[$name][$id]=$old }
        }
    }
    return ,$result
}
function Start-ManagedReset($Targets,$AppsRoot) {
    $control=Get-ResetControl
    if ($control) {
        $previous=Read-ResetJournal $control
        if ($previous.status -in @('resetting','restoring') -or $control.automatic_hold) { throw 'Une remise a zero est deja en cours ou en pause; utiliser les choix 12 ou 13.' }
    }
    $state=Load-State
    $id='reset-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $folder=Join-Path (Join-Path $script:Data 'Backups') $id
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    Write-Json (Join-Path $folder 'apps-avant.json') $AppsRoot
    Write-Json (Join-Path $folder 'state-avant.json') $state
    $operations=@()
    foreach ($target in @($Targets)) {
        if (-not (Owned $target.before $target.key) -or $target.uuid -ne $target.before.uuid) { throw 'Cible de reset non verifiable.' }
        $operations+=@{uuid=$target.uuid;key=$target.key;title=$target.title;before=$target.before;deleted=$false;restored=$false}
    }
    $journal=@{schema='opi5-xbox-reset/1';backup_id=$id;created=(Get-Date).ToString('o');version=$script:Version;
        status='resetting';operations=$operations;automation=$null}
    $control=@{schema='opi5-xbox-reset-control/1';backup_id=$id;automatic_hold=$true}
    Write-Json (Reset-JournalPath $control) $journal
    # Durable hold before pausing the task or sending any DELETE.
    Write-Json (Join-Path $script:Data 'reset-control.json') $control
    return $control
}
function Resume-ManagedReset($Control) {
    Operation-Checkpoint
    $journal=Read-ResetJournal $Control
    if ($journal.status -eq 'reset') { return }
    if ($journal.status -ne 'resetting') { throw 'Cette operation ne peut pas etre reprise comme retrait; utiliser le choix 13.' }
    Session-Idle
    $snapshot=Reset-SnapshotState $Control
    $null=Merge-ResetState (Load-State) $snapshot $true
    $automation=Pause-ResetAutomation
    if ($null -eq $journal.automation) { $journal.automation=$automation;Write-Json (Reset-JournalPath $Control) $journal }
    foreach ($op in @($journal.operations)) {
        Session-Idle
        Operation-Checkpoint
        $root=Get-Apps
        $found=@($root.apps | Where-Object { $_.uuid -eq $op.uuid })
        if ($found.Count -gt 0) {
            if ($found.Count -ne 1 -or -not (Owned $found[0] $op.key) -or -not (Same-App $found[0] $op.before)) {
                throw ('Entree modifiee depuis l apercu : '+$op.title+'. Retrait suspendu; choix 13 pour restaurer les autres entrees.')
            }
            $failure=$null
            try { $null=Api-Call 'DELETE' ('/api/apps/'+$op.uuid) } catch { $failure=$_ }
            $verified=Get-Apps
            if (@($verified.apps | Where-Object { $_.uuid -eq $op.uuid }).Count -gt 0) {
                if ($failure) { throw $failure }
                throw ('Retrait non confirme pour '+$op.title+'. Reprendre le choix 12 apres verification.')
            }
            if ($failure) { Repair-Event 'reset' 'delete_response_recovered' $op.title }
        }
        $op.deleted=$true
        Write-Json (Reset-JournalPath $Control) $journal
    }
    # Recheck all targets before clearing their old registry and cached plan.
    $final=Get-Apps
    foreach ($op in @($journal.operations)) {
        if (@($final.apps | Where-Object { $_.uuid -eq $op.uuid }).Count -gt 0) { throw 'Une entree retiree est reapparue; reset suspendu, verifier le catalogue.' }
    }
    Save-State (Merge-ResetState (Load-State) $snapshot $true)
    Write-Json (Join-Path $script:Data 'last-inventory.json') $null
    Write-Json (Join-Path $script:Data 'last-plan.json') $null
    $journal.status='reset'
    Write-Json (Reset-JournalPath $Control) $journal
    Repair-Event 'reset' 'completed' (@($journal.operations).Count.ToString()+' entrees retirees; automatisation en pause.')
}
function Reset-Identity($Operation) {
    $key=[string]$Operation.key
    if ($key -match '\Asteam:(\d+)\z') { return @{kind='steam';key=$key;steam_id=$Matches[1];title=$Operation.title} }
    if ($key.StartsWith('xbox:',[StringComparison]::OrdinalIgnoreCase)) { return @{kind='xbox';key=$key;aumid=$key.Substring(5);title=$Operation.title} }
    if ($key.StartsWith('ea:',[StringComparison]::OrdinalIgnoreCase)) { return @{kind='ea';key=$key;ea_content_id=$key.Substring(3);ea_content_ids=@($key.Substring(3));title=$Operation.title} }
    throw 'Fournisseur du journal de reset inconnu.'
}
function Restore-ManagedReset($Control) {
    Operation-Checkpoint
    $journal=Read-ResetJournal $Control
    if ($journal.status -eq 'restored') { return }
    Session-Idle
    $snapshot=Reset-SnapshotState $Control
    $null=Merge-ResetState (Load-State) $snapshot $false
    $root=Get-Apps
    # Preflight every original before restoring the first entry.
    foreach ($op in @($journal.operations)) {
        $found=@($root.apps | Where-Object { $_.uuid -eq $op.uuid })
        if ($found.Count -gt 1 -or ($found.Count -eq 1 -and -not (Same-App $found[0] $op.before))) {
            throw ('Restauration bloquee : entree modifiee ou deja reimportee pour '+$op.title+'. Aucune personnalisation ecrasee.')
        }
        $other=@($root.apps | Where-Object { $_.uuid -ne $op.uuid -and (Existing-Game $_ (Reset-Identity $op)) })
        if ($other.Count -gt 0) { throw ('Autre entree correspondante pour '+$op.title+'; restauration suspendue pour eviter un doublon.') }
    }
    $null=Pause-ResetAutomation
    $Control=To-Map $Control;$Control.automatic_hold=$true
    Write-Json (Join-Path $script:Data 'reset-control.json') $Control
    $journal.status='restoring';Write-Json (Reset-JournalPath $Control) $journal
    foreach ($op in @($journal.operations)) {
        Session-Idle
        Operation-Checkpoint
        $current=Get-Apps
        $found=@($current.apps | Where-Object { $_.uuid -eq $op.uuid })
        $other=@($current.apps | Where-Object { $_.uuid -ne $op.uuid -and (Existing-Game $_ (Reset-Identity $op)) })
        if ($found.Count -gt 1 -or ($found.Count -eq 1 -and -not (Same-App $found[0] $op.before)) -or $other.Count -gt 0) { throw 'Catalogue modifie depuis l apercu de restauration; reprise suspendue.' }
        if ($found.Count -eq 0) {
            $failure=$null
            try { $null=Api-Call 'POST' '/api/apps' (Clean-App $op.before) } catch { $failure=$_ }
            $verified=Get-Apps
            $saved=@($verified.apps | Where-Object { $_.uuid -eq $op.uuid })
            if ($saved.Count -ne 1 -or -not (Same-App $saved[0] $op.before)) {
                if ($failure) { throw $failure }
                throw 'Restauration non confirmee; reprendre le choix 13.'
            }
            if ($failure) { Repair-Event 'reset' 'restore_response_recovered' $op.title }
        }
        $op.restored=$true;Write-Json (Reset-JournalPath $Control) $journal
    }
    $final=Get-Apps
    foreach ($op in @($journal.operations)) {
        $found=@($final.apps | Where-Object { $_.uuid -eq $op.uuid })
        if ($found.Count -ne 1 -or -not (Same-App $found[0] $op.before)) { throw 'Verification finale de restauration incomplete.' }
    }
    Save-State (Merge-ResetState (Load-State) $snapshot $false)
    $journal.status='restored';Write-Json (Reset-JournalPath $Control) $journal
    $Control.automatic_hold=$false;Write-Json (Join-Path $script:Data 'reset-control.json') $Control
    Repair-Event 'reset' 'restored' (@($journal.operations).Count.ToString()+' entrees restaurees; tache laissee desactivee.')
}
function Test-ResetAllowsSync([bool]$Automatic) {
    $control=Get-ResetControl
    if ($null -eq $control) { return $true }
    $journal=Read-ResetJournal $control
    if ($journal.status -in @('resetting','restoring')) { throw 'Remise a zero interrompue : choix 12 pour terminer le retrait ou 13 pour restaurer. Synchronisation suspendue.' }
    return -not ($Automatic -and $control.automatic_hold)
}
function Complete-ResetReimport {
    $control=Get-ResetControl
    if ($control -and $control.automatic_hold) {
        $journal=Read-ResetJournal $control
        if ($journal.status -ne 'reset') { throw 'Remise a zero encore en cours.' }
        $map=To-Map $control;$map.automatic_hold=$false
        Write-Json (Join-Path $script:Data 'reset-control.json') $map
    }
}
function Reset-ManagedGames {
    $script:StreamProfiles=Load-StreamProfiles
    $null=Test-UndoAllowsSync $false
    if ($Unattended) { throw 'Remise a zero disponible uniquement dans le menu interactif.' }
    if (-not $script:Authorization) { throw 'Faire le choix 2 avant la remise a zero.' }
    Session-Idle
    $control=Get-ResetControl;$journal=$null
    if ($control) { $journal=Read-ResetJournal $control }
    if ($journal -and $journal.status -eq 'restoring') { throw 'Restauration interrompue : reprendre le choix 13.' }
    if ($journal -and $journal.status -eq 'reset' -and $control.automatic_hold) {
        Write-Host 'Remise a zero deja terminee. Choix 4 pour reimporter avec cette version, ou 13 pour restaurer.';return
    }
    $root=Get-Apps
    $targets=@(Get-ResetTargets $root.apps)
    if ($journal -and $journal.status -eq 'resetting') {
        $targets=@($journal.operations | ForEach-Object { @{uuid=$_.uuid;key=$_.key;title=$_.title;version='reprise';before=$_.before} })
    }
    if ($targets.Count -eq 0) { Write-Host 'Aucune entree identifiee comme creee par OPi5; aucune application retiree.';return }
    $ids=@($targets | ForEach-Object { $_.uuid })
    Write-Host ('Remise a zero : '+$targets.Count+' entree(s) OPi5 a retirer. Aucun jeu installe ne sera desinstalle.') -ForegroundColor Yellow
    $targets | ForEach-Object { [pscustomobject]@{Action='remove';Jeu=$_.title;Version=$_.version} } | Format-Table -AutoSize | Out-Host
    $kept=@($root.apps | Where-Object { $_.uuid -notin $ids } | ForEach-Object { $_.name })
    Write-Host ('Applications conservees : '+($kept -join ', '))
    Write-Host 'Sauvegarde privee avant retrait. Connexion, images et anciens lanceurs conserves. Automatisation mise en pause.'
    if ((Read-Host 'Taper REINITIALISER pour retirer ces entrees, ou Entree pour revenir') -cne 'REINITIALISER') { return }
    if (-not $journal -or $journal.status -ne 'resetting') { $control=Start-ManagedReset $targets $root }
    Resume-ManagedReset $control
    $script:LastInventory=$null;$script:LastPlan=@()
    $script:InventoryInfo=@{origin='cleared_by_reset';version=$script:Version;created=''}
    $script:PlanInfo=@{origin='cleared_by_reset';version=$script:Version;created=''}
    Save-Report
    Write-Host 'Remise a zero terminee. Choix 4 puis APPLIQUER pour repartir avec cette version; choix 13 pour restaurer.' -ForegroundColor Green
    Write-Host 'La tache reste desactivee. Apres validation, choix 7 pour reactiver la synchronisation automatique.'
}
function Undo-ManagedReset {
    $script:StreamProfiles=Load-StreamProfiles
    $null=Test-UndoAllowsSync $false
    if ($Unattended) { throw 'Restauration du reset disponible uniquement dans le menu interactif.' }
    if (-not $script:Authorization) { throw 'Faire le choix 2 avant la restauration.' }
    $control=Get-ResetControl
    if (-not $control) { throw 'Aucune remise a zero sauvegardee.' }
    $journal=Read-ResetJournal $control
    if ($journal.status -eq 'restored') { Write-Host 'Cette remise a zero est deja restauree.';return }
    $journal.operations | ForEach-Object { [pscustomobject]@{Action='restore';Jeu=$_.title} } | Format-Table -AutoSize | Out-Host
    Write-Host 'Restauration des entrees sauvegardees, avec leurs commandes et personnalisations d origine.'
    if ((Read-Host 'Taper RESTAURER pour continuer, ou Entree pour revenir') -cne 'RESTAURER') { return }
    Restore-ManagedReset $control
    Save-Report
    Write-Host 'Entrees restaurees. Synchronisation automatique laissee desactivee; choix 7 pour la reactiver.' -ForegroundColor Green
}

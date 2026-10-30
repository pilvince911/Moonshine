#Requires -Version 5.1
function Undo-Folder([string]$Id) {
    if ($Id -notmatch '\A\d{8}-\d{6}-[a-f0-9]{6}\z') { throw 'Identifiant de sauvegarde invalide; aucune écriture.' }
    return Join-Path (Join-Path $script:Data 'Backups') $Id
}
function Read-UndoJournal([string]$Id) {
    $journal=Read-Json (Join-Path (Undo-Folder $Id) 'transaction.json')
    if ((Field $journal 'schema') -notin @('opi5-xbox-transaction/1',$script:LegacyTransactionSchema) -or
        $journal.operations -isnot [array] -or (Field $journal 'complete') -isnot [bool]) { throw 'Journal de synchronisation invalide; conserver la sauvegarde.' }
    $seen=@{}
    foreach ($op in @($journal.operations)) {
        $key=[string](Field $op 'key');$idValue=[string](Field $op 'uuid')
        if (-not $key -or $idValue -ne (Stable-Id $key) -or -not (Owned (Field $op 'after') $key) -or
            $idValue -ne (Field $op.after 'uuid') -or $seen.ContainsKey($idValue) -or
            ($null -ne (Field $op 'before') -and -not (Owned $op.before $key))) { throw 'Opération du journal non vérifiable; aucune écriture.' }
        $seen[$idValue]=$true
        $old=Field $op 'old_state'
        if ($null -ne $old) {
            $checkState=Empty-State;$checkState.managed[$idValue]=$old
            if ($old.key -ne $key -or -not (Test-StateShape $checkState)) { throw 'Ancien registre non vérifiable dans cette sauvegarde.' }
        }
    }
    return $journal
}
function Get-UndoControl {
    $path=Join-Path $script:Data 'undo-control.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $control=Read-Json $path
    if ((Field $control 'schema') -ne 'opi5-xbox-undo-control/1' -or
        (Field $control 'status') -notin @('undoing','undone')) { throw 'Contrôle de retour arrière invalide; synchronisation bloquée. Joindre le diagnostic.' }
    $null=Undo-Folder ([string](Field $control 'backup_id'))
    if ($control.status -eq 'undoing') { $null=Read-UndoJournal $control.backup_id }
    return $control
}
function Test-UndoAllowsSync([bool]$Automatic) {
    $control=Get-UndoControl
    if ($control -and $control.status -eq 'undoing') {
        if ($Automatic) { return $false }
        throw 'Retour arrière interrompu : reprendre Annuler la dernière synchronisation dans Maintenance (choix 5). Synchronisation suspendue.'
    }
    return $true
}
function Get-UndoSummary {
    try {
        $control=Get-UndoControl
        if (-not $control) { return $null }
        try { $journal=Read-UndoJournal $control.backup_id }
        catch { if ($control.status -eq 'undone') { return @{status='undone';backup_id=$control.backup_id;total=0;restored=0;backup_available=$false} };throw }
        return @{status=$control.status;backup_id=$control.backup_id;total=@($journal.operations).Count;
            restored=@($journal.operations | Where-Object { Field $_ 'undone' $false }).Count}
    } catch { return @{status='invalid';message=(Redact $_.Exception.Message)} }
}
function Get-LatestUndoCandidate {
    $control=Get-UndoControl
    if ($control -and $control.status -eq 'undoing') { return @{id=$control.backup_id;journal=(Read-UndoJournal $control.backup_id);resume=$true} }
    $folders=@(Get-ChildItem -LiteralPath (Join-Path $script:Data 'Backups') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\A\d{8}-\d{6}-[a-f0-9]{6}\z' } | Sort-Object -Property @{Expression={$_.Name.Substring(0,15)};Descending=$true},@{Expression={$_.CreationTimeUtc};Descending=$true})
    foreach ($folder in $folders) {
        if ($folder.Name -notmatch '\A\d{8}-\d{6}-[a-f0-9]{6}\z' -or -not (Test-Path -LiteralPath (Join-Path $folder.FullName 'transaction.json'))) { continue }
        if ($control -and $control.status -eq 'undone' -and $control.backup_id -eq $folder.Name) { continue }
        try { $journal=Read-UndoJournal $folder.Name }
        catch {
            Repair-Event 'rollback' 'invalid_backup_preserved' $folder.Name
            throw 'La sauvegarde la plus récente à examiner est illisible. Annulation indisponible; aucune sauvegarde plus ancienne ne sera choisie automatiquement.'
        }
        if (@($journal.operations).Count -gt 0 -and -not (Field $journal 'undone' $false)) { return @{id=$folder.Name;journal=$journal;resume=$false} }
    }
    return $null
}
function Undo-OperationStatus($Operation,$Apps) {
    $found=@($Apps | Where-Object { (Field $_ 'uuid') -eq $Operation.uuid })
    if ($found.Count -eq 0 -and $null -eq $Operation.before) { return 'restored' }
    if ($found.Count -eq 1 -and $null -ne $Operation.before -and (Same-App $found[0] $Operation.before)) { return 'restored' }
    if ($found.Count -eq 1 -and (Owned $found[0] $Operation.key) -and (Same-App $found[0] $Operation.after)) { return 'apply' }
    # An interrupted original POST may never have reached VibeShine. Only the
    # exact old value (or absence for an add) permits continuing the rollback.
    throw ('Entrée modifiée depuis la synchronisation : '+$Operation.key+'. Retour arrière suspendu pour protéger ces réglages.')
}
function Resume-LastSyncUndo($Control) {
    Operation-Checkpoint
    $journal=Read-UndoJournal $Control.backup_id
    $folder=Undo-Folder $Control.backup_id
    $root=Get-Apps
    $ops=@($journal.operations);[array]::Reverse($ops)
    # Validate all targets and descriptor backups before changing the first one.
    $descriptors=@{}
    foreach ($op in $ops) {
        $null=Undo-OperationStatus $op $root.apps
        if ($null -ne $op.before) {
            $other=@($root.apps | Where-Object { $_.uuid -ne $op.uuid -and (Existing-Game $_ (Reset-Identity @{key=$op.key;title=$op.before.name})) })
            if ($other.Count -gt 0) { throw ('Autre entrée correspondante pour '+$op.key+'; restauration suspendue pour éviter un doublon.') }
        }
        $descriptorPath=Join-Path $folder ($op.uuid+'.game-avant.json')
        if (Test-Path -LiteralPath $descriptorPath -PathType Leaf) {
            $descriptor=Read-Json $descriptorPath
            if ((Field $descriptor 'uuid') -ne $op.uuid -or (Field $descriptor 'key') -ne $op.key) { throw 'Sauvegarde de lanceur invalide; retour arrière suspendu.' }
            $descriptors[$op.uuid]=$descriptor
        }
    }
    Session-Idle
    $state=Load-State
    foreach ($op in $ops) {
        Operation-Checkpoint
        Session-Idle
        $current=Get-Apps
        $status=Undo-OperationStatus $op $current.apps
        if ($status -eq 'apply') {
            if ($null -ne $op.before) {
                $other=@($current.apps | Where-Object { $_.uuid -ne $op.uuid -and (Existing-Game $_ (Reset-Identity @{key=$op.key;title=$op.before.name})) })
                if ($other.Count -gt 0) { throw 'Une entrée correspondante est apparue; reprise du retour arrière suspendue.' }
            }
            $failure=$null
            try {
                if ($null -eq $op.before) { $null=Api-Call 'DELETE' ('/api/apps/'+$op.uuid) }
                else { $null=Api-Call 'POST' '/api/apps' (Clean-App $op.before) }
            } catch { $failure=$_ }
            # Finish verification even when Cancel arrives during POST/DELETE.
            # A lost response never triggers a second mutation in this pass.
            $verify=Get-Apps
            try { $verified=Undo-OperationStatus $op $verify.apps }
            catch { if ($failure) { throw $failure };throw }
            if ($verified -ne 'restored') {
                if ($failure) { throw $failure }
                throw 'Retour arrière non confirmé. Reprendre Annuler la dernière synchronisation.'
            }
            if ($failure) { Repair-Event 'rollback' 'response_recovered' $op.key }
        }
        if ($null -eq $op.old_state) { $state.managed.Remove($op.uuid) }
        else { $state.managed[$op.uuid]=$op.old_state }
        $state.pending.Remove($op.uuid)
        Save-State $state
        if ($descriptors.ContainsKey([string]$op.uuid)) {
            Write-Json (Join-Path (Join-Path $script:Data 'Games') ($op.uuid+'.json')) $descriptors[[string]$op.uuid]
        }
        $savedOp=To-Map $op;$savedOp['undone']=$true
        for ($i=0;$i -lt $journal.operations.Count;$i++) { if ($journal.operations[$i].uuid -eq $op.uuid) { $journal.operations[$i]=$savedOp;break } }
        Write-Json (Join-Path $folder 'transaction.json') $journal
        Write-Host ('  Rétabli : '+$op.key)
    }
    $final=Get-Apps
    foreach ($op in $ops) { if ((Undo-OperationStatus $op $final.apps) -ne 'restored') { throw 'Catalogue modifié pendant la vérification finale du retour arrière.' } }
    $map=To-Map $journal;$map['undone']=$true
    Write-Json (Join-Path $folder 'transaction.json') $map
    $completed=To-Map $Control;$completed.status='undone'
    Write-Json (Join-Path $script:Data 'undo-control.json') $completed
    Repair-Event 'rollback' 'completed' $Control.backup_id
}
function Undo-LastSync {
    $script:StreamProfiles=Load-StreamProfiles
    if ($Unattended) { throw 'Retour arrière réservé à une demande interactive.' }
    $null=Test-ResetAllowsSync $false
    $reset=Get-ResetControl
    if ($reset -and $reset.automatic_hold) { throw 'Utiliser Restaurer le dernier reset (choix 13) pour annuler la remise à zéro.' }
    Session-Idle
    $candidate=Get-LatestUndoCandidate
    if (-not $candidate) { throw 'Aucune synchronisation à annuler.' }
    $journal=$candidate.journal
    $root=Get-Apps
    $null=Load-State
    foreach ($op in @($journal.operations)) {
        $null=Undo-OperationStatus $op $root.apps
        if ($null -ne $op.before) {
            $other=@($root.apps | Where-Object { $_.uuid -ne $op.uuid -and (Existing-Game $_ (Reset-Identity @{key=$op.key;title=$op.before.name})) })
            if ($other.Count -gt 0) { throw ('Autre entrée correspondante pour '+$op.key+'; aucune restauration commencée.') }
        }
        $descriptorPath=Join-Path (Undo-Folder $candidate.id) ($op.uuid+'.game-avant.json')
        if (Test-Path -LiteralPath $descriptorPath -PathType Leaf) {
            $descriptor=Read-Json $descriptorPath
            if ((Field $descriptor 'uuid') -ne $op.uuid -or (Field $descriptor 'key') -ne $op.key) { throw 'Sauvegarde de lanceur invalide; aucune annulation commencée.' }
        }
    }
    Write-Host ('Annulation proposée : '+$candidate.id+' ('+@($journal.operations).Count+' opérations).')
    foreach ($op in @($journal.operations)) { Write-Host ('  '+$op.key) }
    if ((Read-Host 'Taper ANNULER pour continuer') -cne 'ANNULER') { return }
    Operation-Checkpoint
    $control=@{schema='opi5-xbox-undo-control/1';backup_id=$candidate.id;status='undoing';created=(Get-Date).ToString('o')}
    # A durable guard precedes every rollback mutation. Scheduled/manual sync
    # waits until this exact journal has been completely verified and resumed.
    Write-Json (Join-Path $script:Data 'undo-control.json') $control
    Resume-LastSyncUndo $control
    Write-Host 'Dernière synchronisation annulée et catalogue vérifié.' -ForegroundColor Green
}
function Read-InventoryCache {
    $path=Join-Path $script:Data 'last-inventory.json'
    try {
        $cache=Read-Json $path
        if ($null -eq $cache) { return $null }
        if ($cache.ready -isnot [array] -or $cache.pending -isnot [array] -or
            (Field $cache 'version') -isnot [string] -or (Field $cache 'created') -isnot [string]) { throw 'Structure de cache invalide.' }
        foreach ($game in @($cache.ready)) {
            if (-not (Field $game 'key') -or (Field $game 'uuid') -ne (Stable-Id $game.key) -or
                (Field $game 'kind') -notin @('steam','xbox','ea') -or (Field $game 'title') -isnot [string]) { throw 'Jeu en cache invalide.' }
            if (($game.kind -eq 'steam' -and $game.key -ine ('steam:'+[string](Field $game 'steam_id'))) -or
                ($game.kind -eq 'ea' -and $game.key -ine ('ea:'+[string](Field $game 'ea_content_id'))) -or
                ($game.kind -eq 'xbox' -and $game.key -ine ('xbox:'+[string](Field $game 'aumid')))) { throw 'Identité du cache incohérente.' }
        }
        foreach ($pending in @($cache.pending)) { if ((Field $pending 'key') -isnot [string]) { throw 'Attente en cache invalide.' } }
        return $cache
    } catch {
        Preserve-RecoveryFile $path 'inventory-cache'
        Write-Json $path $null
        Repair-Event 'inventory-cache' 'reset' 'Analyse locale à refaire; cache endommagé conservé.'
        return $null
    }
}

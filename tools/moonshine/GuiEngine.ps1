#Requires -Version 5.1
# Dot-sourced only in the dedicated desktop engine, never in console/automatic mode.
$script:GuiApps=@();$script:GuiOnline=$false;$script:GuiDiagnosticRows=@();$script:GuiSelectedId=''
$script:GuiConnectInput=$null;$script:GuiPromptDeclined=$false
$script:GuiPlanScope='Tous les jeux'
$script:GuiLocalError='';$script:GuiPlanVerified=$false;$script:GuiSessionIdle=$false;$script:GuiSession='Session à vérifier'
function Gui-Text([string]$Text) {
    $Text=$Text.Replace('Faire le choix 2 pour connecter VibeShine avant de synchroniser.','Connectez VibeShine avant de synchroniser.')
    $Text=$Text.Replace('Refaire le choix 2 du menu','Utiliser Reconnecter')
    foreach ($pair in @(@('choix 12','Remettre les entrées à zéro'),@('choix 13','Restaurer le reset'),@('choix 2','Connecter VibeShine'),
        @('choix 4','Synchroniser'),@('choix 6','Créer le diagnostic'),@('choix 7','Activer la synchronisation automatique'),@('choix 9','Maintenance'))) {
        $Text=$Text.Replace($pair[0],$pair[1])
    }
    return $Text
}
function Write-Host {
    param([Parameter(ValueFromRemainingArguments=$true)]$Object,[ConsoleColor]$ForegroundColor,[ConsoleColor]$BackgroundColor,[switch]$NoNewline,[object]$Separator=' ')
    if ($script:SelfTestStatus -eq 'running') { return }
    $text=(@($Object | ForEach-Object { [string]$_ }) -join [string]$Separator).Trim()
    if ($text) { $script:GuiBridge.Publish('log',(Gui-Text $text),-1,$null) }
}
function Write-Progress {
    param([string]$Activity,[string]$Status,[int]$PercentComplete=-1,[switch]$Completed,[int]$Id=0,[int]$ParentId=-1,[string]$CurrentOperation)
    if (-not $Completed -and $script:SelfTestStatus -ne 'running') { $script:GuiBridge.Publish('progress',($Activity+' · '+$Status),$PercentComplete,$null) }
}
function Out-Host {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
    process { } # Structured plan is published separately; console formatting is intentionally discarded.
}
function Read-Host([string]$Prompt,[switch]$AsSecureString) {
    Operation-Checkpoint
    if ($null -ne $script:GuiConnectInput) {
        if ($script:GuiConnectInput.Count -eq 0) { throw 'Réponse de connexion inattendue.' }
        return $script:GuiConnectInput.Dequeue()
    }
    if ($AsSecureString) { throw 'Utiliser la fenêtre de connexion sécurisée.' }
    $expected='';$title='Confirmer';$typed=$false;$details=''
    if ($Prompt -like 'Taper APPLIQUER*') {
        $expected='APPLIQUER';$title='Appliquer les changements';$script:GuiPlanVerified=$true
        foreach ($row in @($script:LastPlan | Where-Object { $_.action -in @('add','update') })) { $details+=($row.title+' — '+$row.action+' '+$row.reason+"`n") }
        $details+="`nUne sauvegarde du catalogue et de l'état précède les changements."
    } elseif ($Prompt -like 'Taper REINITIALISER*') {
        $expected='REINITIALISER';$title='Retirer les entrées OPi5';$typed=$true
        $targets=Get-Variable -Name targets -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
        foreach ($row in @($targets)) { $details+=([string]$row.title+"`n") }
        $details+="`nSeules ces entrées seront retirées de VibeShine. Les jeux installés et les applications personnelles restent en place. Une sauvegarde est créée et la synchronisation automatique est mise en pause."
    } elseif ($Prompt -like 'Taper RESTAURER*') {
        $expected='RESTAURER';$title='Restaurer le dernier reset'
        $journal=Get-Variable -Name journal -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
        foreach ($op in @($journal.operations)) { $details+=([string]$op.title+"`n") }
        $details+="`nLes entrées et leurs anciens réglages seront restaurés si aucune modification conflictuelle n'est détectée."
    } elseif ($Prompt -like 'Taper ANNULER*') {
        $expected='ANNULER';$title='Annuler la dernière synchronisation'
        $journal=Get-Variable -Name journal -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
        foreach ($op in @($journal.operations)) { $details+=([string](Field $op.after 'name' $op.key)+"`n") }
        $details+="`nRétablir ces entrées depuis leur sauvegarde. Toute personnalisation ultérieure bloque son écrasement. Une interruption pourra être reprise depuis le même bouton."
    }
    elseif ($Prompt -like '*taper ACTIVER*') { $expected='ACTIVER';$title='Activer la synchronisation automatique';$details='Après validation des lancements Moonlight, activer la vérification à l''ouverture de session, puis toutes les dix minutes. Les jeux absents ne seront pas supprimés.' }
    else { throw ('Confirmation graphique non reconnue : '+$Prompt) }
    Gui-PublishSnapshot
    $reply=$script:GuiBridge.Ask($title,$details,$expected,$typed)
    if ($reply -cne $expected) { $script:GuiPromptDeclined=$true }
    return $reply
}
function Gui-Date([string]$Text) {
    $value=[datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($Text,[ref]$value)) { return $value.ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    return ''
}
function Gui-RefreshData([switch]$Online) {
    $script:GuiLocalError=''
    try { $script:StreamProfiles=Load-StreamProfiles }
    catch { $script:GuiLocalError=Redact $_.Exception.Message;$script:StreamProfiles=@{schema='opi5-stream-profiles/1';games=@{}} }
    if (-not $script:LastInventory) {
        $cached=Read-InventoryCache
        if ($cached) { $script:LastInventory=$cached;$script:InventoryInfo=@{origin='cached_previous_run';version=(Field $cached 'version' 'unknown');created=(Field $cached 'created' '')} }
    }
    if ($Online) {
        $script:GuiBridge.Publish('progress','Vérification de la connexion et des préférences locales…',-1,$null)
        $script:GuiOnline=$false;$script:GuiPlanVerified=$false;$script:GuiSessionIdle=$false;$script:GuiSession='État de session non vérifié'
        $script:GuiApps=@()
        try {
            Load-Connection
            if ($script:Authorization) { $script:GuiApps=@((Get-Apps).apps);$script:GuiOnline=$true }
        } catch { $script:GuiApps=@();$script:GuiBridge.Publish('log',(Gui-Text $_.Exception.Message),-1,$null) }
        if ($script:GuiOnline) {
            try { $script:GuiSessionIdle=Session-IsIdle;$script:GuiSession=$(if ($script:GuiSessionIdle) {'Aucune session Moonlight active'} else {'Session Moonlight active · écritures en pause'}) }
            catch { $script:GuiSession='État de session non vérifiable · reconnecter ou actualiser';$script:GuiBridge.Publish('log',(Gui-Text $_.Exception.Message),-1,$null) }
        }
        if ($script:GuiOnline -and $script:LastInventory) {
            try {
            $state=Load-State
            $games=@($script:LastInventory.ready)
            if ($script:GuiPlanScope -eq 'Pilote Steam + Xbox') { $games=@(Pilot-Games $games) }
            elseif ($script:GuiPlanScope -eq 'Jeux EA seulement') { $games=@(EA-SelectGames $games $false) }
            elseif ($script:GuiPlanScope -eq 'Pilote EA') { $games=@(EA-SelectGames $games $true) }
            $script:LastPlan=@(Build-Plan $games $script:GuiApps $state $script:Runtime $script:Data)
            $script:GuiPlanVerified=$true
            } catch { $script:GuiLocalError=Redact $_.Exception.Message;$script:GuiPlanVerified=$false }
        }
        $script:GuiDiagnosticRows=@(Get-GuiDiagnostics $script:GuiApps $script:GuiSelectedId)
    }
}
function Gui-FieldValue($Value) {
    if ($null -eq $Value) { return 'Non défini' }
    if ($Value -is [bool]) { return $(if ($Value) {'Oui'} else {'Non'}) }
    if ($Value -is [string]) { return $(if ($Value.Length) {$Value} else {'Vide'}) }
    return (Json $Value).Trim()
}
function Gui-GameFields($App,$Plan) {
    $labels=@{'name'='Titre';'cmd'='Commande de lancement';'working-dir'='Dossier de travail';'image-path'='Pochette';
        'auto-detach'='Détachement automatique';'wait-all'='Attendre les processus enfants';'exit-timeout'='Délai de fermeture (s)';
        'elevated'='Lancement administrateur';'exclude-global-prep-cmd'='Ignorer les commandes globales';
        'detached'='Commandes détachées';'prep-cmd'='Commandes avant / après';'steam-id'='Identifiant Steam';
        'steam-install-dir'='Installation Steam';'ea-id'='Identifiant EA';'frame-generation-mode'='Mode Frame Generation';
        'frame-generation-provider'='Source Frame Generation';'lossless-scaling-enabled'='Lossless Scaling';
        'lossless-scaling-framegen'='Frame Generation Lossless Scaling';'config-overrides'='Exceptions de configuration'}
    if ($Plan -and $null -ne $Plan.before) { $App=$Plan.before }
    $current=$(if ($App) {Clean-App $App} else {[ordered]@{}})
    $proposed=$(if ($Plan -and $Plan.action -in @('add','update','unchanged') -and $Plan.payload) {$Plan.payload} else {$current})
    foreach ($key in @(@(Keys $current)+@(Keys $proposed) | Sort-Object -Unique)) {
        if ($key -in @('uuid','opi5-xbox-owner','opi5-xbox-key')) { continue }
        $row=New-Object OPi5GuiField
        $row.Name=$(if ($labels.ContainsKey($key)) {$labels[$key]} else {$key})
        $row.Current=Gui-FieldValue (Field $current $key);$row.Proposed=Gui-FieldValue (Field $proposed $key)
        $row.Decision=$(if ($Plan -and $Plan.action -eq 'add') {'À créer'} elseif ($Plan -and $key -in @($Plan.changed_fields)) {'À modifier'}
            elseif ($Plan -and $Plan.fields -and $key -in @(Keys $Plan.fields) -and -not (App-FieldSame $key (Field $current $key) (Field $Plan.fields $key))) {'Personnalisation conservée'} else {'Conservé'})
        $row
    }
}
function Gui-PublishSnapshot {
    $snapshot=New-Object OPi5GuiSnapshot
    $snapshot.Connected=$script:GuiOnline
    $snapshot.PlanVerified=$script:GuiPlanVerified
    $snapshot.Session=$script:GuiSession
    $snapshot.Connection=$(if ($script:GuiOnline) {'Interface locale · connexion enregistrée'} else {'Connectez l''interface locale pour synchroniser.'})
    $snapshot.Endpoint=[string](Field $script:Connection 'url' 'https://127.0.0.1:47990')
    $snapshot.Tests=$script:SelfTestCount
    $snapshot.PlanScope=$script:GuiPlanScope
    $ownedCount=@($script:GuiApps | Where-Object { $key=[string](Field $_ 'opi5-xbox-key');$key -and (Owned $_ $key) }).Count
    $snapshot.CatalogOnly=$null -eq $script:LastInventory -and $ownedCount -gt 0
    $snapshot.Cached=$script:InventoryInfo.origin -eq 'cached_previous_run' -or $script:PlanInfo.origin -eq 'cached_previous_run'
    $snapshot.LastScan=$(if ($script:LastInventory) {'Dernière analyse : '+(Gui-Date ([string]$script:LastInventory.created))} else {'Aucune analyse disponible.'})
    $last=Read-OptionalJson (Join-Path $script:Data 'last-run.json')
    $lastStatus=switch ([string](Field $last 'status')) {
        'completed' { 'Terminée' }
        'completed_with_conflicts' { 'Éléments à vérifier' }
        'paused_rollback' { 'Retour arrière à reprendre' }
        'paused_after_reset' { 'En pause après remise à zéro' }
        'skipped_busy' { 'Reportée pendant une session active' }
        'no_supported_games' { 'Aucun jeu pris en charge détecté' }
        default { 'Consulter le diagnostic' }
    }
    $snapshot.LastSync=$(if ($last) {'Dernier passage : '+(Gui-Date ([string]$last.time))+' · '+$lastStatus} else {'Aucune synchronisation enregistrée.'})
    $snapshot.Automation='Désactivée'
    try {
        $task=Get-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -ErrorAction SilentlyContinue
        if ($task) { $snapshot.Automation=$(if ($task.Settings.Enabled) {'Activée · '+[string]$task.State} else {'En pause'}) }
    } catch { $snapshot.Automation='État de la tâche indisponible' }
    $reset=Get-ResetSummary
    $snapshot.Reset=$(if ($reset) {'Remise à zéro : '+$reset.status+' · pause automatique : '+$reset.automatic_hold} else {'Aucune remise à zéro enregistrée.'})
    $undo=Get-UndoSummary
    $snapshot.UndoPending=$undo -and $undo.status -eq 'undoing'
    $invalid=[bool]$script:GuiLocalError -or ($undo -and $undo.status -eq 'invalid') -or ($reset -and $reset.status -eq 'invalid')
    $resetPending=$reset -and $reset.status -in @('resetting','restoring')
    $safe=$script:GuiOnline -and $script:GuiSessionIdle -and -not $invalid
    $snapshot.CanSync=$safe -and -not $snapshot.UndoPending -and -not $resetPending
    $snapshot.CanReset=$safe -and -not $snapshot.UndoPending -and (-not $reset -or $reset.status -ne 'restoring')
    $snapshot.CanRestoreReset=$safe -and -not $snapshot.UndoPending -and $reset -and $reset.status -ne 'restored'
    $snapshot.CanUndoSync=$false;$undoWarning=''
    if ($safe -and -not $resetPending -and (-not $reset -or -not $reset.automatic_hold)) {
        try { $snapshot.CanUndoSync=$null -ne (Get-LatestUndoCandidate) }
        catch { $undoWarning=Redact $_.Exception.Message }
    }
    $snapshot.Recovery=$(if ($script:GuiLocalError) {$script:GuiLocalError+' Créez le diagnostic depuis Maintenance.'}
        elseif ($invalid) {'Un journal de récupération doit être vérifié. Créez le diagnostic depuis Maintenance.'}
        elseif ($snapshot.UndoPending) {'Retour arrière interrompu. Maintenance → Reprendre l''annulation; synchronisation en pause.'}
        elseif ($resetPending) {'Remise à zéro interrompue. Maintenance → terminer le retrait ou reprendre la restauration.'}
        elseif ($reset -and $reset.automatic_hold) {'Remise à zéro terminée. Réimportez manuellement ou restaurez le reset; automatisation en pause.'}
        elseif ($undoWarning) {$undoWarning}
        else {''})
    $rows=New-Object 'Collections.Generic.List[OPi5GuiGame]'
    foreach ($game in @(Field $script:LastInventory 'ready' @() | Where-Object { $null -ne $_ })) {
        $row=New-Object OPi5GuiGame;$row.Uuid=[string]$game.uuid;$row.Key=[string]$game.key;$row.Title=[string]$game.title
        $row.Platform=switch ($game.kind) {
            'steam' { 'Steam' }
            'xbox' { 'Xbox' }
            'ea' { 'EA' }
            default { [string]$game.kind }
        }
        $row.Cover=[string]$game.cover
        $plan=@($script:LastPlan | Where-Object { $_.key -eq $game.key } | Select-Object -First 1)
        $row.Action=$(if ($plan.Count -and $script:GuiPlanVerified) {[string]$plan[0].action} else {'unknown'})
        $row.State=switch ($row.Action) {
            'add' { 'À ajouter' }
            'update' { 'À mettre à jour' }
            'unchanged' { 'À jour' }
            'existing' { 'Déjà présent' }
            'conflict' { 'À vérifier' }
            default { 'À analyser' }
        }
        $row.Detail=$(if ($plan.Count -and $plan[0].reason) {[string]$plan[0].reason} else {'Image : '+[string]$game.artwork_origin})
        $owned=@($script:GuiApps | Where-Object { (Field $_ 'uuid') -eq $game.uuid -and (Owned $_ $game.key) })
        $row.Managed=$owned.Count -eq 1
        $profile=Field $script:StreamProfiles.games ([string]$game.uuid)
        $row.Profile=$(if ($profile) {[string]$profile.mode} else {'Réglages conservés'})
        $currentId=$(if ($plan.Count -and (Field $plan[0] 'matched_uuid')) {[string]$plan[0].matched_uuid} else {[string]$game.uuid})
        $current=@($script:GuiApps | Where-Object { (Field $_ 'uuid') -eq $currentId } | Select-Object -First 1)
        $row.Fields=[OPi5GuiField[]]@(Gui-GameFields $(if ($current.Count) {$current[0]} else {$null}) $(if ($script:GuiPlanVerified -and $plan.Count) {$plan[0]} else {$null}))
        [void]$rows.Add($row)
    }
    foreach ($app in @($script:GuiApps)) {
        $key=[string](Field $app 'opi5-xbox-key')
        if (-not $key -or -not (Owned $app $key) -or @($rows | Where-Object { $_.Uuid -eq $app.uuid }).Count -gt 0) { continue }
        $row=New-Object OPi5GuiGame;$row.Uuid=[string]$app.uuid;$row.Key=$key;$row.Title=[string](Field $app 'name')
        $row.Platform=$key.Split(':')[0].ToUpperInvariant();if ($row.Platform -eq 'STEAM') { $row.Platform='Steam' };if ($row.Platform -eq 'XBOX') { $row.Platform='Xbox' }
        $row.Cover=[string](Field $app 'image-path');$row.Managed=$true;$row.Action='unknown';$row.State='À analyser';$row.Detail='Entrée présente dans VibeShine; installation à vérifier.'
        $profile=Field $script:StreamProfiles.games ([string]$app.uuid);$row.Profile=$(if ($profile) {[string]$profile.mode} else {'Réglages conservés'})
        $row.Fields=[OPi5GuiField[]]@(Gui-GameFields $app $null)
        [void]$rows.Add($row)
    }
    foreach ($pending in @(Field $script:LastInventory 'pending' @() | Where-Object { $null -ne $_ })) {
        $row=New-Object OPi5GuiGame;$row.Title=$(if ($pending.title) {[string]$pending.title} else {[string]$pending.key});$row.Key=[string]$pending.key
        $row.Platform=([string]$pending.key).Split(':')[0].ToUpperInvariant();$row.Action='pending';$row.State='En attente';$row.Detail=[string]$pending.reason;[void]$rows.Add($row)
    }
    $snapshot.Games=$rows.ToArray();$snapshot.Diagnostics=[OPi5GuiDiagnostic[]]$script:GuiDiagnosticRows
    $selected=@($script:GuiApps | Where-Object { (Field $_ 'uuid') -eq $script:GuiSelectedId } | Select-Object -First 1)
    $snapshot.Selection=$(if ($selected.Count) {[string](Field $selected[0] 'name')} else {'Préférences hôte'})
    $backups=New-Object 'Collections.Generic.List[OPi5GuiBackup]'
    $folder=Join-Path $script:Data 'Backups'
    foreach ($item in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 30)) {
        $r=New-Object OPi5GuiBackup;$r.Name=$item.Name;$r.Date=$item.CreationTime.ToString('yyyy-MM-dd HH:mm')
        $r.Kind=$(if (Test-Path -LiteralPath (Join-Path $item.FullName 'reset.json')) {'Remise à zéro'} else {'Synchronisation'})
        $r.State='Conservée en privé'
        if ($r.Kind -eq 'Synchronisation') {
            try {
                $journal=Read-UndoJournal $item.Name
                $r.State=$(if (Field $journal 'undone' $false) {'Retour arrière terminé'} elseif ($undo -and $undo.backup_id -eq $item.Name -and $undo.status -eq 'undoing') {'Retour arrière à reprendre'} elseif ($journal.complete) {'Synchronisation vérifiée'} else {'Synchronisation interrompue'})
            } catch { $r.State='Sauvegarde à vérifier' }
        }
        [void]$backups.Add($r)
    }
    $snapshot.Backups=$backups.ToArray()
    $script:GuiBridge.Publish('snapshot','',-1,$snapshot)
}
function Start-GuiEngine {
    $script:GuiBridge.MarkReady()
    while (-not $script:GuiBridge.Closing) {
        $request=$script:GuiBridge.NextCommand()
        if ($null -eq $request) { break }
        $operationLock=$null;$oldLock=$null;$script:GuiPromptDeclined=$false
        $operationStarted=$false
        $outcome='Opération terminée.'
        try {
            if (-not [OPi5GuiBridge]::ValidCommand($request.Name)) { throw 'Action graphique inconnue.' }
            $script:Stage='interface '+$request.Name
            $operationLock=[IO.File]::Open((Join-Path $script:Data 'sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            if (Test-Path -LiteralPath (Legacy-DataRoot) -PathType Container) { $oldLock=[IO.File]::Open((Join-Path (Legacy-DataRoot) 'sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
            Operation-Checkpoint
            $operationStarted=$true
            $script:GuiSelectedId=[string]$request.GameId
            if ($request.Name -in @('Preview','SyncAll','SyncPilot','SyncEA','SyncEAPilot','Profile')) { $script:StreamProfiles=Load-StreamProfiles }
            if ($request.Name -in @('Preview','SyncAll')) { $script:GuiPlanScope='Tous les jeux' }
            elseif ($request.Name -eq 'SyncPilot') { $script:GuiPlanScope='Pilote Steam + Xbox' }
            elseif ($request.Name -eq 'SyncEA') { $script:GuiPlanScope='Jeux EA seulement' }
            elseif ($request.Name -eq 'SyncEAPilot') { $script:GuiPlanScope='Pilote EA' }
            switch ($request.Name) {
                'Connect' {
                    $script:GuiConnectInput=New-Object 'Collections.Generic.Queue[object]'
                    $script:GuiConnectInput.Enqueue([string]$request.Port);$script:GuiConnectInput.Enqueue([string]$request.User);$script:GuiConnectInput.Enqueue($request.Password)
                    Connect-Vibe
                }
                'Preview' { Show-Preview;$outcome='Analyse terminée. Examinez les changements proposés.' }
                'SyncAll' { Sync-Games $false;$outcome=$script:SyncOutcome }
                'SyncPilot' { Sync-Games $true;$outcome=$script:SyncOutcome }
                'SyncEA' { Sync-Games $false $false $true;$outcome=$script:SyncOutcome }
                'SyncEAPilot' { Sync-Games $false $true;$outcome=$script:SyncOutcome }
                'Reset' { Reset-ManagedGames }
                'RestoreReset' { Undo-ManagedReset }
                'UndoSync' { Undo-LastSync }
                'EnableAuto' { Enable-Automation }
                'DisableAuto' { Disable-Automation }
                'Export' { $zip=Export-Return;$script:GuiBridge.Publish('export',$zip,-1,$null) }
                'Status' { $outcome='Diagnostic local actualisé.' }
                'Profile' {
                    $script:GuiPlanScope='Tous les jeux'
                    if ($request.Mode -notin @('game-provided','off','unmanaged') -or $request.GameId -notmatch '^706c6f73-7862-[a-f0-9-]{22}$') { throw 'Profil ou jeu invalide.' }
                    $apps=@((Get-Apps).apps | Where-Object { (Field $_ 'uuid') -eq $request.GameId })
                    if ($apps.Count -ne 1) { throw 'Entrée à actualiser avant de configurer son profil.' }
                    Save-GameStreamProfile $apps[0] $request.Mode
                    $outcome='Profil enregistré. Synchroniser pour appliquer les changements proposés.'
                    Write-Host 'Profil enregistré. Analyser puis Synchroniser pour appliquer les changements proposés.'
                }
            }
            if ($script:GuiPromptDeclined) { $outcome='Aucune modification appliquée.';Write-Host 'Aucune confirmation donnée. Les changements proposés n''ont pas été appliqués.' }
        } catch {
            $failure=$_;$exception=$failure.Exception
            while ($exception.InnerException) { $exception=$exception.InnerException }
            if ($exception -is [OperationCanceledException]) { $outcome='Opération annulée à un point de reprise sûr.';$script:GuiBridge.Publish('log',$outcome,-1,$null) }
            else {
                $outcome='Opération suspendue. Le diagnostic peut être créé depuis Maintenance.'
                try { Record-Error $failure } catch { }
                $message=Gui-Text (Redact $failure.Exception.Message)
                if (-not $operationStarted -and ($exception.HResult -band 65535) -in @(32,33)) { $message='Une autre synchronisation est en cours. Réessayez dans quelques instants.' }
                $script:GuiBridge.Publish('error',$message,-1,$null)
            }
        } finally {
            $script:GuiConnectInput=$null;$request.Dispose()
            if ($operationStarted -and -not $script:GuiBridge.Closing) {
                try {
                    if (-not $script:GuiBridge.IsCancellationRequested) { Gui-RefreshData -Online }
                    else { $script:GuiPlanVerified=$false;$script:GuiSessionIdle=$false;$script:GuiSession='Après annulation : actualiser le diagnostic avant de reprendre' }
                    Gui-PublishSnapshot;Save-Report
                }
                catch { $outcome='Actualisation incomplète. Consulter le diagnostic.';$script:GuiBridge.Publish('error',(Gui-Text $_.Exception.Message),-1,$null) }
            }
            if ($oldLock) { $oldLock.Dispose() };if ($operationLock) { $operationLock.Dispose() }
            $script:GuiBridge.Publish('result',$outcome,-1,$null)
            $script:GuiBridge.FinishCommand()
        }
    }
}

#Requires -Version 5.1
function Empty-State { return [ordered]@{schema='opi5-xbox-state/1';managed=@{};pending=@{}} }
function Load-State {
    $path=Join-Path $script:Data 'state.json'
    $script:StateNeedsRepair=$false
    $bad=$false
    try {
        $s=Read-Json $path
        $schema=Field $s 'schema'
        if ($schema -and $schema -notin @('opi5-xbox-state/1',$script:LegacyStateSchema)) { throw [NotSupportedException]::new('Version du registre local non reconnue; fichier conserve.') }
        if (Test-StateShape $s) { return State-Map $s }
        $bad=Test-Path -LiteralPath $path -PathType Leaf
    } catch [NotSupportedException] { throw }
    catch { $bad=$true }
    if ($bad) { Preserve-RecoveryFile $path 'state' }
    $mirror=Join-Path $script:Data 'state.last-good.json'
    try {
        $s=Read-Json $mirror
        if (Test-StateShape $s) {
            Write-Json $path $s
            Repair-Event 'state' 'restored' 'Etat local restaure depuis sa derniere copie valide.'
            return State-Map $s
        }
    } catch { }
    $script:StateNeedsRepair=$true
    if ($bad) { Note 'reparation' 'Etat local endommage conserve; reconstruction limitee aux entrees OPi5 verifiees dans l API.' }
    return Empty-State
}
function Save-State($State) {
    if (-not (Test-StateShape $State)) { throw 'Etat local incoherent : sauvegarde refusee.' }
    foreach ($name in @('state.json','state.last-good.json')) {
        $path=Join-Path $script:Data $name
        $old=$null
        try { $old=Read-Json $path } catch { Preserve-RecoveryFile $path 'state' }
        if (-not (Same $old $State)) { Write-Json $path $State }
    }
}
function Desired-Fields($Game,[string]$Runtime,[string]$Data) {
    $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcher=Join-Path $Runtime 'Launch-Game.ps1'
    foreach ($path in @($ps,$launcher,$Data)) {
        if ($path -match '["\r\n]') { throw 'Chemin incompatible avec une commande Windows.' }
    }
    $command='"'+$ps+'" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "'+$launcher+'" -GameId "'+$Game.uuid+'" -DataRoot "'+$Data+'"'
    $fields=[ordered]@{
        uuid=$Game.uuid;name=$Game.title;cmd=$command;'working-dir'=$Runtime
        'auto-detach'=($Game.kind -eq 'steam');'wait-all'=$false;'exit-timeout'=5
        elevated=$false;'opi5-xbox-owner'=$script:Owner;'opi5-xbox-key'=$Game.key
        'image-path'=''
    }
    if ($Game.kind -eq 'steam') {
        $fields['steam-id']=[string]$Game.steam_id
        $fields['steam-install-dir']=$Game.install
    }
    if ($Game.kind -eq 'ea') { $fields['ea-id']=[string]$Game.ea_content_id }
    if ($Game.cover -and [IO.Path]::GetExtension($Game.cover) -ieq '.png') {
        $fields['image-path']=$Game.cover
    }
    $profile=Get-GameStreamFields $Game
    foreach ($name in @(Keys $profile)) { $fields[$name]=$profile[$name] }
    return ,$fields
}
function Existing-Game($App,$Game) {
    if ((Field $App 'opi5-xbox-key') -ieq $Game.key) { return $true }
    if ($Game.kind -eq 'steam') {
        if ([string](Field $App 'steam-id') -eq [string]$Game.steam_id) { return $true }
        $command=([string](Field $App 'cmd'))+' '+((@(Field $App 'detached' @())) -join ' ')
        foreach ($match in [regex]::Matches($command,'(?i)steam://(?:run|rungameid)/(\d+)(?:[/\s?"]|$)|-applaunch\s+(\d+)(?:\s|$)')) {
            if ($match.Groups[1].Value -eq $Game.steam_id -or $match.Groups[2].Value -eq $Game.steam_id) { return $true }
        }
    } elseif ($Game.kind -eq 'xbox') {
        $command=([string](Field $App 'cmd'))+' '+((@(Field $App 'detached' @())) -join ' ')
        if ((Field $App 'aumid') -ieq $Game.aumid -or $command.IndexOf($Game.aumid,[StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    } elseif ($Game.kind -eq 'ea') {
        $ids=@($Game.ea_content_id)+@($Game.ea_content_ids)
        foreach ($eaId in @(EA-IdList ([string](Field $App 'ea-id')))) {
            if ($eaId -in $ids) { return $true }
        }
        $command=([string](Field $App 'cmd'))+' '+((@(Field $App 'detached' @())) -join ' ')
        if (EA-CommandMatches $command $ids) { return $true }
    }
    # A matching title is ambiguous, so leave it for the user rather than duplicate it.
    $title=Title-Key $Game.title
    return $title -ne '' -and (Title-Key ([string](Field $App 'name'))) -ceq $title
}
function Build-Plan($Games,$Apps,$State,[string]$Runtime,[string]$Data) {
    $result=@()
    $seen=@{}
    foreach ($game in @($Games)) {
        if ($game.uuid -ne (Stable-Id $game.key)) { throw 'Inventaire incoherent : identifiant de jeu invalide.' }
        if (($game.kind -eq 'steam' -and ($game.steam_id -notmatch '^\d+$' -or $game.key -ine ('steam:'+$game.steam_id))) -or
            ($game.kind -eq 'xbox' -and (-not $game.aumid -or $game.key -ine ('xbox:'+$game.aumid))) -or
            ($game.kind -eq 'ea' -and (-not (EA-ValidId $game.ea_content_id) -or $game.key -ine ('ea:'+$game.ea_content_id))) -or $game.kind -notin @('steam','xbox','ea')) {
            throw 'Inventaire incoherent : fournisseur et identifiant ne correspondent pas.'
        }
        if ($seen.ContainsKey($game.uuid)) {
            if (-not (Same $seen[$game.uuid] $game)) { throw 'Inventaire ambigu : deux installations pour le meme identifiant.' }
            continue
        }
        $seen[$game.uuid]=$game
        $fields=Desired-Fields $game $Runtime $Data
        $found=@($Apps | Where-Object { (Field $_ 'uuid') -eq $game.uuid })
        $row=[ordered]@{key=$game.key;uuid=$game.uuid;title=$game.title;action='';reason='';changed_fields=@();fields=$fields;payload=$null;before=$null;baseline=$null}
        if (Field $State.pending $game.uuid) { $row.action='conflict';$row.reason='Ecriture precedente a verifier; aucune recreation ni mise a jour de cette entree.' }
        elseif ($found.Count -gt 1) { $row.action='conflict';$row.reason='UUID duplique dans VibeShine.' }
        elseif ($found.Count -eq 0) {
            $other=@($Apps | Where-Object { Existing-Game $_ $game })
            if ($other.Count -gt 1) { $row.action='conflict';$row.reason='Plusieurs entrees correspondantes existent deja; aucun ajout.' }
            elseif ($other.Count -eq 1) { $row.action='existing';$row['matched_uuid']=[string](Field $other[0] 'uuid');$row.reason='Entree existante par identifiant ou titre; la conserver.' }
            else {
                $creation=Get-NewGameStreamFields $game
                foreach ($name in @(Keys $creation)) { $fields[$name]=$creation[$name] }
                $row.action='add';$row.fields=$fields;$row.payload=$fields;$row.baseline=$fields
                if ($creation.Count) {
                    $row.changed_fields=@(Keys $creation)
                    $row.reason=$(if ($creation['frame-generation-mode'] -eq 'game-provided') {'Création : Frame Generation fournie par le jeu; Lossless Scaling désactivé.'} else {'Création : aucune Frame Generation coordonnée par Moonshine.'})
                }
            }
        } else {
            $app=$found[0]
            $known=Field $State.managed $game.uuid
            $other=@($Apps | Where-Object { (Field $_ 'uuid') -ne $game.uuid -and (Existing-Game $_ $game) })
            if ($other.Count -gt 0) {
                $row.action='conflict';$row.reason='Une autre entree correspond deja a ce jeu; aucune nouvelle ecriture.'
            } elseif (-not (Owned $app $game.key) -or -not $known -or $known.key -ne $game.key) {
                $row.action='conflict';$row.reason='Entree non reconnue comme geree par ce synchronisateur.'
            } elseif (Field $State.pending $game.uuid) {
                $row.action='conflict';$row.reason='Ecriture precedente a verifier; conservation de cette entree.'
            } else {
                $before=Clean-App $app
                $payload=Clean-App $app
                $baseline=To-Map $known.fields
                $preserved=@()
                $changed=@()
                foreach ($key in @(Keys $fields)) {
                    $current=Field $app $key
                    $old=Field $known.fields $key
                    $desired=Field $fields $key
                    # Failure to resolve artwork must not erase a previous cover.
                    if ($key -eq 'image-path' -and -not $desired -and $current) { continue }
                    if (App-FieldSame $key $current $desired) {
                        # Keep the API representation instead of rewriting equal
                        # paths, equivalent numeric/boolean values or identical fields.
                        $baseline[$key]=$current
                    } elseif (App-FieldSame $key $current $old) {
                        $payload[$key]=$desired
                        $baseline[$key]=$desired
                        $changed+=$key
                    } else { $preserved+=$key }
                }
                if ('cmd' -in $preserved -or 'opi5-xbox-owner' -in $preserved -or 'opi5-xbox-key' -in $preserved) {
                    $row.action='conflict';$row.reason='Commande ou identite personnalisee; aucune modification.'
                } else {
                    $row.before=$before;$row.payload=$payload;$row.baseline=$baseline
                    $row.changed_fields=@($changed)
                    if ($changed.Count -eq 0) { $row.action='unchanged' }
                    else { $row.action='update';$row.reason='Champs modifies : '+($changed -join ', ')+'.' }
                    if ($preserved.Count -gt 0) { $row.reason=($row.reason+' Personnalisations conservees : '+($preserved -join ', ')).Trim() }
                }
            }
        }
        $result+=$row
    }
    return $result
}
function Recover-Pending($State,$Apps) {
    foreach ($uuid in @(Keys $State.pending)) {
        $op=Field $State.pending $uuid
        $found=@($Apps | Where-Object { (Field $_ 'uuid') -eq $uuid })
        if ($found.Count -eq 1 -and (Same-App $found[0] $op.after)) {
            $State.managed[$uuid]=$op.new_state
            $State.pending.Remove($uuid)
            Repair-Event 'transaction' 'recovered' $uuid
        } elseif (($found.Count -eq 0 -and $null -eq $op.before) -or
                  ($found.Count -eq 1 -and $null -ne $op.before -and (Same-App $found[0] $op.before))) {
            $State.pending.Remove($uuid)
            Repair-Event 'transaction' 'retry_available' $uuid
        }
    }
    Save-State $State
}
function Session-Idle {
    if (-not (Session-IsIdle)) { throw 'Terminer la session Moonlight (Quitter la session), puis relancer la synchronisation.' }
}
function Session-IsIdle {
    $s=Api-Call 'GET' '/api/session/status'
    if ($null -eq (Field $s 'activeSessions') -or $null -eq (Field $s 'appRunning')) { throw 'Etat de session VibeShine inconnu.' }
    $count=0L
    if (-not [long]::TryParse([string]$s.activeSessions,[ref]$count) -or $count -lt 0) { throw 'Nombre de sessions VibeShine invalide; aucune écriture.' }
    $running=Field $s 'appRunning'
    if ($running -is [string] -and ($running -ceq 'true' -or $running -ceq 'false')) { $running=$running -ceq 'true' }
    if ($running -isnot [bool]) { throw 'État du jeu VibeShine invalide; aucune écriture.' }
    return $count -eq 0 -and -not $running
}
function Save-Runtime($Game) {
    # Only launch data: cache timestamps and artwork diagnostics do not rewrite
    # a descriptor on every scan.
    $descriptor=[ordered]@{}
    $source=To-Map $Game
    foreach ($key in @('key','uuid','kind','title','install','steam_id','aumid','monitor_names','ea_content_id','ea_content_ids')) {
        if ($source.Contains($key)) { $descriptor[$key]=$source[$key] }
    }
    $descriptor['schema']='opi5-xbox-game/1'
    $descriptor['user_sid']=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $path=Join-Path (Join-Path $script:Data 'Games') ($Game.uuid+'.json')
    $current=$null;$damaged=$false;$exists=Test-Path -LiteralPath $path -PathType Leaf
    try {
        $current=Read-Json $path
        if ($exists -and (-not $current -or $current.schema -ne 'opi5-xbox-game/1' -or $current.uuid -ne $Game.uuid -or $current.key -ne $Game.key)) { $damaged=$true }
    } catch { $damaged=$true }
    if ($damaged) { Preserve-RecoveryFile $path 'descriptor' }
    if (-not (Same $current $descriptor)) {
        Write-Json $path $descriptor
        if ($damaged -or -not $exists) { Repair-Event 'descriptor' 'rebuilt' $Game.title }
    }
}
function Plan-Summary($Plan) {
    foreach ($r in @($Plan)) { [pscustomobject]@{Action=$r.action;Jeu=$r.title;Detail=$r.reason} }
}
function Apply-Plan($Plan,$Games,$State,$AppsRoot) {
    Operation-Checkpoint
    Session-Idle
    $changes=@($Plan | Where-Object { $_.action -in @('add','update') })
    if ($changes.Count -eq 0) {
        foreach ($row in @($Plan | Where-Object { $_.action -eq 'unchanged' })) {
            Operation-Checkpoint
            $game=@($Games | Where-Object { $_.uuid -eq $row.uuid })[0]
            Save-Runtime $game
        }
        Write-Host 'Aucun ajout ni changement du catalogue necessaire.'
        return
    }
    $folder=Join-Path (Join-Path $script:Data 'Backups') ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    # Local backup only. It may include private custom commands; never in the share ZIP.
    Write-Json (Join-Path $folder 'apps-avant.json') $AppsRoot
    Write-Json (Join-Path $folder 'state-avant.json') $State
    $journal=[ordered]@{schema='opi5-xbox-transaction/1';created=(Get-Date).ToString('o');complete=$false;operations=@()}
    Write-Json (Join-Path $folder 'transaction.json') $journal
    foreach ($row in @($Plan | Where-Object { $_.action -in @('add','update','unchanged') })) {
        Operation-Checkpoint
        $game=@($Games | Where-Object { $_.uuid -eq $row.uuid })[0]
        $runtimeFile=Join-Path (Join-Path $script:Data 'Games') ($row.uuid+'.json')
        if (Test-Path -LiteralPath $runtimeFile) { Copy-Item -LiteralPath $runtimeFile -Destination (Join-Path $folder ($row.uuid+'.game-avant.json')) }
        if ($row.action -eq 'unchanged') { Save-Runtime $game; continue }
        Session-Idle
        # Re-read immediately before each write; UUID addressing avoids index drift.
        $current=Get-Apps
        $again=@($current.apps | Where-Object { (Field $_ 'uuid') -eq $row.uuid })
        if (($row.action -eq 'add' -and $again.Count -gt 0) -or
            ($row.action -eq 'update' -and ($again.Count -ne 1 -or -not (Same-App $again[0] $row.before)))) {
            throw 'Le catalogue a change depuis l apercu. Relancer la synchronisation.'
        }
        $duplicates=@($current.apps | Where-Object { (Field $_ 'uuid') -ne $row.uuid -and (Existing-Game $_ $game) })
        if ($duplicates.Count -gt 0) { throw ('Une autre entree correspond maintenant a '+$game.title+'. Refaire l apercu.') }
        $newState=[ordered]@{key=$row.key;fields=$row.baseline}
        $op=[ordered]@{uuid=$row.uuid;key=$row.key;before=$row.before;after=$row.payload;old_state=(Field $State.managed $row.uuid);new_state=$newState;verified=$false}
        $journal.operations+=@($op)
        Write-Json (Join-Path $folder 'transaction.json') $journal
        $State.pending[$row.uuid]=$op
        Save-State $State
        Save-Runtime $game
        $writeFailure=$null
        try { $null=Api-Call 'POST' '/api/apps' $row.payload }
        catch { $writeFailure=$_ }
        # A lost POST response is not a reason to POST twice. Re-read by UUID;
        # a matching result finishes the journal, otherwise it remains pending.
        $check=Get-Apps
        $saved=@($check.apps | Where-Object { (Field $_ 'uuid') -eq $row.uuid })
        if ($saved.Count -ne 1 -or -not (Same-App $saved[0] $row.payload)) {
            if ($writeFailure) { throw $writeFailure }
            throw 'Verification apres enregistrement incomplete. Relancer l apercu avant toute autre modification.'
        }
        if ($writeFailure) { Repair-Event 'transaction' 'response_recovered' $row.title }
        $concurrent=@($check.apps | Where-Object { (Field $_ 'uuid') -ne $row.uuid -and (Existing-Game $_ $game) })
        if ($concurrent.Count -gt 0) {
            throw ('Une autre entree est apparue simultanement pour '+$row.title+'. Synchronisation suspendue; examiner le catalogue avant de continuer.')
        }
        $op.verified=$true
        $State.managed[$row.uuid]=$newState
        $State.pending.Remove($row.uuid)
        Save-State $State
        Write-Json (Join-Path $folder 'transaction.json') $journal
        Write-Host ('  '+$row.action+' : '+$row.title) -ForegroundColor Green
    }
    $final=Get-Apps
    $verifyPlan=@(Build-Plan $Games $final.apps $State $script:Runtime $script:Data)
    $checkedIds=@($Plan | Where-Object { $_.action -in @('add','update','unchanged') } | ForEach-Object { $_.uuid })
    $unstable=@($verifyPlan | Where-Object { $_.uuid -in $checkedIds -and $_.action -ne 'unchanged' })
    if ($unstable.Count -gt 0) {
        throw ('Catalogue instable apres verification; aucune nouvelle ecriture automatique dans ce passage. Jeux : '+(($unstable | ForEach-Object { $_.title+' ['+($_.changed_fields -join ', ')+']' }) -join '; '))
    }
    $journal.complete=$true
    Write-Json (Join-Path $folder 'transaction.json') $journal
    Write-Host ('Synchronisation terminee. '+$changes.Count+' entree(s) ajoutee(s) ou mise(s) a jour.')
}

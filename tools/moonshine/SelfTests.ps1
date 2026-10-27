#Requires -Version 5.1
function Invoke-SelfTests {
    function Assert([bool]$Condition,[string]$Message) {
        Operation-Checkpoint
        if ($script:GuiBridge) { $script:GuiBridge.Publish('progress',('Vérification du programme · étape '+($script:SelfTestCount+1)),-1,$null) }
        $script:SelfTestCheckpoint=$Message
        if (-not $Condition) { throw ('Autotest echoue : '+$Message) }
        $script:SelfTestCount++
    }
    $script:SelfTestCount=0
    $script:SelfTestCheckpoint='Analyse syntaxique'
    foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
        $tokens=$null;$errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert (@($errors).Count -eq 0) ('Syntaxe PowerShell : '+$file.Name)
    }
    $id=Stable-Id 'steam:990080'
    Assert ($id.Length -eq 36 -and $id -match '^706c6f73-7862-8[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$') 'Format UUIDv8 prive'
    Assert ((Stable-Id 'XBOX:Microsoft.Game_abc!Game') -ceq (Stable-Id 'xbox:microsoft.game_abc!game')) 'Identite Windows insensible a la casse'
    Assert ($id -ne (Stable-Id 'steam:1926590')) 'Pas de collision entre deux jeux'
    $launchCommand=Get-Command (Join-Path $PSScriptRoot 'Launch-Game.ps1')
    $pattern=@($launchCommand.Parameters['GameId'].Attributes | Where-Object { $_ -is [Management.Automation.ValidatePatternAttribute] })[0].RegexPattern
    Assert ($id -match $pattern) 'UUID accepte par le vrai lanceur'
    $paths=@(Unique-Paths @('C:\Games\Steam','c:\games\steam\','C:\Other'))
    Assert ($paths.Count -eq 2) 'Dedoublonnage des chemins Windows'
    Assert ((Vdf-Value '"name" "Nancy Drew" "appid" "1926590"' 'appid') -eq '1926590') 'Lecture identifiant Steam'
    Assert ((Vdf-Value '"path" "C:\\Games\\Steam"' 'path') -eq 'C:\Games\Steam') 'Decodage chemin Steam'
    Assert (Same @{a=1;b=@(2,3)} ([ordered]@{b=@(2,3);a=1})) 'Comparaison JSON independante de l ordre des champs'
    Assert (-not (Same @{a=$false} @{a='false'})) 'Comparaison sensible aux types'
    Assert (-not (Same @{a=@()} @{a=$null})) 'Tableau vide distinct de null'
    Assert ((Parse-Port '') -eq 47990 -and (Parse-Port ' [47990] ') -eq 47990 -and (Parse-Port '48000') -eq 48000) 'Port par defaut, nombre et crochets acceptes'
    $bad=$false;try { $null=Parse-Port '65536' } catch { $bad=$true }
    Assert $bad 'Port hors limites refuse'
    $mapSource=[pscustomobject]@{empty=@();one=@('un');two=@('un','deux');optional=$null}
    Assert (Same (To-Map $mapSource) $mapSource) 'Copie des tableaux JSON sans perte de type ou de longueur'
    $emptyJson='{}' | ConvertFrom-Json
    Assert (@(Keys $emptyJson).Count -eq 0) 'Objet JSON vide sans fausse cle null'
    Assert ((To-Map $emptyJson).Count -eq 0) 'Conversion d un objet JSON vide en dictionnaire vide'
    Assert (@(Keys $null).Count -eq 0 -and @(Keys @{}).Count -eq 0) 'Absence de cles pour null et dictionnaire vide'
    $game=[ordered]@{key='steam:990080';uuid=$id;kind='steam';title='Hogwarts Legacy';steam_id='990080';install='C:\Games\Hogwarts';cover=''}
    $desktop=@{uuid='00000000-0000-4000-8000-000000000001';name='Desktop';cmd=''}
    $state=Empty-State
    $plan=@(Build-Plan @($game) @($desktop) $state 'C:\Tool' 'C:\Data')
    Assert ($plan.Count -eq 1 -and $plan[0].action -eq 'add') 'Ajout initial'
    Assert (@(Build-Plan @($game,(Clone-Object $game)) @($desktop) (Empty-State) 'C:\Tool' 'C:\Data').Count -eq 1) 'Meme jeu repete dans l inventaire : un seul plan'
    $ambiguous=To-Map $game;$ambiguous.install='D:\Autre installation'
    $bad=$false;try { $null=Build-Plan @($game,$ambiguous) @($desktop) (Empty-State) 'C:\Tool' 'C:\Data' } catch { $bad=$true }
    Assert $bad 'Deux installations contradictoires ne sont pas fusionnees'
    Assert ($desktop.name -eq 'Desktop' -and $desktop.cmd -eq '') 'Entree existante non modifiee'
    $app=Clone-Object $plan[0].payload
    $state.managed[$id]=@{key=$game.key;fields=(Clone-Object $plan[0].baseline)}
    $again=@(Build-Plan @($game) @($desktop,$app) $state 'C:\Tool' 'C:\Data')
    Assert ($again[0].action -eq 'unchanged') 'Deuxieme synchronisation sans doublon'
    $manual=Clone-Object $app
    $manual.name='Mon titre personnel'
    $manual | Add-Member -NotePropertyName 'config-overrides' -NotePropertyValue @{fps=60}
    $newGame=To-Map $game;$newGame.title='Titre officiel actualise';$newGame.install='D:\Games\Hogwarts'
    $edited=@(Build-Plan @($newGame) @($manual) $state 'C:\Tool' 'C:\Data')[0]
    Assert ($edited.action -eq 'update') 'Mise a jour du chemin Steam'
    Assert ($edited.payload.name -eq 'Mon titre personnel') 'Titre personnalise conserve'
    Assert ((Field $edited.payload 'config-overrides').fps -eq 60) 'Reglages personnalises conserves'
    Assert ($edited.payload['steam-install-dir'] -eq 'D:\Games\Hogwarts') 'Champ gere actualise'
    $customArt=Clone-Object $app;$customArt.'image-path'='C:\Mes pochettes\Hogwarts.png'
    $withArt=To-Map $game;$withArt.cover='C:\Data\Artwork\nouvelle.png'
    $artPlan=@(Build-Plan @($withArt) @($customArt) $state 'C:\Tool' 'C:\Data')[0]
    Assert ($artPlan.payload['image-path'] -eq 'C:\Mes pochettes\Hogwarts.png') 'Pochette choisie manuellement conservee'
    $previousArt=Clone-Object $app;$previousArt.'image-path'='C:\Data\Artwork\ancienne.png'
    $artState=Empty-State
    $artState.managed[$id]=@{key=$game.key;fields=(Clone-Object $previousArt)}
    $missingArt=@(Build-Plan @($game) @($previousArt) $artState 'C:\Tool' 'C:\Data')[0]
    Assert ($missingArt.action -eq 'unchanged' -and $missingArt.payload['image-path'] -eq 'C:\Data\Artwork\ancienne.png') 'Une recherche d image infructueuse conserve la pochette precedente'
    Assert ($manual.'steam-install-dir' -eq 'C:\Games\Hogwarts') 'Plan sans mutation de la source'
    $manual.cmd='ma-commande-personnelle'
    $conflict=@(Build-Plan @($game) @($manual) $state 'C:\Tool' 'C:\Data')[0]
    Assert ($conflict.action -eq 'conflict') 'Commande modifiee protegee'
    $nativeSteam=@{uuid='steam-native';name='Autre nom';'steam-id'='990080';cmd='steam://rungameid/990080'}
    $duplicate=@(Build-Plan @($game) @($nativeSteam) (Empty-State) 'C:\Tool' 'C:\Data')[0]
    Assert ($duplicate.action -eq 'existing') 'Integration Steam native non dupliquee'
    $preexisting=@(Build-Plan @($game) @($app,$nativeSteam) $state 'C:\Tool' 'C:\Data')[0]
    Assert ($preexisting.action -eq 'conflict') 'Doublon deja present signale sans nouvelle ecriture'
    $detached=@{uuid='detached';name='Renomme';cmd='';detached=@('steam://rungameid/990080')}
    Assert ((@(Build-Plan @($game) @($detached) (Empty-State) 'C:\Tool' 'C:\Data')[0]).action -eq 'existing') 'Commande Steam detachee reconnue'
    $multiple=@{uuid='multiple';name='Renomme';cmd='steam://rungameid/123';detached=@('steam://rungameid/990080')}
    Assert ((@(Build-Plan @($game) @($multiple) (Empty-State) 'C:\Tool' 'C:\Data')[0]).action -eq 'existing') 'Toutes les commandes Steam sont examinees pour les doublons'
    $xboxKey='xbox:Microsoft.ForzaMotorsport_8wekyb3d8bbwe!ReleaseFinal'
    $xbox=@{key=$xboxKey;uuid=(Stable-Id $xboxKey);kind='xbox';title='Forza Motorsport';aumid='Microsoft.ForzaMotorsport_8wekyb3d8bbwe!ReleaseFinal';install='C:\XboxGames\Forza';cover=''}
    $xboxManual=@{uuid='xbox-manuel';name='Forza personnel';cmd='explorer.exe shell:AppsFolder\Microsoft.ForzaMotorsport_8wekyb3d8bbwe!ReleaseFinal'}
    Assert ((@(Build-Plan @($xbox) @($xboxManual) (Empty-State) 'C:\Tool' 'C:\Data')[0]).action -eq 'existing') 'Raccourci Xbox manuel reconnu par son AUMID'
    $xboxFirst=@(Build-Plan @($xbox) @($desktop) (Empty-State) 'C:\Tool' 'C:\Data')[0]
    $xboxState=Empty-State;$xboxState.managed[$xbox.uuid]=@{key=$xboxKey;fields=(Clone-Object $xboxFirst.baseline)}
    Assert ((@(Build-Plan @($xbox) @($xboxFirst.payload) $xboxState 'C:\Tool' 'C:\Data')[0]).action -eq 'unchanged') 'Deuxieme synchronisation Xbox sans doublon'
    $symbolGame=To-Map $game;$symbolGame.title='Nancy Drew®: Mystery of the Seven Keys'
    $symbolApp=@{uuid='manual-title';name='Nancy Drew - Mystery of the Seven Keys';cmd='personnel'}
    Assert ((@(Build-Plan @($symbolGame) @($symbolApp) (Empty-State) 'C:\Tool' 'C:\Data')[0]).action -eq 'existing') 'Titre avec marques et ponctuation reconnu sans doublon'
    Assert ((Title-Key 'Cities II') -ne (Title-Key 'Cities III')) 'Versions differentes du titre restent distinctes'
    $manualUri=@{uuid='manual';name='Autre nom';cmd='steam://rungameid/990080'}
    Assert ((@(Build-Plan @($game) @($manualUri) (Empty-State) 'C:\Tool' 'C:\Data')[0]).action -eq 'existing') 'Raccourci Steam manuel non duplique'
    $foreign=@{uuid=$id;name='Hogwarts Legacy';cmd='autre'}
    Assert ((@(Build-Plan @($game) @($foreign) $state 'C:\Tool' 'C:\Data')[0]).action -eq 'conflict') 'Collision UUID protegee'
    Assert (@(Build-Plan @() @($app) $state 'C:\Tool' 'C:\Data').Count -eq 0) 'Inventaire vide ne supprime rien'
    $dirty=To-Map $app;$dirty['index']=7;$dirty['id']='100';$dirty['image-version']=42
    Assert (Same (Clean-App $dirty) (Clean-App $app)) 'Champs transitoires API exclus'
    $emptyFields=To-Map $app;$emptyFields['detached']=@();$emptyFields['prep-cmd']=@()
    Assert (Same (Clean-App $emptyFields) (Clean-App $app)) 'Normalisation des seuls tableaux vides retires par VibeShine'
    $commands=To-Map $app;$commands['prep-cmd']=@(@{do='commande';undo='retour'});$commands['detached']=@('premier','deuxieme')
    Assert (Same (Clean-App $commands) $commands) 'Commandes et tableaux non vides integralement conserves'
    $pendingState=Empty-State
    $pendingState.managed[$id]=$state.managed[$id]
    $pendingState.pending[$id]=@{key=$game.key}
    Assert ((@(Build-Plan @($game) @($app) $pendingState 'C:\Tool' 'C:\Data')[0]).action -eq 'conflict') 'Ecriture incertaine non ecrasee'
    Assert ((@(Build-Plan @($game) @() $pendingState 'C:\Tool' 'C:\Data')[0]).action -eq 'conflict') 'Écriture incertaine bloque aussi la recréation si l entrée API a disparu'
    Assert ($duplicate.matched_uuid -eq 'steam-native') 'Entrée manuelle correspondante identifiée pour consultation sans prise de contrôle'
    $savedData=$script:Data
    $temporary=Join-Path $env:TEMP ('opi5-xbox-selftest-'+[guid]::NewGuid().ToString('N'))
    try {
        $script:Data=$temporary
        $script:SelfTestCheckpoint='Etat vide sauvegarde puis recharge depuis JSON'
        Save-State (Empty-State)
        $loaded=Load-State
        Assert ($loaded.managed.Count -eq 0 -and $loaded.pending.Count -eq 0) 'Etat vide rechargeable apres sauvegarde JSON'
        $script:SelfTestCheckpoint='Pilote sauvegarde puis import de six jeux'
        $sixGames=@($game,$xbox)
        foreach ($steamId in @('1926590','4374500')) {
            $extra=To-Map $game;$extra.key='steam:'+$steamId;$extra.uuid=Stable-Id $extra.key
            $extra.steam_id=$steamId;$extra.title='Jeu Steam '+$steamId;$extra.install='C:\Games\'+$steamId
            $sixGames+=$extra
        }
        foreach ($appId in @('Synthetic.Cities_pkg!Game','Synthetic.Indy_pkg!Game')) {
            $extra=To-Map $xbox;$extra.key='xbox:'+$appId;$extra.uuid=Stable-Id $extra.key
            $extra.aumid=$appId;$extra.title=$appId;$extra.install='C:\Games\'+$appId.Replace('!','_')
            $sixGames+=$extra
        }
        $completedPilot=Empty-State
        $completedPilot.managed[$id]=$state.managed[$id]
        $completedPilot.managed[$xbox.uuid]=$xboxState.managed[$xbox.uuid]
        Save-State $completedPilot
        $loaded=Load-State
        Assert ($loaded.managed.Count -eq 2 -and $loaded.pending.Count -eq 0) 'Deux jeux pilotes conserves et journal vide recharge'
        Recover-Pending $loaded @($desktop,$app,$xboxFirst.payload)
        $fullPlan=@(Build-Plan $sixGames @($desktop,$app,$xboxFirst.payload) $loaded 'C:\Tool' 'C:\Data')
        Assert (@($fullPlan | Where-Object { $_.action -eq 'add' }).Count -eq 4 -and @($fullPlan | Where-Object { $_.action -eq 'unchanged' }).Count -eq 2) 'Apres rechargement : quatre ajouts et deux pilotes deja presents'
        $sixApps=@($desktop)
        foreach ($row in $fullPlan) {
            $sixApps+=$row.payload
            $loaded.managed[$row.uuid]=@{key=$row.key;fields=$row.baseline}
        }
        Save-State $loaded
        $loaded=Load-State
        $repeat=@(Build-Plan $sixGames $sixApps $loaded 'C:\Tool' 'C:\Data')
        Assert ($repeat.Count -eq 6 -and @($repeat | Where-Object { $_.action -ne 'unchanged' }).Count -eq 0) 'Six jeux sauvegardes et recharges sans aucun nouvel ajout'
        $withPending=Empty-State
        $withPending.pending[$id]=@{before=$null;after=$app;new_state=$state.managed[$id]}
        Save-State $withPending
        $loaded=Load-State
        Recover-Pending $loaded @($app)
        $loaded=Load-State
        Assert ($loaded.managed.Count -eq 1 -and $loaded.pending.Count -eq 0) 'Reprise d ecriture depuis un journal JSON puis nouveau rechargement'

        $script:SelfTestCheckpoint='Metadonnees EA et lancement sans commandes libres'
        $eaRoot=Join-Path $temporary 'EA Test'
        [IO.Directory]::CreateDirectory((Join-Path $eaRoot '__Installer')) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $eaRoot 'GameEA.exe'),[byte[]]@(0))
        [IO.File]::WriteAllBytes((Join-Path $eaRoot 'EAAntiCheat.GameServiceLauncher.exe'),[byte[]]@(0))
        $eaXml='<DiPManifest><gameTitle>EA Test</gameTitle><contentIDs><contentID>16425629</contentID><contentID>ALT-16425629</contentID></contentIDs><runtime><launcher><filePath>[INSTALLDIR]\GameEA.exe</filePath></launcher><launcher><filePath>[INSTALLDIR]\EAAntiCheat.GameServiceLauncher.exe</filePath></launcher></runtime></DiPManifest>'
        [IO.File]::WriteAllText((Join-Path $eaRoot '__Installer\installerdata.xml'),$eaXml)
        $eaMeta=EA-ReadMetadata $eaRoot 'Titre provisoire' @('REGISTRY-ONLY')
        Assert ($eaMeta.manifest_status -eq 'read' -and -not $eaMeta.reason -and $eaMeta.content_ids.Count -eq 2) 'Identifiants EA lus dans le manifeste local'
        Assert ($eaMeta.monitor_names.Count -eq 1 -and $eaMeta.monitor_names[0] -eq 'GameEA') 'Lanceur antitriche exclu des noms de jeu suivis'
        Assert ($eaMeta.icon_executable -eq (Join-Path $eaRoot 'GameEA.exe')) ('Icone associee au seul executable de jeu identifie : '+(ConvertTo-Json -InputObject $eaMeta -Depth 10 -Compress))
        [IO.File]::WriteAllBytes((Join-Path $temporary 'outside.exe'),[byte[]]@(0))
        Assert ((EA-ResolveFile $eaRoot '..\outside.exe') -eq '') 'Chemin EA hors de l installation refuse'
        Assert ((EA-LaunchUri '16425629') -ceq 'origin2://game/launch?offerIds=16425629') 'URI EA construite depuis l identifiant confirme uniquement'
        $bad=$false;try { $null=EA-LaunchUri '16425629&autoDownload=1' } catch { $bad=$true }
        Assert $bad 'Injection de parametre dans un identifiant EA refusee'
        $eaRef=@{key='ea:16425629'};$eaProtocol=@{ready=$true;reason=''}
        $eaResolved=EA-BuildGame $eaRef @($eaMeta) $eaProtocol
        Assert ($null -ne $eaResolved.ready -and $null -eq $eaResolved.pending) 'Jeu EA importable apres recoupement Xbox manifeste et protocole'
        $eaAlias=EA-BuildGame @{key='ea:ALT-16425629'} @($eaMeta) $eaProtocol
        Assert ($eaAlias.ready.uuid -eq $eaResolved.ready.uuid) 'Deux alias Xbox EA donnent une seule identite stable'
        $eaComposite=EA-BuildGame @{key='ea:16425629,ALT-16425629'} @($eaMeta) $eaProtocol
        Assert ($eaComposite.ready.uuid -eq $eaResolved.ready.uuid -and $eaComposite.ready.ea_matched_ids.Count -eq 2) 'Reference Xbox EA a deux identifiants resolue en un seul jeu'
        $eaSecond=EA-BuildGame @{key='ea:UNKNOWN,16425629'} @($eaMeta) $eaProtocol
        Assert ($eaSecond.ready.uuid -eq $eaResolved.ready.uuid -and $eaSecond.ready.ea_matched_ids.Count -eq 1) 'Un alias confirme suffit si l autre ne figure pas dans le manifeste'
        $fcMeta=To-Map $eaMeta;$fcMeta.ids=@('16425884');$fcMeta.content_ids=@('16425884')
        $reported=EA-BuildGame @{key='ea:16425884,16425884_sc'} @($fcMeta) $eaProtocol
        Assert ($reported.ready.ea_content_id -eq '16425884' -and $reported.ready.ea_xbox_keys[0] -eq 'ea:16425884,16425884_sc') 'Regression du format exact signale par PL : identifiant principal et suffixe sc'
        $otherMeta=To-Map $fcMeta;$otherMeta.ids=@('16425884_sc');$otherMeta.content_ids=@('16425884_sc');$otherMeta.install='D:\Autre jeu'
        $mixed=EA-BuildGame @{key='ea:16425884,16425884_sc'} @($fcMeta,$otherMeta) $eaProtocol
        Assert ($null -eq $mixed.ready -and $mixed.pending.reason -like 'Plusieurs installations*') 'Reference composite pointant vers deux installations laissee en attente'
        Assert (@(EA-ReferenceIds 'ea: 16425884 , 16425884_sc,16425884').Count -eq 2) 'Espaces et repetition d un alias EA geres'
        $invalidCount=0
        foreach ($key in @('ea:16425884,','ea:,16425884','ea:16425884,,16425884_sc','ea:16425884,other&autoDownload=1','steam:16425884')) {
            if (@(EA-ReferenceIds $key).Count -eq 0) { $invalidCount++ }
        }
        Assert ($invalidCount -eq 5) 'Reference EA invalide refusee entierement sans recuperation partielle'
        Assert ((EA-LaunchUri $reported.ready.ea_content_id) -eq 'origin2://game/launch?offerIds=16425884') 'Lancement utilise le contentID local et non la liste Xbox brute'
        $eaMissing=EA-BuildGame @{key='ea:REGISTRY-ONLY'} @($eaMeta) $eaProtocol
        Assert ($null -eq $eaMissing.ready -and $null -ne $eaMissing.pending) 'Identifiant du registre seul insuffisant pour lancer un jeu EA'
        $eaNoProtocol=EA-BuildGame $eaRef @($eaMeta) @{ready=$false;reason='Protocole absent'}
        Assert ($null -eq $eaNoProtocol.ready) 'Jeu EA en attente si le protocole du launcher manque'
        $eaMultiple=EA-BuildGame $eaRef @($eaMeta,$eaMeta) $eaProtocol
        Assert ($null -eq $eaMultiple.ready) 'Installations EA ambigues non importees'
        $eaManual=@{uuid='manual-ea';name='Titre personnalise';cmd='origin2://game/launch?offerIds=16425629'}
        $eaPlan=@(Build-Plan @($eaResolved.ready) @($eaManual) (Empty-State) 'C:\Tool' 'C:\Data')
        Assert ($eaPlan[0].action -eq 'existing') 'Raccourci EA manuel reconnu sans doublon'
        $manualEaIds=@{uuid='manual-ea-list';name='Titre personnel';cmd='';'ea-id'='UNKNOWN,16425629'}
        Assert ((@(Build-Plan @($eaResolved.ready) @($manualEaIds) (Empty-State) 'C:\Tool' 'C:\Data')[0]).action -eq 'existing') 'Entree existante avec champ ea-id composite conservee sans doublon'
        $mergedEa=@{}
        foreach ($g in @($eaResolved.ready,$eaComposite.ready,$eaSecond.ready)) { $null=EA-MergeGame $mergedEa $g }
        $eaMultiPlan=@(Build-Plan @($mergedEa.Values) @() (Empty-State) 'C:\Tool' 'C:\Data')
        Assert ($eaMultiPlan.Count -eq 1 -and $eaMultiPlan[0].action -eq 'add' -and $mergedEa[$eaResolved.ready.key].ea_xbox_keys.Count -eq 3) 'Alias simples et composites regroupes avant le plan : un seul ajout EA'
        $eaDifferent=To-Map $eaResolved.ready;$eaDifferent.install='D:\Autre installation EA'
        $bad=$false;try { $null=EA-MergeGame $mergedEa $eaDifferent } catch { $bad=$true }
        Assert $bad 'Fusion EA refusee lorsque les dossiers d installation se contredisent'
        Assert ((EA-CommandMatches 'origin2://game/launch?offerIds=OTHER,ALT-16425629' @('ALT-16425629')) -and -not (EA-CommandMatches 'origin2://game/launch?offerIds=164256290' @('16425629'))) 'Identification EA exacte parmi plusieurs identifiants'
        $eaFirst=@(Build-Plan @($eaResolved.ready) @() (Empty-State) 'C:\Tool' 'C:\Data')[0]
        $eaState=Empty-State;$eaState.managed[$eaFirst.uuid]=@{key=$eaFirst.key;fields=$eaFirst.baseline}
        Save-State $eaState
        $eaRepeat=@(Build-Plan @($eaResolved.ready) @($eaFirst.payload) (Load-State) 'C:\Tool' 'C:\Data')[0]
        Assert ($eaRepeat.action -eq 'unchanged' -and $eaFirst.payload['auto-detach'] -eq $false) 'Entree EA rechargeable sans doublon avec suivi du lanceur'
        $eaCompositeRepeat=@(Build-Plan @($eaComposite.ready) @($eaFirst.payload) (Load-State) 'C:\Tool' 'C:\Data')[0]
        Assert ($eaCompositeRepeat.action -eq 'unchanged') 'Passage d une reference EA simple a composite sans recreer l entree existante'
        Assert (@(EA-SelectGames @($game,$xbox,$eaResolved.ready,$reported.ready)).Count -eq 2) 'Selection EA exclut les jeux Steam et Xbox'
        Assert ((@(EA-SelectGames @($reported.ready,$eaResolved.ready) $true))[0].key -eq 'ea:16425629') 'Pilote EA conserve la priorite de PGA Tour'
        Assert (@(EA-SelectGames @($game,$xbox) $true).Count -eq 0) 'Selection EA vide sans element null'
        Assert ((@(EA-SelectGames @($reported.ready) $true))[0].key -eq 'ea:16425884') 'Pilote EA disponible quand PGA Tour est absent'
        Assert (EA-IsGameProcess (Join-Path $eaRoot 'GameEA.exe') 'GameEA' $eaRoot @('GameEA')) 'Vrai processus EA dans le dossier du jeu retenu'
        Assert (-not (EA-IsGameProcess ($eaRoot+'-autre\GameEA.exe') 'GameEA' $eaRoot @('GameEA'))) 'Dossier voisin avec meme nom de processus exclu'
        Assert (-not (EA-IsGameProcess (Join-Path $eaRoot 'EAAntiCheat.GameServiceLauncher.exe') 'EAAntiCheat.GameServiceLauncher' $eaRoot @())) 'Fermeture du lanceur antitriche sans faux arret du jeu'
        Assert (-not (EA-IsGameProcess (Join-Path $eaRoot '__Installer\helper.exe') 'helper' $eaRoot @())) 'Processus d installation exclu du suivi EA'
        Assert ((EA-IsGameProcess '' 'GameEA' $eaRoot @('GameEA')) -and -not (EA-IsGameProcess '' 'Inconnu' $eaRoot @('GameEA'))) 'Processus protege accepte seulement avec un nom declare'
        $helperOnly=$eaXml.Replace('<launcher><filePath>[INSTALLDIR]\GameEA.exe</filePath></launcher>','')
        [IO.File]::WriteAllText((Join-Path $eaRoot '__Installer\installerdata.xml'),$helperOnly)
        $eaHelperOnly=EA-ReadMetadata $eaRoot
        Assert ($eaHelperOnly.monitor_names.Count -eq 0 -and $eaHelperOnly.icon_executable -eq (Join-Path $eaRoot 'GameEA.exe')) 'Icone de repli sans inventer un nom de processus protege'
        $icoFile=Join-Path $eaRoot '__Installer\Game.ico'
        [IO.File]::WriteAllBytes($icoFile,[byte[]]@(0))
        $iconXml=$helperOnly.Replace('</DiPManifest>','<gameIcon>[INSTALLDIR]\__Installer\Game.ico</gameIcon></DiPManifest>')
        [IO.File]::WriteAllText((Join-Path $eaRoot '__Installer\installerdata.xml'),$iconXml)
        $withIcon=EA-ReadMetadata $eaRoot '' @() @(('"'+(Join-Path $eaRoot 'GameEA.exe')+'",0'))
        Assert ($withIcon.icon_candidates.Count -eq 2 -and $withIcon.icon_candidates[0] -eq $icoFile) 'ICO declare dans le manifeste puis DisplayIcon du registre associes au jeu'
        Assert ((EA-IconFile $eaRoot ('"'+(Join-Path $eaRoot 'GameEA.exe')+'",0')) -eq (Join-Path $eaRoot 'GameEA.exe')) 'DisplayIcon avec guillemets et index zero reconnu'
        Assert (-not (EA-IconFile $eaRoot '..\outside.exe') -and -not (EA-IconFile $eaRoot 'GameEA.exe,1') -and -not (EA-IconFile $eaRoot 'EAAntiCheat.GameServiceLauncher.exe')) 'Icones hors installation, index inconnu et antitriche refuses'
        [IO.File]::WriteAllText((Join-Path $eaRoot '__Installer\installerdata.xml'),'<incomplet>')
        $eaBroken=EA-ReadMetadata $eaRoot
        Assert ($eaBroken.manifest_status -eq 'unreadable' -and $eaBroken.reason) 'Manifeste EA incomplet laisse en attente'

        $script:SelfTestCheckpoint='Selection des variantes de logo Windows'
        $assetRoot=Join-Path $temporary 'Paquet'
        [IO.Directory]::CreateDirectory((Join-Path $assetRoot 'Assets')) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $assetRoot 'Assets\Logo.scale-100.png'),[byte[]]@(0))
        [IO.File]::WriteAllBytes((Join-Path $assetRoot 'Assets\Logo.scale-400.png'),[byte[]]@(0))
        Assert ((Package-Asset $assetRoot 'Assets\Logo.png') -like '*scale-400.png') 'Logo Windows qualifie selectionne automatiquement'
        Assert ((Package-Asset $assetRoot '..\autre.png') -eq '') 'Logo hors du paquet refuse'
        # Regression: the second save used to pass an empty backup path to .NET.
        # Exercise real filesystem calls, including literal brackets and Unicode.
        $jsonFolder=Join-Path $temporary 'écriture JSON [pilote]'
        $jsonFile=Join-Path $jsonFolder 'état du jeu.json'
        $script:SelfTestCheckpoint='Creation du fichier JSON de regression'
        $first=@{version=1;title='Jeu échantillon';enabled=$false;items=@();optional=$null}
        Write-Json $jsonFile $first
        Assert (Same (Read-Json $jsonFile) $first) 'Creation JSON avec espaces, accents et crochets'
        $script:SelfTestCheckpoint='Remplacement atomique du fichier JSON existant'
        $second=@{version=2;title='Titre actualisé';enabled=$true;items=@('un','deux');optional=$null}
        Write-Json $jsonFile $second
        Assert (Same (Read-Json $jsonFile) $second) 'Remplacement atomique du JSON avec sauvegarde temporaire explicite'
        $script:SelfTestCheckpoint='Deuxieme remplacement du meme fichier JSON'
        Write-Json $jsonFile $first
        Assert (Same (Read-Json $jsonFile) $first) 'Remplacements JSON repetes'
        $script:SelfTestCheckpoint='Valeur JSON null sous Windows PowerShell 5.1'
        $nullFile=Join-Path $jsonFolder 'last-error [nul].json'
        Write-Json $nullFile $null
        Assert ((Read-Text $nullFile) -ceq 'null' -and [IO.File]::ReadAllBytes($nullFile).Length -eq 4 -and
            $null -eq (Read-Json $nullFile)) 'Null racine ecrit en quatre octets JSON valides, pas en fichier vide'
        $oldError=@{stage='synthetique';message='Ancienne erreur de test';optional=$null}
        Write-Json $nullFile $oldError
        Assert (Same (Read-Json $nullFile) $oldError) 'Un JSON null peut etre remplace par une nouvelle erreur'
        Write-Json $nullFile $null
        Write-Json $nullFile $null
        Assert ((Read-Text $nullFile) -ceq 'null' -and $null -eq (Read-Json $nullFile)) 'Effacement puis reeffacement d une erreur apres succes sans GetBytes null'
        Assert ((Json $false) -ceq 'false' -and (Json 0) -ceq '0' -and (Json '') -ceq '""' -and
            (Json 'null') -ceq '"null"') 'Null distinct de false, zero, chaine vide et texte null'
        Assert ((Json @()) -match '\A\[\s*\]\z' -and (Json @(1)) -match '\A\[\s*1\s*\]\z') 'Serialisation directe des tableaux vides et unitaires conservee'
        $script:SelfTestCheckpoint='Refus de remplacer un fichier JSON verrouille'
        $held=[IO.File]::Open($jsonFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $refused=$false
        try {
            try { Write-Json $jsonFile $second } catch { $refused=$true }
        } finally { $held.Dispose() }
        Assert $refused 'Ecriture refusee si le fichier Windows est verrouille'
        Assert (Same (Read-Json $jsonFile) $first) 'Ancien JSON conserve apres un echec de remplacement'
        $untracked=@([IO.Directory]::GetFiles($jsonFolder,'*.tmp') | Where-Object { -not $script:AtomicRetained.ContainsKey($_) })
        Assert ($untracked.Count -eq 0) 'Fichiers temporaires nettoyes ou explicitement conserves avec diagnostic'
        $script:SelfTestCheckpoint='Reprise apres ecriture terminee'
        $recover=Empty-State
        $recover.pending[$id]=@{before=$null;after=$app;new_state=$state.managed[$id]}
        Recover-Pending $recover @($app)
        Assert ($recover.pending.Count -eq 0 -and $recover.managed.Contains($id)) 'Reprise apres ecriture terminee'
        $script:SelfTestCheckpoint='Reprise apres ecriture non commencee'
        $recover=Empty-State
        $recover.pending[$id]=@{before=$null;after=$app;new_state=$state.managed[$id]}
        Recover-Pending $recover @()
        Assert ($recover.pending.Count -eq 0 -and $recover.managed.Count -eq 0) 'Reprise apres ecriture non commencee'
        $script:SelfTestCheckpoint='Reprise ambigue'
        $recover=Empty-State
        $recover.pending[$id]=@{before=$null;after=$app;new_state=$state.managed[$id]}
        $changed=Clone-Object $app;$changed.cmd='commande-changee'
        Recover-Pending $recover @($changed)
        Assert ($recover.pending.Count -eq 1) 'Reprise ambigue conservee en conflit'
        $readback=Read-Json (Join-Path $temporary 'state.json')
        Assert ($readback.schema -eq 'opi5-xbox-state/1') 'Etat JSON ecrit et relu'
    } finally {
        $script:Data=$savedData
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
    $script:SelfTestCheckpoint='Compilation du code C# local'
    Init-Native
    Assert ($null -ne ('OPi5Native' -as [type])) 'Compilation du client HTTPS et de l activation Windows'
    $blocked=$false
    try { $null=[OPi5Native]::Send('https://example.com/api/apps','GET','',$null,'') } catch { $blocked=$true }
    Assert $blocked 'Client HTTPS limite a la boucle locale'
    $blocked=$false
    try { $null=[OPi5Native]::Send('https://127.0.0.1:47990/api/apps','GET','Bearer test',$null,'') } catch { $blocked=$true }
    Assert $blocked 'Aucun secret avant verification du certificat'
    $script:SelfTestCheckpoint='Preparation des requetes HTTP sans corps'
    $pin='A'*64
    foreach ($verb in @('GET','DELETE')) {
        foreach ($body in @($null,'')) {
            $prepared=[OPi5Native]::Prepare('https://127.0.0.1:47990/api/apps',$verb,'Bearer synthetic-test',$body,$pin)
            try { Assert ($null -eq $prepared.Body -and $prepared.Request.ContentLength -le 0) ('Aucun corps ni flux pour '+$verb+' avec null ou chaine vide') }
            finally { $prepared.Request.Abort() }
        }
    }
    $prepared=[OPi5Native]::Prepare('https://127.0.0.1:47990/api/auth/login','POST','Bearer synthetic-test','{"titre":"échantillon"}',$pin)
    try { Assert ($prepared.Request.ContentLength -eq [Text.Encoding]::UTF8.GetByteCount('{"titre":"échantillon"}')) 'Longueur POST calculee en octets UTF-8' }
    finally { $prepared.Request.Abort() }
    $bad=$false;try { $null=[OPi5Native]::Prepare('https://127.0.0.1:47990/api/apps','GET','','{}',$pin) } catch { $bad=$true }
    Assert $bad 'GET avec corps explicite refuse avant toute connexion'
    $script:SelfTestCheckpoint='Requetes HTTPS reelles contre le serveur synthetique local'
    $transportCount=[OPi5TransportTests]::Run((Join-Path $PSScriptRoot 'Transport-Test.pfx'))
    Assert ($transportCount -eq 9) 'GET POST DELETE, erreurs HTTP, redirection et certificat testes sur boucle locale'
    $script:SelfTestCount+=$transportCount
    $script:SelfTestCheckpoint='Association des pochettes a leurs identifiants exacts'
    $catalog=@{Products=@(@{ProductId='9P0TRPTHG7VF';LocalizedProperties=@(@{Images=@(
        @{ImagePurpose='Screenshot';Uri='//store-images.s-microsoft.com/image/screenshot';Width=3840;Height=2160},
        @{ImagePurpose='Poster';Uri='//store-images.s-microsoft.com/image/correct';Width=600;Height=900},
        @{ImagePurpose='Poster';Uri='https://example.com/wrong';Width=600;Height=900}
    )})})}
    $urls=@(Store-ImageUrls $catalog '9P0TRPTHG7VF')
    Assert ($urls.Count -eq 1 -and $urls[0] -eq 'https://store-images.s-microsoft.com/image/correct') 'Affiche officielle retenue; captures et sources etrangeres exclues'
    $bad=$false;try { $null=Store-ImageUrls $catalog '9N8FQ28Z6QX3' } catch { $bad=$true }
    Assert $bad 'Pochette d un autre produit Microsoft refusee'
    Assert (-not [OPi5Native]::PublicArtworkUrl('http://store-images.s-microsoft.com/image/a') -and -not [OPi5Native]::PublicArtworkUrl('https://example.com/image/a')) 'Sources publiques limitees aux services HTTPS prevus'
    Assert ([OPi5Native]::PublicArtworkUrl('https://store.steampowered.com/api/storesearch/?term=pga%20tour&l=english&cc=ca') -and
        -not [OPi5Native]::PublicArtworkUrl('https://store.steampowered.com.example.com/api/storesearch/') -and
        -not [OPi5Native]::PublicArtworkUrl('https://store.steampowered.com/login')) 'Recherche publique limitee au point d acces Steam prevu'
    $eaSearch=@{items=@(
        @{type='app';name='PGA TOUR 2K25';id=2385530;platforms=@{windows=$true}},
        @{type='app';name='EA SPORTS™ PGA TOUR™';id=1677350;platforms=@{windows=$true}},
        @{type='app';name='EA SPORTS™ PGA TOUR™ Deluxe Upgrade';id=2337580;platforms=@{windows=$true}}
    )}
    Assert ((EA-SteamArtworkId $eaSearch 'PGA Tour') -eq '1677350') 'Image de PGA Tour : correspondance exacte au milieu des jeux 2K et DLC'
    $eaSearch.items+=@(@{type='app';name='EA SPORTS PGA TOUR';id=999999;platforms=@{windows=$true}})
    Assert ((EA-SteamArtworkId $eaSearch 'PGA Tour') -eq '') 'Images EA ambigues non choisies automatiquement'
    Assert ((EA-ArtworkTitleKey 'EA SPORTS FC™ 27') -eq 'fc 27' -and
        (EA-ArtworkTitleKey 'Madden NFL 27') -ne (EA-ArtworkTitleKey 'Madden NFL 26') -and
        (EA-ArtworkTitleKey 'FC 27') -ne (EA-ArtworkTitleKey 'FC 27 Lite')) 'Annees et editions conservees dans les comparaisons d images EA'
    $eaCatalog=@{'1677350'=@{success=$true;data=@{type='game';steam_appid=1677350;name='EA SPORTS™ PGA TOUR™';publishers=@('Electronic Arts');platforms=@{windows=$true};header_image='https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1677350/header.jpg'}}}
    Assert ((EA-SteamHeaderUrl $eaCatalog '1677350' 'PGA Tour') -like '*/1677350/header.jpg') 'Image EA confirmee par titre, identifiant, editeur et plateforme PC'
    $rejected=0
    foreach ($variation in @('publisher','title','dlc','id','platform','image')) {
        $badCatalog=Clone-Object $eaCatalog
        switch ($variation) {
            'publisher' { $badCatalog.'1677350'.data.publishers=@('Autre editeur') }
            'title' { $badCatalog.'1677350'.data.name='PGA TOUR 2K25' }
            'dlc' { $badCatalog.'1677350'.data.type='dlc' }
            'id' { $badCatalog.'1677350'.data.steam_appid=999999 }
            'platform' { $badCatalog.'1677350'.data.platforms.windows=$false }
            'image' { $badCatalog.'1677350'.data.header_image='https://shared.akamai.steamstatic.com/steam/apps/999999/header.jpg' }
        }
        try { $null=EA-SteamHeaderUrl $badCatalog '1677350' 'PGA Tour' } catch { $rejected++ }
    }
    Assert ($rejected -eq 6) 'Mauvais editeur, titre, DLC, identifiant, plateforme ou chemin d image rejetes'
    $assetFixture=@{response=@{store_items=@(@{appid=4080220;id=4080220;success=1;item_type=0;name='EA SPORTS FC™ 27';assets=@{
        asset_url_format='steam/apps/4080220/${FILENAME}?t=1790973254';
        library_capsule='81210d536b70c14e4cf9725f3f03d82bf64e5e25/library_capsule.jpg';
        library_capsule_2x='81210d536b70c14e4cf9725f3f03d82bf64e5e25/library_capsule_2x.jpg'
    }})}}
    $assetUrls=@(Steam-LibraryUrls $assetFixture '4080220' 'FC 27')
    Assert ($assetUrls.Count -eq 2 -and $assetUrls[0] -eq 'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/4080220/81210d536b70c14e4cf9725f3f03d82bf64e5e25/library_capsule_2x.jpg?t=1790973254') 'Affiches Steam avec chemin empreinte : priorite a la grande image du bon jeu'
    $bad=$false;try { $null=Steam-LibraryUrls $assetFixture '3940610' 'Madden NFL 27' } catch { $bad=$true }
    Assert $bad 'Affiche d un autre AppId refusee'
    $badAssets=Clone-Object $assetFixture
    $badAssets.response.store_items[0].assets.asset_url_format='https://example.com/${FILENAME}'
    $bad=$false;try { $null=Steam-LibraryUrls $badAssets '4080220' 'FC 27' } catch { $bad=$true }
    Assert $bad 'Format distant ne peut pas rediriger la source de l affiche'
    $badAssets=Clone-Object $assetFixture
    $badAssets.response.store_items[0].assets.library_capsule='../3940610/library_capsule.jpg'
    $badAssets.response.store_items[0].assets.library_capsule_2x='https://example.com/other.jpg'
    Assert (@(Steam-LibraryUrls $badAssets '4080220' 'FC 27').Count -eq 0) 'Noms d images hors du jeu refuses'
    Assert ([OPi5Native]::PublicArtworkUrl('https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json=test') -and
        -not [OPi5Native]::PublicArtworkUrl('https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/')) 'Seul le catalogue public des images est autorise sur le nouveau domaine Steam'
    $script:SelfTestCheckpoint='Chargement de System.Drawing pour les images'
    Init-Artwork
    Assert ($null -ne ('System.Drawing.Bitmap' -as [type]) -and $null -ne ('System.Drawing.Imaging.ImageFormat' -as [type])) 'Types System.Drawing charges dans PowerShell avant la creation d une image'
    $script:SelfTestCheckpoint='Creation et conversion de la pochette de test'
    $bitmap=New-Object System.Drawing.Bitmap 48,48
    $memory=New-Object IO.MemoryStream
    try { $bitmap.Save($memory,[System.Drawing.Imaging.ImageFormat]::Png);[byte[]]$png=[OPi5Artwork]::Png($memory.ToArray()) }
    finally { $bitmap.Dispose();$memory.Dispose() }
    $memory=New-Object IO.MemoryStream (,$png)
    $image=[System.Drawing.Image]::FromStream($memory)
    try { Assert ($image.Width -eq 600 -and $image.Height -eq 900) 'Pochette encodee en vrai PNG, proportions conservees dans un cadre 600 x 900' }
    finally { $image.Dispose();$memory.Dispose() }
    $bad=$false;try { $null=[OPi5Artwork]::Png([Text.Encoding]::UTF8.GetBytes('<html>pas une image mais une erreur HTTP</html>')) } catch { $bad=$true }
    Assert $bad 'Reponse HTML non acceptee comme une image'
    $iconMemory=New-Object IO.MemoryStream
    try {
        [System.Drawing.SystemIcons]::Application.Save($iconMemory)
        [byte[]]$iconPng=[OPi5Artwork]::IcoBytes($iconMemory.ToArray())
        [byte[]]$normalizedIcon=[OPi5Artwork]::Png($iconPng)
        Assert ($normalizedIcon.Length -gt 24 -and $normalizedIcon[0] -eq 137 -and $normalizedIcon[1] -eq 80) 'Fichier ICO decode en vrai PNG compatible avec VibeShine'
    } finally { $iconMemory.Dispose() }
    $bad=$false;try { $null=[OPi5Artwork]::IcoBytes([Text.Encoding]::UTF8.GetBytes('<html>icone absente dans un fichier invalide</html>')) } catch { $bad=$true }
    Assert $bad 'Faux fichier ICO refuse'
    Invoke-AtomicWriteSelfTests
    Invoke-RepairSelfTests
    Invoke-ResetSelfTests
    Invoke-BrandSelfTests
    Invoke-ProfileSelfTests
    Invoke-RecoverySelfTests
    Invoke-GuiSelfTests
    return $script:SelfTestCount
}

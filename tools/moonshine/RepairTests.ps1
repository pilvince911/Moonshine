#Requires -Version 5.1
function Invoke-AtomicWriteSelfTests {
    $temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('opi5-atomic-selftest-'+[guid]::NewGuid().ToString('N'))
    $savedMode=$script:AtomicTestMode;$savedCalls=$script:AtomicTestCalls
    function Invoke-AtomicFileOperation([string]$Source,[string]$Destination,[bool]$Replace,[string]$Backup) {
        $script:AtomicTestCalls++
        if ($script:AtomicTestMode -eq '1175' -and $script:AtomicTestCalls -le 2) {
            throw [IO.IOException]::new('Refus 1175 synthetique.',[int](-2147023721))
        }
        if ($script:AtomicTestMode -eq 'denied') { throw [UnauthorizedAccessException]::new('Refus de permission synthetique.') }
        if ($script:AtomicTestMode -eq 'partial') {
            if ($Replace) { [IO.File]::Move($Destination,$Backup) }
            throw [IO.IOException]::new('Etat partiel 1177 synthetique.',[int](-2147023719))
        }
        if ($Replace) { [IO.File]::Replace($Source,$Destination,$Backup) }
        else { [IO.File]::Move($Source,$Destination) }
    }
    try {
        [IO.Directory]::CreateDirectory($temporary) | Out-Null
        $path=Join-Path $temporary 'état [pilote].json'
        $first=@{phase=1;title='Jeu initial';empty=@()};$next=@{phase=2;title='Jeu actualisé';empty=@()}
        $script:AtomicTestMode='normal';$script:AtomicTestCalls=0
        Write-Json $path $first
        $script:SelfTestCheckpoint='Reprise exacte de l erreur Windows 1175 du retour 0.4.0'
        $script:AtomicTestMode='1175';$script:AtomicTestCalls=0
        $events=$script:AtomicWriteEvents.Count
        Write-Json $path $next
        Assert ($script:AtomicTestCalls -ge 3 -and (Same (Read-Json $path) $next)) 'Erreur 1175 temporaire : deux echecs injectes puis remplacement complet reussi'
        Assert ($script:AtomicWriteEvents.Count -gt $events -and $script:AtomicWriteEvents[$events].win32 -eq 1175) 'Reprise de remplacement inscrite au diagnostic avec son code Windows'
        Assert (@([IO.Directory]::GetFiles($temporary,'*.tmp')).Count -eq 0) 'Reprise reussie sans laisser de candidat temporaire'

        $script:SelfTestCheckpoint='Refus permanent sans effacement du JSON existant'
        $script:AtomicTestMode='denied';$script:AtomicTestCalls=0
        $failure=$null
        try { Write-Json $path $first } catch { $failure=Atomic-FailureSummary $_ }
        Assert ($null -ne $failure -and $failure.file -eq 'état [pilote].json' -and $failure.win32 -eq 5 -and $failure.attempts -eq 1) 'Permission refusee : arret immediat et diagnostic precis du fichier'
        Assert ($script:AtomicTestCalls -eq 1 -and (Same (Read-Json $path) $next)) 'Aucun contournement par suppression ou ecrasement direct du fichier valide'

        $script:SelfTestCheckpoint='Conservation du candidat si Windows signale un etat partiel'
        $script:AtomicTestMode='partial';$script:AtomicTestCalls=0
        $failure=$null
        try { Write-Json $path $first } catch { $failure=Atomic-FailureSummary $_ }
        Assert ($failure.win32 -eq 1177 -and $failure.candidate_retained -eq $true -and $failure.previous_retained -eq $true -and $script:AtomicTestCalls -eq 1) 'Erreur de renommage partiel non retentee : ancien et nouveau fichiers conserves'
        Assert ((Same (Read-Json (Join-Path $temporary $failure.candidate)) $first) -and
            (Same (Read-Json (Join-Path $temporary $failure.previous)) $next)) 'Deux contenus intacts apres un renommage partiel reel dans le dossier synthetique'
        [IO.File]::Move((Join-Path $temporary $failure.previous),$path)
        Remove-Item -LiteralPath (Join-Path $temporary $failure.candidate)

        $script:SelfTestCheckpoint='Verrou Windows temporaire relache par un vrai thread .NET'
        $script:AtomicTestMode='normal';$script:AtomicTestCalls=0
        $lease=New-Object OPi5FileLease($path,1000)
        try {
            Write-Json $path $first
            Assert ($lease.Released -and (Same (Read-Json $path) $first)) 'Verrou reel relache pendant les reprises : ecriture atomique terminee'
        } finally { $lease.Dispose() }

        $script:SelfTestCheckpoint='Sauvegardes primaire et miroir repetees'
        $savedData=$script:Data
        try {
            $script:Data=Join-Path $temporary 'state'
            $state=Empty-State
            Save-State $state
            $stateKey='steam:990080';$stateId=Stable-Id $stateKey
            for ($i=0;$i -lt 12;$i++) {
                $state.managed[$stateId]=@{key=$stateKey;fields=@{uuid=$stateId;name=('Etape '+$i)}}
                Save-State $state
                Assert ((Same (Read-Json (Join-Path $script:Data 'state.json')) $state) -and
                    (Same (Read-Json (Join-Path $script:Data 'state.last-good.json')) $state)) ('Etat primaire et miroir actualises, passage '+($i+1))
            }
        } finally { $script:Data=$savedData }
    } finally {
        $script:AtomicTestMode=$savedMode;$script:AtomicTestCalls=$savedCalls
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}
function Invoke-RepairSelfTests {
    $savedData=$script:Data;$savedRuntime=$script:Runtime
    $savedRepairs=$script:Repairs;$savedStateRepair=$script:StateNeedsRepair
    $temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('opi5-repair-selftest-'+[guid]::NewGuid().ToString('N'))
    $script:Repairs=New-Object 'Collections.Generic.List[object]'
    function Get-Apps {
        # Model the real API envelope, sorted properties, generated ids and
        # image timestamps. No network and no real VibeShine connection.
        $apps=@();$index=0
        foreach ($a in @($script:TestApiApps)) {
            $copy=[ordered]@{}
            foreach ($k in @(Keys $a | Sort-Object)) { $copy[$k]=Field $a $k }
            $copy['index']=$index;$copy['id']=[string](1000+$index);$copy['image-version']=1234567890123L
            $apps+=@($copy);$index++
        }
        return Clone-Object @{apps=$apps}
    }
    function Session-Idle { }
    function Api-Call([string]$Method,[string]$Path,$Body=$null,[string]$Authorization='') {
        if ($Method -ne 'POST' -or $Path -ne '/api/apps') { throw 'Appel inattendu dans le simulateur de catalogue.' }
        $script:TestApiPosts++
        $script:TestApiApps=@($script:TestApiApps | Where-Object { $_.uuid -ne $Body.uuid })+@((Clone-Object $Body))
        if ($script:TestLoseReply) { $script:TestLoseReply=$false;throw 'Reponse POST perdue apres enregistrement synthetique.' }
        return @{status=$true}
    }
    try {
        $script:Data=$temporary;$script:Runtime=Join-Path $temporary 'versions\1.0.0'
        [IO.Directory]::CreateDirectory($script:Runtime) | Out-Null
        $script:SelfTestCheckpoint='Neuf jeux : vrai parcours de plan ecriture relecture et reprise'
        $games=@()
        foreach ($id in @('990080','1926590','4374500')) {
            $key='steam:'+$id
            $games+=@(@{key=$key;uuid=(Stable-Id $key);kind='steam';title='Steam '+$id;steam_id=$id;install=('C:\Games\'+$id);cover='';monitor_names=@()})
        }
        foreach ($id in @('16425629','16425884','16425895')) {
            $key='ea:'+$id
            $games+=@(@{key=$key;uuid=(Stable-Id $key);kind='ea';title='EA '+$id;ea_content_id=$id;ea_content_ids=@($id);install=('C:\Games\EA'+$id);cover='';monitor_names=@()})
        }
        foreach ($id in @('Synthetic.Forza_pkg!Game','Synthetic.Cities_pkg!Game','Synthetic.Indy_pkg!Game')) {
            $key='xbox:'+$id
            $games+=@(@{key=$key;uuid=(Stable-Id $key);kind='xbox';title=$id;aumid=$id;install='C:\XboxGames\'+$id.Replace('!','_');cover='';monitor_names=@('SyntheticGame')})
        }
        $script:TestApiApps=@();$script:TestApiPosts=0;$script:TestLoseReply=$false
        $state=Empty-State
        $plan=@(Build-Plan $games @() $state $script:Runtime $script:Data)
        $null=Apply-Plan $plan $games $state (Get-Apps) 6>$null
        Assert ($script:TestApiPosts -eq 9 -and @($script:TestApiApps).Count -eq 9) 'Neuf ajouts verifies dans le simulateur du vrai parcours Apply-Plan'
        $loaded=Load-State
        $again=@(Build-Plan $games (Get-Apps).apps $loaded $script:Runtime $script:Data)
        Assert (@($again | Where-Object { $_.action -ne 'unchanged' }).Count -eq 0) 'Relecture API et redemarrage simules : neuf unchanged'
        $backupCount=@(Get-ChildItem -LiteralPath (Join-Path $temporary 'Backups') -Directory).Count
        $null=Apply-Plan $again $games $loaded (Get-Apps) 6>$null
        Assert ($script:TestApiPosts -eq 9 -and @(Get-ChildItem -LiteralPath (Join-Path $temporary 'Backups') -Directory).Count -eq $backupCount) 'Deuxieme passage : zero POST et zero sauvegarde transactionnelle superflue'
        $game=$games[0];$id=$game.uuid
        $sameApp=@((Get-Apps).apps | Where-Object { $_.uuid -eq $id })[0]
        $formatted=To-Map $sameApp
        foreach ($k in @('cmd','working-dir','steam-install-dir')) { $formatted[$k]=([string]$formatted[$k]).ToUpperInvariant() }
        $formatted['auto-detach']='true';$formatted['wait-all']='false';$formatted['elevated']='false';$formatted['exit-timeout']='5'
        $formattedPlan=@(Build-Plan @($game) @($formatted) $loaded $script:Runtime $script:Data)[0]
        Assert ($formattedPlan.action -eq 'unchanged' -and $formattedPlan.changed_fields.Count -eq 0) 'Casse Windows et types API equivalents ne declenchent pas de reecriture'
        Assert (Same-App $sameApp $formatted) 'Verification API compatible avec les representations equivalentes connues'
        Assert (-not (App-FieldSame 'name' 'Titre personnel' 'TITRE PERSONNEL')) 'Titre personnalise compare exactement'
        Assert (-not (App-FieldSame 'cmd' 'autre.exe "Argument"' 'autre.exe "argument"')) 'Commandes personnalisees non normalisees arbitrairement'
        Assert (-not (App-FieldSame 'auto-detach' 'false' $true)) 'Faux textuel ne devient pas vrai par conversion PowerShell'
        $moved=To-Map $game;$moved.install='D:\Nouveau chemin'
        $movePlan=@(Build-Plan @($moved) @($sameApp) $loaded $script:Runtime $script:Data)[0]
        Assert ($movePlan.action -eq 'update' -and $movePlan.changed_fields.Count -eq 1 -and $movePlan.changed_fields[0] -eq 'steam-install-dir' -and $movePlan.reason -like '*steam-install-dir*') 'Vrai changement explique precisement dans le plan'
        $newRuntime=Join-Path $temporary 'versions\0.6.1'
        $upgrade=@(Build-Plan @($game) @($sameApp) $loaded $newRuntime $script:Data)[0]
        Assert ($upgrade.action -eq 'update' -and 'cmd' -in $upgrade.changed_fields -and 'working-dir' -in $upgrade.changed_fields) 'Une vraie mise a niveau du lanceur reste une mise a jour'
        $taskAction=@{Execute=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=(Automation-Arguments $script:Data '1.0.0');WorkingDirectory=''}
        Assert (Test-ManagedAutomationAction $taskAction $script:Data) 'Nouvelle tache OPi5 reconnue par son chemin et ses arguments'
        $oldTask=To-Map $taskAction
        $oldTask.Arguments=$oldTask.Arguments.Replace('Packages\1.0.0\Bootstrap.ps1','versions\0.3.1\VibeShine-Xbox.ps1')
        Assert (Test-ManagedAutomationAction $oldTask $script:Data) 'Ancienne tache OPi5 reconnue pour migration de version'
        $withDirectory=To-Map $taskAction;$withDirectory.WorkingDirectory=$script:Runtime
        Assert (Test-ManagedAutomationAction $withDirectory $script:Data) 'Tache creee par le menu avec son repertoire de version reconnue pour migration'
        $withDirectory.WorkingDirectory='C:\Autre repertoire personnel'
        Assert (-not (Test-ManagedAutomationAction $withDirectory $script:Data)) 'Repertoire de travail personnalise de tache conserve sans migration forcee'
        $customTask=To-Map $taskAction;$customTask.Arguments+=' -AutreOption'
        Assert (-not (Test-ManagedAutomationAction $customTask $script:Data)) 'Action planifiee personnalisee conservee sans migration automatique'
        Assert ((Redact 'Tache OPi5-S-1-5-21-111-222-333-1001') -notmatch 'S-1-5-21') 'Identifiant Windows masque dans les erreurs de tache partagees'

        $script:SelfTestCheckpoint='Reparation des fiches de lancement et de l etat'
        $descriptorPath=Join-Path (Join-Path $temporary 'Games') ($id+'.json')
        $beforeDescriptor=Read-Json $descriptorPath
        [IO.File]::WriteAllText($descriptorPath,'{corrompu')
        $posts=$script:TestApiPosts
        $null=Apply-Plan $again $games $loaded (Get-Apps) 6>$null
        Assert ((Same (Read-Json $descriptorPath) $beforeDescriptor) -and $script:TestApiPosts -eq $posts) 'Fiche corrompue reconstruite sans reecrire VibeShine'
        Remove-Item -LiteralPath $descriptorPath
        Save-Runtime $game
        Assert ((Read-Json $descriptorPath).uuid -eq $id) 'Fiche absente reconstruite automatiquement'
        $statePath=Join-Path $temporary 'state.json';$mirrorPath=Join-Path $temporary 'state.last-good.json'
        [IO.File]::WriteAllText($statePath,'{tronque')
        $restored=Load-State
        Assert ($restored.managed.Count -eq 9 -and $restored.pending.Count -eq 0 -and (Test-StateShape (Read-Json $statePath))) 'Etat tronque restaure depuis sa copie valide'
        [IO.File]::WriteAllText($statePath,'{}')
        Assert ((Load-State).managed.Count -eq 9) 'Etat vide et incomplet restaure sans etre confondu avec une version future'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $temporary 'Recovery') -File).Count -ge 2) 'Originaux endommages conserves avant reparation'
        $badState=Empty-State;$badState.managed[$id]=@{key=$game.key;fields='invalide'}
        Assert (-not (Test-StateShape $badState)) 'Etat JSON syntaxiquement valide mais mal structure refuse'
        Write-Json $statePath @{schema='opi5-xbox-state/99';managed=@{};pending=@{}}
        $bad=$false;try { $null=Load-State } catch { $bad=$true }
        Assert ($bad -and (Read-Json $statePath).schema -eq 'opi5-xbox-state/99') 'Version inconnue conservee sans reinitialisation silencieuse'
        Save-State $restored
        [IO.File]::WriteAllText($statePath,'{perdu');[IO.File]::WriteAllText($mirrorPath,'{perdu')
        $rebuilt=Load-State
        $personal=To-Map $sameApp;$personal.name='Mon titre';$personal['image-path']='C:\Pochettes\personnelle.png';$personal['exit-timeout']=30
        Repair-ManagedState $rebuilt @($personal) @($game) $script:Runtime $script:Data
        $personalPlan=@(Build-Plan @($game) @($personal) $rebuilt $script:Runtime $script:Data)[0]
        Assert ($rebuilt.managed.Count -eq 1 -and $personalPlan.action -eq 'unchanged' -and $personalPlan.payload.name -eq 'Mon titre' -and $personalPlan.payload['exit-timeout'] -eq 30) 'Reconstruction depuis API : titre et reglages personnels preserves'
        $foreign=To-Map $personal;$foreign['opi5-xbox-owner']='autre'
        $foreignState=Empty-State
        Repair-ManagedState $foreignState @($foreign) @($game) $script:Runtime $script:Data
        Assert ($foreignState.managed.Count -eq 0) 'Reconstruction exclut les entrees non gerees par OPi5'
        $customCommand=To-Map $personal;$customCommand.cmd='ma-commande-personnelle.exe'
        $customState=Empty-State
        Repair-ManagedState $customState @($customCommand) @($game) $script:Runtime $script:Data
        Assert ((@(Build-Plan @($game) @($customCommand) $customState $script:Runtime $script:Data)[0]).action -eq 'conflict') 'Commande personnalisee jamais ecrasee pendant une reconstruction'

        $script:SelfTestCheckpoint='Reponse POST perdue et reprise sans doublon'
        $script:Data=Join-Path $temporary 'lost-response';$script:Runtime=Join-Path $script:Data 'versions\1.0.0'
        $script:TestApiApps=@();$script:TestApiPosts=0;$script:TestLoseReply=$true
        $lostState=Empty-State
        $lostPlan=@(Build-Plan @($game) @() $lostState $script:Runtime $script:Data)
        $null=Apply-Plan $lostPlan @($game) $lostState (Get-Apps) 6>$null
        Assert ($script:TestApiPosts -eq 1 -and $lostState.pending.Count -eq 0 -and $lostState.managed.Count -eq 1) 'POST enregistre mais reponse perdue : une seule ecriture, journal termine apres relecture'
        $pending=Empty-State;$pending.pending[$id]=@{before=$null;after=$lostPlan[0].payload;new_state=$lostState.managed[$id]}
        Save-State $pending
        [IO.File]::WriteAllText((Join-Path $script:Data 'state.json'),'{interrompu')
        $pending=Load-State
        Recover-Pending $pending (Get-Apps).apps
        Assert ($pending.pending.Count -eq 0 -and $pending.managed.Count -eq 1 -and $script:TestApiPosts -eq 1) 'Journal restaure puis repris sans renvoyer le POST deja effectue'
        $optional=Join-Path $script:Data 'last-plan.json'
        [IO.File]::WriteAllText($optional,'{incomplet')
        $script:SelfTestCheckpoint='Retour 0.4.1 : reparation du cache corrompu en JSON null'
        $optionalValue=Read-OptionalJson $optional
        Assert ($null -eq $optionalValue -and (Read-Text $optional) -ceq 'null' -and
            $null -eq (Read-Json $optional)) 'Cache de diagnostic corrompu ne bloque pas un prochain rapport'
        $savedCache=@(Get-ChildItem -LiteralPath (Join-Path $script:Data 'Recovery') -File | Where-Object { $_.Name -like '*-last-plan.json' })
        Assert ($savedCache.Count -eq 1 -and (Read-Text $savedCache[0].FullName) -ceq '{incomplet') 'Cache original conserve intact avant la reparation en null'
        $eventsBefore=$script:Repairs.Count
        $optionalValue=Read-OptionalJson $optional
        Assert ($null -eq $optionalValue -and $script:Repairs.Count -eq $eventsBefore -and
            @(Get-ChildItem -LiteralPath (Join-Path $script:Data 'Recovery') -File | Where-Object { $_.Name -like '*-last-plan.json' }).Count -eq 1) 'Relecture du cache repare sans nouvelle reparation ni copie superflue'
        $freshCache=@{rows=@();version=$script:Version}
        Write-Json $optional $freshCache
        Assert (Same (Read-OptionalJson $optional) $freshCache) 'Cache reinitialise reutilisable pour un nouveau plan valide'
        $history=@(Repair-History);$historyAgain=@(Repair-History)
        Assert ($history.Count -gt 0 -and $historyAgain.Count -eq $history.Count) 'Historique de reparation persistant sans repetition des memes evenements'

        $script:SelfTestCheckpoint='Copie verifiee du programme et reparation atomique'
        . (Join-Path $PSScriptRoot 'Bootstrap.ps1') -FunctionsOnly
        $source=Join-Path $temporary 'package-good';$destination=Join-Path $temporary 'package-damaged'
        [IO.Directory]::CreateDirectory($source) | Out-Null
        foreach ($name in @('Core.ps1','Launch-Game.ps1')) { [IO.File]::WriteAllText((Join-Path $source $name),('# synthetic '+$name)) }
        $lines=@();foreach ($name in @('Core.ps1','Launch-Game.ps1')) { $lines+=((Get-FileHash -LiteralPath (Join-Path $source $name) -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+$name) }
        [IO.File]::WriteAllLines((Join-Path $source 'SHA256.txt'),$lines)
        $expected=@('Core.ps1','Launch-Game.ps1');$hashes=Package-Hashes $source $expected
        Assert (Package-Valid $source $expected) 'Copie de reference verifiee par ses empreintes'
        $initial=@(Repair-PackageTree $source $destination $hashes (Join-Path $temporary 'package-recovery'))
        Assert ($initial.Count -eq 3 -and (Package-Valid $destination $expected)) 'Installation complete depuis une source saine'
        [IO.File]::WriteAllText((Join-Path $destination 'Core.ps1'),'# damaged')
        Remove-Item -LiteralPath (Join-Path $destination 'Launch-Game.ps1')
        $fixed=@(Repair-PackageTree $source $destination $hashes (Join-Path $temporary 'package-recovery'))
        Assert ($fixed.Count -eq 2 -and (Package-Valid $destination $expected)) 'Fichier du programme corrompu et fichier absent restaures'
        Assert (@(Repair-PackageTree $source $destination $hashes (Join-Path $temporary 'package-recovery')).Count -eq 0) 'Programme deja sain : aucune copie ni sauvegarde inutile'
        [IO.File]::WriteAllText((Join-Path $source 'SHA256.txt'),(('0'*64)+'  ..\outside.ps1'))
        Assert (-not (Package-Valid $source $expected)) 'Liste d empreintes avec chemin hors programme refusee'
    } finally {
        $script:Data=$savedData;$script:Runtime=$savedRuntime
        $script:Repairs=$savedRepairs;$script:StateNeedsRepair=$savedStateRepair
        Remove-Variable -Name @('TestApiApps','TestApiPosts','TestLoseReply') -Scope Script -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

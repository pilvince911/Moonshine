#Requires -Version 5.1
function Invoke-RecoverySelfTests {
    $savedData=$script:Data;$savedRuntime=$script:Runtime;$savedProfiles=$script:StreamProfiles;$savedUnattended=$script:Unattended
    $savedConnection=$script:Connection;$savedAuthorization=$script:Authorization;$savedRepairs=$script:Repairs
    $temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('opi5-recovery-selftest-'+[guid]::NewGuid().ToString('N'))
    try {
        $script:Unattended=$false;$script:Data=$temporary;$script:Runtime=Join-Path $temporary 'versions\0.8.0'
        $script:Repairs=New-Object 'Collections.Generic.List[object]'
        [IO.Directory]::CreateDirectory($temporary) | Out-Null
        foreach ($value in @(@(),@(1),@(1,2),$false,0,'')) {
            Assert (Same $value (Clone-Object $value)) 'Copie JSON conserve tableaux racines, booléens, zéro et chaîne vide'
        }
        Assert ($null -eq (Clone-Object $null)) 'Copie JSON conserve null'
        $endpoint=@{url='https://127.0.0.1:47990';pin=('A'*64)}
        $record=Save-Connection $endpoint 'synthetic-token-one'
        Load-Connection
        Assert ($script:Authorization -ceq 'Bearer synthetic-token-one' -and $script:Connection.schema -eq 'opi5-vibeshine-connection/2') 'Connexion et jeton chiffré rechargés depuis le même enregistrement atomique'
        Assert ((Read-Text (Join-Path $temporary 'connection.json')) -notlike '*synthetic-token-one*') 'Jeton absent en clair du fichier de connexion'
        [IO.File]::WriteAllText((Join-Path $temporary 'api-token.dpapi'),'ancien fichier inutilisable')
        Load-Connection
        Assert ($script:Authorization -ceq 'Bearer synthetic-token-one') 'Nouvelle connexion indépendante du vieux fichier de jeton séparé'
        $legacy=ConvertTo-SecureString 'synthetic-legacy-token' -AsPlainText -Force
        try { [IO.File]::WriteAllText((Join-Path $temporary 'api-token.dpapi'),(ConvertFrom-SecureString $legacy)) } finally { $legacy.Dispose() }
        Write-Json (Join-Path $temporary 'connection.json') $endpoint
        Load-Connection
        Assert ($script:Authorization -ceq 'Bearer synthetic-legacy-token') 'Connexion des anciennes versions encore compatible'
        $null=Save-Connection $endpoint 'synthetic-token-one';Load-Connection
        Invoke-ConnectionFailureSelfTests
        $cachePath=Join-Path $temporary 'last-inventory.json'
        foreach ($badCache in @(@{ready='incorrect';pending=@();created='';version='0.8.0'},@{ready=@(@{uuid='incorrect';key='steam:1';kind='steam';title='Test'});pending=@();created='';version='0.8.0'})) {
            Write-Json $cachePath $badCache
            Assert ($null -eq (Read-InventoryCache)) 'Cache JSON lisible mais incohérent écarté sans toucher au catalogue'
            Assert ($null -eq (Read-Json $cachePath)) 'Cache invalide remplacé par null après conservation de son original'
        }
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $temporary 'Recovery') -Filter '*last-inventory.json').Count -eq 2) 'Deux caches endommagés conservés pour diagnostic privé'
        $validCache=@{ready=@();pending=@();created=(Get-Date).ToString('o');version='0.8.0'}
        Write-Json $cachePath $validCache
        Assert (Same (Read-InventoryCache) $validCache) 'Cache vide valide conservé sans réparation inutile'
        Invoke-SingleJournalSelfTests
        Invoke-SessionShapeSelfTests
        Invoke-UndoRecoverySelfTests
        Invoke-ProfileCommitRecoverySelfTests
    } finally {
        $script:Data=$savedData;$script:Runtime=$savedRuntime;$script:StreamProfiles=$savedProfiles;$script:Unattended=$savedUnattended
        $script:Connection=$savedConnection;$script:Authorization=$savedAuthorization;$script:Repairs=$savedRepairs
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}
function Invoke-ConnectionFailureSelfTests {
    $initialConnection=$script:Connection;$initialAuthorization=$script:Authorization
    $before=Read-Text (Join-Path $script:Data 'connection.json')
    $writeJsonBody=${function:Write-Json}
    $script:ConnectionTestFailure='login';$script:ConnectionTestLogout=0
    function Probe-Connection([string]$Url,[string]$Pin) { return @{Status=200;Fingerprint=('B'*64)} }
    function Read-Host([string]$Prompt,[switch]$AsSecureString) {
        if ($AsSecureString) { return ConvertTo-SecureString 'synthetic-password' -AsPlainText -Force }
        if ($Prompt -like 'Port HTTPS*') { return '48000' }
        return 'synthetic-user'
    }
    function Api-Call([string]$Method,[string]$Path,$Body=$null,[string]$Authorization='') {
        switch ($Path) {
            '/api/auth/login' { if ($script:ConnectionTestFailure -eq 'login') { throw 'Échec de connexion synthétique.' };return @{token='synthetic-session'} }
            '/api/apps' { return [pscustomobject]@{apps=@()} }
            '/api/token' { return @{token='synthetic-token-two'} }
            '/api/auth/logout' { $script:ConnectionTestLogout++;return @{status=$true} }
            default { throw 'Appel inattendu dans le test de connexion.' }
        }
    }
    function Write-Json([string]$Path,$Object) {
        if ($script:ConnectionTestFailure -eq 'disk' -and [IO.Path]::GetFileName($Path) -eq 'connection.json') { throw 'Échec disque synthétique avant commit.' }
        & $writeJsonBody $Path $Object
    }
    try {
        foreach ($mode in @('login','disk')) {
            $script:ConnectionTestFailure=$mode;$bad=$false
            try { $null=Connect-Vibe 6>$null } catch { $bad=$true }
            Assert ($bad -and (Same $script:Connection $initialConnection) -and $script:Authorization -ceq $initialAuthorization) 'Reconnexion échouée conserve la connexion et le jeton précédents en mémoire'
            Assert ((Read-Text (Join-Path $script:Data 'connection.json')) -ceq $before) 'Reconnexion échouée conserve le fichier de connexion précédent'
        }
        Assert ($script:ConnectionTestLogout -eq 1) 'Session provisoire fermée même si la sauvegarde de connexion échoue'
        $script:ConnectionTestFailure='';$null=Connect-Vibe 6>$null
        Assert ($script:Connection.url -eq 'https://127.0.0.1:48000' -and $script:Authorization -ceq 'Bearer synthetic-token-two') 'Reconnexion réussie adopte ensemble le nouvel endpoint et son jeton'
        Load-Connection
        Assert ($script:Connection.pin -ceq ('B'*64) -and $script:Authorization -ceq 'Bearer synthetic-token-two') 'Nouveau certificat et jeton liés après rechargement'
    } finally { Remove-Variable -Name @('ConnectionTestFailure','ConnectionTestLogout') -Scope Script -ErrorAction SilentlyContinue }
}
function Invoke-SessionShapeSelfTests {
    function Api-Call([string]$Method,[string]$Path,$Body=$null) { return $script:SessionTestReply }
    try {
        $script:SessionTestReply=@{activeSessions=0;appRunning=$false}
        Assert (Session-IsIdle) 'Session explicitement inactive reconnue'
        $script:SessionTestReply=@{activeSessions='0';appRunning='false'}
        Assert (Session-IsIdle) 'Représentation textuelle connue de session interprétée sans booléen trompeur'
        foreach ($reply in @(@{activeSessions=1;appRunning=$false},@{activeSessions=0;appRunning=$true})) {
            $script:SessionTestReply=$reply;Assert (-not (Session-IsIdle)) 'Session ou application active bloque les écritures'
        }
        foreach ($reply in @(@{activeSessions=-1;appRunning=$false},@{activeSessions='0.2';appRunning=$false},@{activeSessions=0;appRunning='unknown'},@{activeSessions=0;appRunning=0})) {
            $script:SessionTestReply=$reply;$bad=$false;try { $null=Session-IsIdle } catch { $bad=$true }
            Assert $bad 'État de session ambigu refusé sans conclure à tort que le flux est arrêté'
        }
    } finally { Remove-Variable -Name SessionTestReply -Scope Script -ErrorAction SilentlyContinue }
}
function Invoke-UndoRecoverySelfTests {
    $savedBridge=$script:GuiBridge;$savedProfiles=$script:StreamProfiles
    $localBridge=$null;$script:UndoTestApps=@();$script:UndoTestDeletes=0;$script:UndoTestPosts=0;$script:UndoTestCancel=$false
    function Session-Idle { }
    function Read-Host([string]$Prompt) { return 'ANNULER' }
    function Get-Apps { return Clone-Object @{apps=@($script:UndoTestApps)} }
    function Api-Call([string]$Method,[string]$Path,$Body=$null) {
        if ($Method -eq 'POST' -and $Path -eq '/api/apps') {
            $script:UndoTestPosts++;$script:UndoTestApps=@($script:UndoTestApps | Where-Object { $_.uuid -ne $Body.uuid })+@((Clone-Object $Body));return @{status=$true}
        }
        if ($Method -eq 'DELETE' -and $Path -like '/api/apps/*') {
            $idValue=$Path.Split('/')[-1];$script:UndoTestDeletes++
            $script:UndoTestApps=@($script:UndoTestApps | Where-Object { $_.uuid -ne $idValue })
            if ($script:UndoTestCancel) { $localBridge.Cancel();$script:UndoTestCancel=$false }
            throw 'Réponse DELETE perdue après retrait synthétique.'
        }
        throw 'Appel inattendu dans le test de retour arrière.'
    }
    try {
        $script:StreamProfiles=@{schema='opi5-stream-profiles/1';games=@{}}
        $games=@(foreach ($n in @('100001','100002','100003')) { $key='steam:'+$n;@{key=$key;uuid=(Stable-Id $key);kind='steam';title=('Test '+$n);steam_id=$n;install='C:\Synthetic';cover=''} })
        $state=Empty-State;$plan=@(Build-Plan $games @() $state $script:Runtime $script:Data)
        $null=Apply-Plan $plan $games $state (Get-Apps) 6>$null
        $candidate=Get-LatestUndoCandidate
        Assert ($candidate -and @($candidate.journal.operations).Count -eq 3) 'Dernière sauvegarde vérifiée disponible pour le retour arrière'
        $changed=To-Map $script:UndoTestApps[0];$changed['name']='Titre personnalisé après synchronisation'
        $original=$script:UndoTestApps[0];$script:UndoTestApps[0]=$changed
        $bad=$false;try { $null=Undo-LastSync 6>$null } catch { $bad=$true }
        Assert ($bad -and $script:UndoTestDeletes -eq 0) 'Précontrôle de tout le retour arrière protège une personnalisation avant le premier retrait'
        $script:UndoTestApps[0]=$original
        Init-DesktopTypes;$localBridge=New-Object OPi5GuiBridge
        $script:UndoTestCancel=$true;$failure=$null
        try { $script:GuiBridge=$localBridge;$null=Undo-LastSync 6>$null } catch { $failure=$_ }
        finally { $script:GuiBridge=$savedBridge }
        $cause=$(if ($failure) {$failure.Exception} else {$null});while ($cause -and $cause.InnerException) { $cause=$cause.InnerException }
        if ($failure -and $cause -isnot [OperationCanceledException]) { throw $failure }
        Assert ($cause -is [OperationCanceledException] -and $script:UndoTestDeletes -eq 1) 'Annulation pendant DELETE vérifie le retrait courant avant de suspendre les suivants'
        Assert ((Get-UndoSummary).status -eq 'undoing' -and (Get-UndoSummary).restored -eq 1) 'Journal durable indique exactement la reprise du retour arrière'
        Assert (-not (Test-UndoAllowsSync $true)) 'Passage automatique retenu pendant une annulation interrompue'
        $bad=$false;try { $null=Test-UndoAllowsSync $false } catch { $bad=$true }
        Assert $bad 'Synchronisation manuelle bloquée jusqu à la reprise du retour arrière'
        $localBridge.FinishCommand()
        $null=Undo-LastSync 6>$null
        Assert ($script:UndoTestDeletes -eq 3 -and $script:UndoTestApps.Count -eq 0) 'Reprise ne répète aucun DELETE déjà confirmé malgré les réponses perdues'
        Assert ((Load-State).managed.Count -eq 0 -and (Get-UndoSummary).status -eq 'undone') 'Registre et contrôle de reprise terminés après vérification finale'
        Assert ((Test-UndoAllowsSync $false) -and $null -eq (Get-LatestUndoCandidate)) 'Synchronisation libérée et sauvegarde déjà annulée exclue du prochain retour arrière'
        $bad=$false;try { $null=Undo-Folder '..\autre' } catch { $bad=$true }
        Assert $bad 'Chemin du journal de reprise limité au dossier de sauvegarde attendu'
        $older='19990101-000000-abcdef';$broken='20000101-000000-abcdef'
        try {
            Write-Json (Join-Path (Undo-Folder $older) 'transaction.json') $candidate.journal
            [IO.Directory]::CreateDirectory((Undo-Folder $broken)) | Out-Null
            [IO.File]::WriteAllText((Join-Path (Undo-Folder $broken) 'transaction.json'),'{tronqué')
            $bad=$false;try { $null=Get-LatestUndoCandidate } catch { $bad=$true }
            Assert ($bad -and $script:UndoTestDeletes -eq 3) 'Sauvegarde récente illisible bloque l annulation sans sélectionner une plus ancienne'
        } finally { foreach ($idValue in @($older,$broken)) { if (Test-Path -LiteralPath (Undo-Folder $idValue)) { Remove-Item -LiteralPath (Undo-Folder $idValue) -Recurse -Force } } }
        $completedControl=Read-Json (Join-Path $script:Data 'undo-control.json')
        Write-Json (Join-Path $script:Data 'undo-control.json') @{schema='inconnu';status='undoing'}
        $bad=$false;try { $null=Test-UndoAllowsSync $true } catch { $bad=$true }
        Assert ($bad -and (Get-UndoSummary).status -eq 'invalid') 'Contrôle de reprise invalide reste bloquant et visible au diagnostic'
        Write-Json (Join-Path $script:Data 'undo-control.json') $completedControl

    } finally {
        $script:GuiBridge=$savedBridge;$script:StreamProfiles=$savedProfiles
        if ($localBridge) { $localBridge.Dispose() }
        Remove-Variable -Name @('UndoTestApps','UndoTestDeletes','UndoTestPosts','UndoTestCancel') -Scope Script -ErrorAction SilentlyContinue
    }
}

function Invoke-ProfileCommitRecoverySelfTests {
    $savedData=$script:Data;$savedProfiles=$script:StreamProfiles
    $temporary=Join-Path $script:Data 'profile-commit-test'
    $writeJsonBody=${function:Write-Json};$script:ProfileTestFault=$false
    function Write-Json([string]$Path,$Object) {
        if ($script:ProfileTestFault -and [IO.Path]::GetFileName($Path) -eq 'stream-profiles.json') { throw 'Panne synthétique au milieu du changement de profil.' }
        & $writeJsonBody $Path $Object
    }
    try {
        $script:Data=$temporary
        $key='steam:100099';$game=@{key=$key;uuid=(Stable-Id $key);kind='steam';title='Profil synthétique';steam_id='100099';install='C:\Synthetic';cover=''}
        $app=Desired-Fields $game $script:Runtime $script:Data
        $app['frame-generation-mode']='off';$app['frame-generation-provider']='lossless-scaling'
        $state=Empty-State;$state.managed[$game.uuid]=@{key=$key;fields=(Clone-Object $app)};Save-State $state
        $script:ProfileTestFault=$true;$bad=$false
        try { Save-GameStreamProfile $app 'game-provided' } catch { $bad=$true }
        Assert ($bad -and $null -ne (Read-Json (Join-Path $temporary 'stream-profile-change.json'))) 'Choix du profil interrompu conserve un journal local complet'
        $script:ProfileTestFault=$false
        $script:StreamProfiles=Load-StreamProfiles
        Assert ((Field $script:StreamProfiles.games $game.uuid).mode -eq 'game-provided') 'Profil explicitement choisi récupéré après interruption'
        Assert ($null -eq (Read-Json (Join-Path $temporary 'stream-profile-change.json'))) 'Journal local vidé seulement après commit des deux fichiers'
        $plan=@(Build-Plan @($game) @($app) (Load-State) $script:Runtime $script:Data)[0]
        Assert ($plan.action -eq 'update' -and $plan.payload['frame-generation-mode'] -eq 'game-provided') 'Profil repris reste une proposition à synchroniser; aucune écriture API implicite'
        Save-GameStreamProfile $app 'unmanaged'
        Assert ($null -eq (Field (Load-StreamProfiles).games $game.uuid)) 'Arrêt de gestion du profil conserve les réglages dans le catalogue'
        $before=Load-State;$after=Clone-Object $before
        $root=Load-StreamProfiles
        Write-Json (Join-Path $temporary 'stream-profile-change.json') @{schema='opi5-stream-profile-change/1';state_before=$before;state_after=$after;profiles_before=$root;profiles_after=$root}
        $changed=Load-State;$record=To-Map (Field $changed.managed $game.uuid);$record['personal_change']='nouveau';$changed.managed[$game.uuid]=$record;Save-State $changed
        $bad=$false;try { $null=Load-StreamProfiles } catch { $bad=$true }
        Assert ($bad -and (Field (Load-State).managed $game.uuid).personal_change -eq 'nouveau') 'Reprise locale refuse d écraser un registre modifié après la panne'
    } finally {
        $script:Data=$savedData;$script:StreamProfiles=$savedProfiles
        Remove-Variable -Name ProfileTestFault -Scope Script -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

function Invoke-SingleJournalSelfTests {
    $key='steam:100088';$game=@{key=$key;uuid=(Stable-Id $key);kind='steam';title='Journal synthétique';steam_id='100088';install='C:\Synthetic';cover=''}
    $app=Desired-Fields $game $script:Runtime $script:Data
    $idValue='20000101-000000-abcdef';$folder=Undo-Folder $idValue
    $resetControl=@{backup_id='reset-20000101-000000-abcdef12'}
    $resetFolder=Split-Path -Parent (Reset-JournalPath $resetControl)
    try {
        $op=@{uuid=$game.uuid;key=$key;before=$null;after=$app;old_state=$null;new_state=@{key=$key;fields=$app};verified=$true}
        $journal=@{schema='opi5-xbox-transaction/1';complete=$true;operations=@($op)}
        Write-Json (Join-Path $folder 'transaction.json') $journal
        Assert (@((Read-UndoJournal $idValue).operations).Count -eq 1) 'Journal d une seule écriture garde son tableau PowerShell 5.1'
        $journal.schema=$script:LegacyTransactionSchema
        Write-Json (Join-Path $folder 'transaction.json') $journal
        Assert (@((Read-UndoJournal $idValue).operations).Count -eq 1) 'Ancien journal d une seule écriture accepté sans changement d identité'
        Write-Json (Reset-JournalPath $resetControl) @{schema='opi5-xbox-reset/1';backup_id=$resetControl.backup_id;status='resetting';operations=@(@{uuid=$game.uuid;key=$key;before=$app;deleted=$false;restored=$false})}
        Assert (@((Read-ResetJournal $resetControl).operations).Count -eq 1) 'Remise à zéro d un seul jeu garde aussi son tableau JSON'
    } finally {
        foreach ($path in @($folder,$resetFolder)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

#Requires -Version 5.1
function Invoke-ProfileSelfTests {
    $savedData=$script:Data;$savedProfiles=$script:StreamProfiles
    $savedCreation=Get-Variable -Name CreationStreamMode -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $script:CreationStreamMode='unmanaged'
    $temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('opi5-profile-selftest-'+[guid]::NewGuid().ToString('N'))
    try {
        $script:Data=$temporary
        $script:StreamProfiles=Load-StreamProfiles
        $key='steam:990080';$game=@{key=$key;uuid=(Stable-Id $key);kind='steam';steam_id='990080';title='Jeu test';install='C:\Game';cover=''}
        $app=Desired-Fields $game 'C:\Runtime' $temporary
        $app['frame-generation-mode']='off';$app['frame-generation-provider']='lossless-scaling'
        $app['image-path']='C:\Mes images\image.png';$app['custom-unknown']='conserver'
        $state=Empty-State;$state.managed[$game.uuid]=@{key=$key;fields=(Desired-Fields $game 'C:\Runtime' $temporary)}
        Save-State $state
        $script:SelfTestCheckpoint='Profil explicite de generation d images par jeu'
        Assert ((Get-GameStreamFields $game).Count -eq 0) 'Aucun reglage FG force par defaut ou par modele de GPU'
        Save-GameStreamProfile $app 'game-provided'
        $plan=@(Build-Plan @($game) @($app) (Load-State) 'C:\Runtime' $temporary)[0]
        Assert ($plan.action -eq 'update' -and $plan.payload['frame-generation-mode'] -eq 'game-provided' -and
            $plan.payload['frame-generation-provider'] -eq 'game-provided' -and -not $plan.payload['lossless-scaling-enabled']) 'Profil FG du jeu prepare uniquement les champs documentes de VibeShine'
        Assert ($plan.payload['image-path'] -eq $app['image-path'] -and $plan.payload['custom-unknown'] -eq 'conserver' -and
            $plan.payload.cmd -eq $app.cmd) 'Profil conserve image personnalisee commandes et autres parametres'
        $state=Load-State;$state.managed[$game.uuid]=@{key=$key;fields=$plan.baseline};Save-State $state
        $current=Clone-Object $plan.payload
        $again=@(Build-Plan @($game) @($current) (Load-State) 'C:\Runtime' $temporary)[0]
        Assert ($again.action -eq 'unchanged') 'Profil applique une fois puis stable au passage suivant'
        $personal=To-Map $current;$personal['frame-generation-mode']='nvidia-smooth-motion'
        $preserved=@(Build-Plan @($game) @($personal) (Load-State) 'C:\Runtime' $temporary)[0]
        Assert ($preserved.payload['frame-generation-mode'] -eq 'nvidia-smooth-motion') 'Modification personnelle ulterieure du profil preservee'
        Save-GameStreamProfile $current 'off'
        $off=@(Build-Plan @($game) @($current) (Load-State) 'C:\Runtime' $temporary)[0]
        Assert ($off.payload['frame-generation-mode'] -eq 'off') 'Retour explicite au profil sans FG pris en compte'
        Save-GameStreamProfile $current 'unmanaged'
        Assert ((Get-GameStreamFields $game).Count -eq 0 -and (Load-StreamProfiles).games.Count -eq 0) 'Retrait du profil cesse de gerer les reglages sans les effacer dans VibeShine'
        $script:SelfTestCheckpoint='Préréglage de création distinct des réglages existants'
        Assert ((Read-CreationStreamMode) -eq 'game-provided') 'Moonshine propose la FG fournie par le jeu pour les nouvelles fiches'
        $script:CreationStreamMode=Read-CreationStreamMode
        $fresh=@(Build-Plan @($game) @() (Empty-State) 'C:\Runtime' $temporary)[0]
        Assert ($fresh.action -eq 'add' -and $fresh.payload['frame-generation-mode'] -eq 'game-provided' -and
            $fresh.payload['frame-generation-provider'] -eq 'game-provided' -and -not $fresh.payload['lossless-scaling-enabled'] -and -not $fresh.payload['lossless-scaling-framegen']) 'Préréglage nouveau jeu configure FG et désactive Lossless Scaling'
        Assert (-not $fresh.payload.Contains('config-overrides') -and -not $fresh.payload.Contains('gen1-framegen-fix') -and
            -not $fresh.payload.Contains('gen2-framegen-fix') -and -not $fresh.payload.Contains('lossless-scaling-target-fps')) 'Aucune fréquence cible ni correction de capture imposée par le préréglage'
        $freshState=Empty-State;$freshState.managed[$game.uuid]=@{key=$game.key;fields=$fresh.baseline}
        $repeat=@(Build-Plan @($game) @($fresh.payload) $freshState 'C:\Runtime' $temporary)[0]
        Assert ($repeat.action -eq 'unchanged') 'Nouvelle fiche préréglée inchangée à la synchronisation suivante'
        $personalized=To-Map $fresh.payload;$personalized['frame-generation-mode']='off'
        $kept=@(Build-Plan @($game) @($personalized) $freshState 'C:\Runtime' $temporary)[0]
        Assert ($kept.action -eq 'unchanged' -and $kept.payload['frame-generation-mode'] -eq 'off') 'Préréglage de création ne remplace pas un choix personnel ultérieur'
        $legacy=@(Build-Plan @($game) @($app) $state 'C:\Runtime' $temporary)[0]
        Assert ($legacy.payload['frame-generation-mode'] -eq 'off') 'Fiche déjà existante ne reçoit pas le préréglage nouveau jeu'
        Save-GameStreamProfile $current 'off'
        $explicit=@(Build-Plan @($game) @() (Empty-State) 'C:\Runtime' $temporary)[0]
        Assert ($explicit.payload['frame-generation-mode'] -eq 'off') 'Profil explicite du jeu prioritaire au préréglage de création lors du réimport'
        Save-GameStreamProfile $current 'unmanaged'
        Save-CreationStreamMode 'unmanaged';$script:CreationStreamMode=Read-CreationStreamMode
        $neutral=@(Build-Plan @($game) @() (Empty-State) 'C:\Runtime' $temporary)[0]
        Assert (-not $neutral.payload.Contains('frame-generation-mode')) 'Préférence neutre retire uniquement le préréglage des créations futures'
        Write-Json (Join-Path $temporary 'moonshine-creation-profile.json') @{schema='unknown';mode='off'}
        $refused=$false;try { $null=Read-CreationStreamMode } catch { $refused=$true }
        Assert $refused 'Préréglage corrompu bloque les créations au lieu de forcer une valeur'
        Save-CreationStreamMode 'game-provided'
        Assert ((Read-CreationStreamMode) -eq 'game-provided' -and @(Get-ChildItem -LiteralPath (Join-Path $temporary 'Recovery') -Recurse -File).Count -gt 0) 'Choix explicite répare le préréglage et conserve sa version précédente'
        $script:CreationStreamMode='unmanaged'
        Write-Json (Join-Path $temporary 'stream-profiles.json') @{schema='opi5-stream-profiles/99';games=@{}}
        $bad=$false;try { $null=Load-StreamProfiles } catch { $bad=$true }
        Assert $bad 'Profil de version inconnue conserve et refuse sans reinitialisation'
    } finally {
        $script:Data=$savedData;$script:StreamProfiles=$savedProfiles;$script:CreationStreamMode=$savedCreation
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

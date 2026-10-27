#Requires -Version 5.1
function Invoke-ProfileSelfTests {
    $savedData=$script:Data;$savedProfiles=$script:StreamProfiles
    $temporary=Join-Path $env:TEMP ('opi5-profile-selftest-'+[guid]::NewGuid().ToString('N'))
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
        Write-Json (Join-Path $temporary 'stream-profiles.json') @{schema='opi5-stream-profiles/99';games=@{}}
        $bad=$false;try { $null=Load-StreamProfiles } catch { $bad=$true }
        Assert $bad 'Profil de version inconnue conserve et refuse sans reinitialisation'
    } finally {
        $script:Data=$savedData;$script:StreamProfiles=$savedProfiles
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

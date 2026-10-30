#Requires -Version 5.1
function Invoke-MoonshineTrialSelfTests {
    . (Join-Path $PSScriptRoot 'Trial.ps1')
    $previous=$env:MOONSHINE_TRIAL_ID;$savedConnection=$script:Connection
    $temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('moonshine-trial-test-'+[guid]::NewGuid().ToString('N'))
    $installed=Get-MoonshineInstallId
    $id=Get-MoonshineTrialId
    if (-not $id) { $id=[guid]::NewGuid().ToString('N') }
    function Get-ScheduledTask { throw 'Aucune lecture de tache Windows permise dans le test d isolation.' }
    function Disable-ScheduledTask { throw 'Aucune modification de tache Windows permise dans le test d isolation.' }
    try {
        $env:MOONSHINE_TRIAL_ID=$id
        Assert ((Get-MoonshineTrialId) -ceq $id) 'Contexte d essai connu conserve'
        $root=Get-MoonshineDataRoot $id $temporary
        $relative=if ($installed) { 'Moonshine\Library\'+$id } else { 'OPi5\Moonshine-Trial\'+$id+'\Sync' }
        Assert ($root -eq (Join-Path $temporary $relative)) 'Essai et production ont des racines distinctes'
        Assert ((Get-MoonshineDataRoot '' $temporary (Join-Path $temporary 'unmarked')) -eq (Join-Path $temporary 'OPi5\VibeShine-Xbox')) 'Racine historique conservee hors essai'
        $bad=$false;try { $null=Get-MoonshineDataRoot '..\production' $temporary } catch { $bad=$true }
        Assert $bad 'Identifiant libre ou chemin parent refuse'
        $source=Join-Path $temporary 'legacy';$target=Join-Path $temporary 'destination'
        [IO.Directory]::CreateDirectory($source) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'state.json'),'ne pas importer')
        Import-LegacyData $target $source
        Assert (-not (Test-Path -LiteralPath $target)) 'Essai sans import des donnees historiques'
        Migrate-LegacyAutomation
        Assert $true 'Essai sans lecture ni migration des anciennes taches'
        $paused=Pause-ResetAutomation
        Assert (-not $paused.present -and -not $paused.was_enabled) 'Reset d essai sans toucher a une tache Windows'
        Assert ((Task-Name) -ceq ('Moonshine-Trial-'+$id)) 'Nom de tache distinct pour le mode de secours'
        $bad=$false;try { Enable-Automation } catch { $bad=$true }
        Assert $bad 'Creation de tache Windows refusee dans le mode de secours de l essai'
        Assert-MoonshineTrialEndpoint 'https://127.0.0.1:48990'
        Assert $true 'Interface locale d essai acceptee'
        $bad=$false;try { Assert-MoonshineTrialEndpoint 'https://127.0.0.1:47990' } catch { $bad=$true }
        Assert $bad 'Interface de production refusee par un moteur d essai'
        $copy=Join-Path $temporary 'runtime'
        Set-MoonshineTrialMarkers $copy $id
        Assert ((Get-MoonshineTrialId $copy) -ceq $id) 'Copie de secours conserve son identifiant d essai'
        $env:MOONSHINE_TRIAL_ID=$null
        Assert ((Get-MoonshineTrialId $copy) -ceq $id) 'Copie de secours reste isolee sans variable de lancement'
        $missing=Join-Path $temporary 'incomplete';[IO.Directory]::CreateDirectory($missing) | Out-Null
        [IO.File]::WriteAllText((Join-Path $missing 'moonshine-trial-only.txt'),'trial')
        $bad=$false;try { $null=Get-MoonshineTrialId $missing } catch { $bad=$true }
        Assert $bad 'Copie d essai incomplete sans repli vers la production'
        $install=Join-Path $temporary 'installed';[IO.Directory]::CreateDirectory($install) | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'moonshine-install-id.txt'),$id)
        Assert ((Get-MoonshineDataRoot $id $temporary $install) -ceq (Join-Path $temporary ('Moonshine\Library\'+$id))) 'Installation sans aucune racine OPi5 ou essai'
        $bad=$false;try { $null=Get-MoonshineDataRoot '' $temporary $install } catch { $bad=$true }
        Assert $bad 'Installation sans repli implicite vers les anciennes donnees'
        $runtime=Join-Path $temporary 'installed-runtime'
        Set-MoonshineTrialMarkers $runtime $id $install
        Assert ((Get-MoonshineInstallId $runtime) -ceq $id) 'Copie de secours conserve son contexte installe'
        Assert (-not (Test-Path -LiteralPath (Join-Path $runtime 'moonshine-trial-id.txt'))) 'Installation sans marqueur d essai'
        [IO.File]::WriteAllText((Join-Path $install 'moonshine-trial-id.txt'),$id)
        $bad=$false;try { $null=Get-MoonshineInstallId $install } catch { $bad=$true }
        Assert $bad 'Contextes melanges refuses'
        $env:MOONSHINE_TRIAL_ID='f'*32
        if ($env:MOONSHINE_TRIAL_ID -ceq $id) { $env:MOONSHINE_TRIAL_ID='e'*32 }
        $bad=$false;try { $null=Get-MoonshineTrialId $copy } catch { $bad=$true }
        Assert $bad 'Contexte d un autre essai refuse'
    } finally {
        $env:MOONSHINE_TRIAL_ID=$previous;$script:Connection=$savedConnection
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

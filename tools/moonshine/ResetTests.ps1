#Requires -Version 5.1
function Invoke-ResetSelfTests {
    $savedData=$script:Data;$savedRuntime=$script:Runtime;$savedRepairs=$script:Repairs
    $temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('opi5-reset-selftest-'+[guid]::NewGuid().ToString('N'))
    function Get-Apps { return Clone-Object @{apps=@($script:ResetTestApps)} }
    function Session-Idle { if ($script:ResetTestBusy) { throw 'Session synthetique active.' } }
    function Pause-ResetAutomation {
        if ($script:ResetTestPauseFails) { throw 'Pause synthetique refusee.' }
        $enabled=$script:ResetTestTask;$script:ResetTestTask=$false
        return @{present=$true;was_enabled=$enabled}
    }
    function Api-Call([string]$Method,[string]$Path,$Body=$null) {
        if ($Method -eq 'DELETE') {
            $script:ResetTestDeletes++
            if ($script:ResetTestTask) { throw 'Tache encore active pendant un DELETE.' }
            if ($script:ResetTestStopAt -eq $script:ResetTestDeletes) { throw 'Interruption synthetique avant suppression.' }
            $id=$Path.Substring('/api/apps/'.Length)
            $script:ResetTestApps=@($script:ResetTestApps | Where-Object { $_.uuid -ne $id })
            if ($script:ResetTestLoseDelete) { $script:ResetTestLoseDelete=$false;throw 'Reponse DELETE perdue apres suppression.' }
        } elseif ($Method -eq 'POST' -and $Path -eq '/api/apps') {
            $script:ResetTestPosts++
            $script:ResetTestApps=@($script:ResetTestApps | Where-Object { $_.uuid -ne $Body.uuid })+@((Clone-Object $Body))
            if ($script:ResetTestLosePost) { $script:ResetTestLosePost=$false;throw 'Reponse POST perdue apres restauration.' }
        } else { throw 'Appel inattendu dans le simulateur du reset.' }
        return @{status=$true}
    }
    try {
        $script:Data=$temporary;$script:Runtime=Join-Path $temporary 'versions\1.0.0'
        $script:Repairs=New-Object 'Collections.Generic.List[object]'
        $script:ResetTestBusy=$false;$script:ResetTestTask=$true;$script:ResetTestPauseFails=$false
        $script:ResetTestDeletes=0;$script:ResetTestPosts=0;$script:ResetTestStopAt=0
        $script:ResetTestLoseDelete=$false;$script:ResetTestLosePost=$false
        $games=@();$apps=@();$state=Empty-State
        foreach ($key in @('steam:990080','steam:1926590','steam:4374500','ea:16425629','ea:16425884','ea:16425895','xbox:Synthetic.Forza!Game','xbox:Synthetic.Cities!Game','xbox:Synthetic.Indy!Game')) {
            $game=@{key=$key;uuid=(Stable-Id $key);kind=$key.Split(':')[0];title=$key;install='C:\Synthetic';cover='';monitor_names=@()}
            if ($game.kind -eq 'steam') { $game.steam_id=$key.Substring(6) }
            elseif ($game.kind -eq 'ea') { $game.ea_content_id=$key.Substring(3);$game.ea_content_ids=@($key.Substring(3)) }
            else { $game.aumid=$key.Substring(5) }
            $app=Desired-Fields $game (Join-Path $temporary 'versions\0.3.1') $temporary
            $app['name']='Personnel '+$key;$app['image-path']='C:\Pochettes\image personnelle.png';$app['custom-unknown']=@{keep=$true}
            $apps+=@($app);$games+=@($game)
            $state.managed[$game.uuid]=@{key=$key;fields=$app}
        }
        $personal=@()
        foreach ($name in @('Desktop','Remote Input','Remote Monitor','Xbox app')) { $personal+=@(@{uuid=[guid]::NewGuid().ToString();name=$name;cmd='personnel.exe'}) }
        $script:ResetTestApps=@($apps)+@($personal)
        Save-State $state
        $before=Get-Apps
        $script:SelfTestCheckpoint='Reset 0.5 : neuf jeux anciens et quatre applications personnelles'
        $targets=@(Get-ResetTargets $before.apps)
        Assert ($targets.Count -eq 9 -and @($targets | Where-Object { $_.version -ne '0.3.1' }).Count -eq 0) 'Reset reconnait les neuf anciens lanceurs par proprietaire cle et UUID'
        $fake=To-Map $apps[0];$fake.uuid=[guid]::NewGuid().ToString()
        $foreign=To-Map $apps[0];$foreign['opi5-xbox-owner']='autre'
        $pathOnly=@{uuid=[guid]::NewGuid().ToString();name=$apps[0].name;'working-dir'=$apps[0]['working-dir'];cmd=$apps[0].cmd}
        Assert (@(Get-ResetTargets @($fake,$foreign,$pathOnly)).Count -eq 0) 'Nom ou ancien chemin seul ne permet jamais un retrait'
        $bad=$false;try { $null=@(Get-ResetTargets @($apps[0],$apps[0])) } catch { $bad=$true }
        Assert $bad 'UUID OPi5 duplique bloque le reset'
        $control=Start-ManagedReset $targets $before
        Assert ((Get-ResetControl).automatic_hold -and $script:ResetTestDeletes -eq 0) 'Journal sauvegarde et blocage automatique avant tout DELETE'
        Assert ((Same (Read-Json (Join-Path (Split-Path -Parent (Reset-JournalPath $control)) 'apps-avant.json')) $before)) 'Catalogue complet sauvegarde avant retrait, avec applications personnelles'
        $bad=$false;try { $null=Test-ResetAllowsSync $false } catch { $bad=$true }
        Assert $bad 'Synchronisation manuelle bloquee pendant un reset incomplet'
        $script:ResetTestPauseFails=$true
        $bad=$false;try { Resume-ManagedReset $control } catch { $bad=$true }
        Assert ($bad -and $script:ResetTestDeletes -eq 0 -and @($script:ResetTestApps).Count -eq 13) 'Echec de pause de la tache : aucun DELETE'
        $script:ResetTestPauseFails=$false;$script:ResetTestBusy=$true
        $bad=$false;try { Resume-ManagedReset $control } catch { $bad=$true }
        Assert ($bad -and $script:ResetTestDeletes -eq 0) 'Session active interdit les retraits'
        $script:ResetTestBusy=$false;$script:ResetTestLoseDelete=$true;$script:ResetTestStopAt=4
        $bad=$false;try { Resume-ManagedReset $control } catch { $bad=$true }
        Assert ($bad -and @($script:ResetTestApps).Count -eq 10 -and -not $script:ResetTestTask) 'Reset interrompu apres trois retraits verifies, tache deja en pause'
        Assert (@((Read-ResetJournal $control).operations | Where-Object { $_.deleted }).Count -eq 3) 'Reponse DELETE perdue recuperee par relecture, journal persistant'
        $script:ResetTestStopAt=0
        Resume-ManagedReset (Get-ResetControl)
        Assert (@($script:ResetTestApps).Count -eq 4 -and $script:ResetTestDeletes -eq 10) 'Reprise retire seulement les six entrees restantes, sans renvoyer les trois DELETE termines'
        Assert (Same @($script:ResetTestApps) $personal) 'Desktop Remote Input Remote Monitor et Xbox app integralement conserves'
        Assert ((Load-State).managed.Count -eq 0 -and (Read-ResetJournal $control).status -eq 'reset') 'Etat gere vide apres reset confirme'
        Assert (-not (Test-ResetAllowsSync $true) -and (Test-ResetAllowsSync $false)) 'Apres reset : reimport manuel permis, passage automatique bloque'
        Assert ((Read-Text (Join-Path $temporary 'last-plan.json')) -ceq 'null') 'Ancien plan invalide apres remise a zero'
        $count=$script:ResetTestDeletes;Resume-ManagedReset $control
        Assert ($script:ResetTestDeletes -eq $count) 'Reset termine repete sans suppression supplementaire'
        $script:ResetTestLosePost=$true
        Restore-ManagedReset $control
        Assert (@($script:ResetTestApps).Count -eq 13 -and $script:ResetTestPosts -eq 9) 'Restauration des neuf jeux, reponse POST perdue sans double envoi'
        Assert ((Same (Load-State) $state) -and (Read-ResetJournal $control).status -eq 'restored') 'Etat original et personnalisations retrouves apres restauration'
        foreach ($app in @($before.apps)) {
            $restored=@($script:ResetTestApps | Where-Object { $_.uuid -eq $app.uuid })
            Assert ($restored.Count -eq 1 -and (Same-App $restored[0] $app)) ('Restauration exacte : '+$app.name)
        }
        $posts=$script:ResetTestPosts;Restore-ManagedReset (Get-ResetControl)
        Assert ($script:ResetTestPosts -eq $posts -and -not $script:ResetTestTask) 'Restauration repetee sans POST ni reactivation automatique'
        $control=Start-ManagedReset @(Get-ResetTargets (Get-Apps).apps) (Get-Apps)
        $position=0
        while ($script:ResetTestApps[$position].uuid -ne $apps[0].uuid) { $position++ }
        $changed=To-Map $script:ResetTestApps[$position];$changed.name='Changement apres apercu'
        $script:ResetTestApps[$position]=$changed;$count=$script:ResetTestDeletes
        $bad=$false;try { Resume-ManagedReset $control } catch { $bad=$true }
        Assert ($bad -and $script:ResetTestDeletes -eq $count) 'Personnalisation faite apres apercu : reset suspendu avant DELETE'
        $script:ResetTestApps[$position]=Clone-Object $apps[0]
        Resume-ManagedReset $control
        $duplicate=@{uuid=[guid]::NewGuid().ToString();name='Duplicata manuel';'steam-id'='990080';cmd='steam://rungameid/990080'}
        $script:ResetTestApps+=@($duplicate);$posts=$script:ResetTestPosts
        $bad=$false;try { Restore-ManagedReset $control } catch { $bad=$true }
        Assert ($bad -and $script:ResetTestPosts -eq $posts) 'Nouvelle entree manuelle equivalente bloque la restauration sans doublon'
        $script:ResetTestApps=@($script:ResetTestApps | Where-Object { $_.uuid -ne $duplicate.uuid })
        $extra=Empty-State;$extra.managed[$games[0].uuid]=@{key=$games[0].key;fields=@{name='Nouvel etat importe'}}
        Save-State $extra
        $bad=$false;try { Restore-ManagedReset $control } catch { $bad=$true }
        Assert ($bad -and $script:ResetTestPosts -eq $posts) 'Nouvel etat gere bloque la restauration sans ecrasement'
        Save-State (Empty-State)
        Complete-ResetReimport
        Assert (Test-ResetAllowsSync $true) 'Reimport valide leve le blocage logique, sans reactiver la tache'
        Write-Json (Join-Path $temporary 'reset-control.json') @{schema='opi5-xbox-reset-control/1';backup_id='..\hors-dossier';automatic_hold=$true}
        $bad=$false;try { $null=Test-ResetAllowsSync $true } catch { $bad=$true }
        Assert ($bad -and (Get-ResetSummary).status -eq 'blocked') 'Controle de reset corrompu bloque les ecritures et reste exportable au diagnostic'
    } finally {
        $script:Data=$savedData;$script:Runtime=$savedRuntime;$script:Repairs=$savedRepairs
        Remove-Variable -Name @('ResetTestApps','ResetTestBusy','ResetTestTask','ResetTestPauseFails','ResetTestDeletes','ResetTestPosts','ResetTestStopAt','ResetTestLoseDelete','ResetTestLosePost') -Scope Script -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

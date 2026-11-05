#Requires -Version 5.1
function Invoke-BrandSelfTests {
    $savedData=$script:Data;$savedRepairs=$script:Repairs
    $script:Repairs=New-Object 'Collections.Generic.List[object]'
    $temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('opi5-brand-selftest-'+[guid]::NewGuid().ToString('N'))
    function Task-Name { return 'OPi5-test' }
    function Legacy-TaskName { return 'ancienne-test' }
    function Legacy-DataRoot { return $script:BrandTestSource }
    function Get-ScheduledTask([string]$TaskName,[string]$TaskPath) {
        if ($script:BrandTestTasks.ContainsKey($TaskName)) { return Clone-Object $script:BrandTestTasks[$TaskName] }
    }
    function Disable-ScheduledTask([string]$TaskName,[string]$TaskPath) { $script:BrandTestTasks[$TaskName].Settings.Enabled=$false }
    function Enable-ScheduledTask([string]$TaskName,[string]$TaskPath) { $script:BrandTestTasks[$TaskName].Settings.Enabled=$true }
    function Export-ScheduledTask([string]$TaskName,[string]$TaskPath) { return '<Task>definition synthetique</Task>' }
    function New-ScheduledTaskAction([string]$Execute,[string]$Argument) { return @{Execute=$Execute;Arguments=$Argument;WorkingDirectory=''} }
    function Register-ScheduledTask([string]$TaskName,[string]$TaskPath,$Action,$Trigger,$Settings,$Principal,[string]$Description) {
        $script:BrandTestTasks[$TaskName]=Clone-Object @{Actions=@($Action);Triggers=$Trigger;Settings=$Settings;Principal=$Principal;Description=$Description}
    }
    function Unregister-ScheduledTask([string]$TaskName,[string]$TaskPath,[switch]$Confirm) { $script:BrandTestTasks.Remove($TaskName) }
    try {
        $source=Join-Path $temporary 'ancien';$destination=Join-Path $temporary 'OPi5'
        [IO.Directory]::CreateDirectory((Join-Path $source 'Artwork')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $source 'versions\0.3.1')) | Out-Null
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'connection.json'),'connexion synthetique')
        [IO.File]::WriteAllText((Join-Path $source 'api-token.dpapi'),'chiffre synthetique')
        [IO.File]::WriteAllBytes((Join-Path $source 'Artwork\image.png'),[byte[]]@(1,2,3,4))
        [IO.File]::WriteAllText((Join-Path $source 'versions\0.3.1\Core.ps1'),'# ancienne version')
        [IO.File]::WriteAllText((Join-Path $source 'state.json'),'ancien etat')
        [IO.File]::WriteAllText((Join-Path $destination 'state.json'),'nouvel etat a conserver')
        $script:SelfTestCheckpoint='Migration de marque OPi5 avec donnees existantes'
        $held=[IO.File]::Open((Join-Path $source 'sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $bad=$false
        try { try { Import-LegacyData $destination $source } catch { $bad=$true } }
        finally { $held.Dispose() }
        Assert ($bad -and -not (Test-Path -LiteralPath (Join-Path $destination 'brand-migration.json'))) 'Ancien synchronisateur ouvert bloque la migration sans annoncer sa reussite'
        Import-LegacyData $destination $source
        Assert ((Read-Text (Join-Path $destination 'connection.json')) -ceq 'connexion synthetique' -and
            (Read-Text (Join-Path $destination 'api-token.dpapi')) -ceq 'chiffre synthetique') 'Connexion et jeton copies octet pour octet sans rechiffrement'
        Assert ((Read-Text (Join-Path $destination 'state.json')) -ceq 'nouvel etat a conserver') 'Donnees OPi5 existantes prioritaires, jamais ecrasees par une ancienne copie'
        Assert ((Test-Path -LiteralPath (Join-Path $source 'versions\0.3.1\Core.ps1')) -and
            -not (Test-Path -LiteralPath (Join-Path $destination 'versions')) -and
            (Read-Json (Join-Path $destination 'brand-migration.json')).complete) 'Anciens lanceurs conserves a leur emplacement, migration marquee seulement apres verification'
        [IO.File]::WriteAllText((Join-Path $source 'connection.json'),'ancienne copie modifiee')
        Import-LegacyData $destination $source
        Assert ((Read-Text (Join-Path $destination 'connection.json')) -ceq 'connexion synthetique') 'Migration terminee non rejouee au demarrage suivant'
        $key='steam:990080';$id=Stable-Id $key
        $legacy=@{uuid=$id;name='Ancien jeu'}
        $legacy[$script:LegacyFields['opi5-xbox-owner']]=$script:LegacyOwner
        $legacy[$script:LegacyFields['opi5-xbox-key']]=$key
        Assert ($id -eq '706c6f73-7862-8830-81ec-2118ff82baaa' -and (Owned $legacy $key)) 'Identite historique preservee et ancienne propriete reconnue apres changement de marque'
        $clean=Clean-App $legacy
        Assert ($clean.Contains('opi5-xbox-key') -and -not $clean.Contains($script:LegacyFields['opi5-xbox-key'])) 'Nouvelles ecritures utilisent les noms de champs OPi5'
        Assert (@(Get-ResetTargets @($legacy)).Count -eq 1) 'Reset OPi5 reconnait une entree des anciennes versions'
        $legacy['opi5-xbox-owner']='autre'
        Assert (-not (Owned $legacy $key)) 'Marqueur courant contradictoire ne peut pas etre contourne par un ancien marqueur'
        $script:Data=Join-Path $temporary 'etat'
        $oldState=@{schema=$script:LegacyStateSchema;managed=@{};pending=@{}}
        Write-Json (Join-Path $script:Data 'state.json') $oldState
        $loaded=Load-State
        Assert ($loaded.schema -eq 'opi5-xbox-state/1') 'Ancien schema connu converti en etat OPi5 sans changer les UUID'
        Save-State $loaded
        Assert ((Read-Json (Join-Path $script:Data 'state.json')).schema -eq 'opi5-xbox-state/1') 'Etat migre sauvegarde avec le nouveau schema'
        $script:Data=Join-Path $temporary 'taches';$script:BrandTestSource=$source
        $oldTask=@{Actions=@(@{Execute=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=(Automation-Arguments $source '0.4.2');WorkingDirectory=(Join-Path $source 'versions\0.4.2')});
            Triggers=@(@{Delay='PT1M'});Settings=@{Enabled=$true};Principal=@{UserId='synthetique'}}
        $script:BrandTestTasks=@{'ancienne-test'=$oldTask}
        Migrate-LegacyAutomation
        Assert ($script:BrandTestTasks.ContainsKey('OPi5-test') -and -not $script:BrandTestTasks.ContainsKey('ancienne-test') -and
            $script:BrandTestTasks['OPi5-test'].Settings.Enabled) 'Tache ancienne migree vers OPi5 avec activation conservee'
        Assert ((Same $script:BrandTestTasks['OPi5-test'].Triggers $oldTask.Triggers) -and
            $script:BrandTestTasks['OPi5-test'].Actions[0].Arguments -eq (Automation-Arguments $script:Data $script:Version)) 'Declencheurs conserves et action dirigee vers le nouveau programme'
        Migrate-LegacyAutomation
        Assert ($script:BrandTestTasks.Count -eq 1) 'Migration de tache deja faite sans doublon'
        $disabled=Clone-Object $oldTask;$disabled.Settings.Enabled=$false
        $script:BrandTestTasks=@{'ancienne-test'=$disabled}
        Migrate-LegacyAutomation
        Assert (-not $script:BrandTestTasks['OPi5-test'].Settings.Enabled) 'Tache ancienne desactivee reste desactivee apres renommage'
        $custom=Clone-Object $oldTask;$custom.Actions[0].Arguments+=' -Personnalise'
        $script:BrandTestTasks=@{'ancienne-test'=$custom}
        Migrate-LegacyAutomation
        Assert ($script:BrandTestTasks.Count -eq 1 -and -not $script:BrandTestTasks['ancienne-test'].Settings.Enabled) 'Ancienne action personnalisee preservee et mise en pause sans remplacement force'
    } finally {
        $script:Data=$savedData;$script:Repairs=$savedRepairs
        Remove-Variable -Name @('BrandTestTasks','BrandTestSource') -Scope Script -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

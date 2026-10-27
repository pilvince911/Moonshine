#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Menu','Gui','Preview','SyncPilot','SyncAll','SyncEAPilot','SyncEA','Export','SelfTest')][string]$Action='Menu',
    [switch]$Unattended,
    [object]$GuiBridge=$null,
    [switch]$FunctionsOnly
)
$ErrorActionPreference='Stop'
foreach ($module in @('Core.ps1','Repair.ps1','EA.ps1','Inventory.ps1','Api.ps1','Artwork.ps1','Profiles.ps1','Sync.ps1','Reset.ps1','Recovery.ps1','RecoveryTests.ps1','RepairTests.ps1','ResetTests.ps1','BrandTests.ps1','ProfileTests.ps1','GuiTests.ps1','SelfTests.ps1')) { . (Join-Path $PSScriptRoot $module) }
$script:Data=Join-Path $env:LOCALAPPDATA 'OPi5\VibeShine-Xbox'
$script:Runtime=Join-Path (Join-Path $script:Data 'versions') $script:Version
$script:Connection=$null;$script:Authorization=''
$script:LastInventory=$null;$script:LastPlan=@()
$script:RunId=[guid]::NewGuid().ToString('N')
$script:InventoryInfo=@{origin='not_collected';version='';created=''}
$script:PlanInfo=@{origin='not_collected';version='';created=''}
$script:LastError=$null
$script:Stage='demarrage'
$script:SelfTestCount=0;$script:SelfTestStatus='not_started';$script:SelfTestCheckpoint=''
$lock=$null
$legacyLock=$null
if ($Action -eq 'Gui') {
    if (-not $GuiBridge -or $GuiBridge.GetType().Name -ne 'OPi5GuiBridge') { throw 'Interface graphique à lancer avec Demarrer.cmd.' }
    . (Join-Path $PSScriptRoot 'GuiDiagnostics.ps1')
    . (Join-Path $PSScriptRoot 'GuiEngine.ps1')
}

function Install-Tool {
    [IO.Directory]::CreateDirectory($script:Data) | Out-Null
    [IO.Directory]::CreateDirectory($script:Runtime) | Out-Null
    if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine [IO.Path]::GetFullPath($script:Runtime).TrimEnd('\')) {
        foreach ($file in @('Moonshine-Worker.ps1','Recovery.ps1','RecoveryTests.ps1','Desktop.ps1','Desktop.xaml','DesktopView.cs','GuiBridge.cs','GuiEngine.ps1','GuiDiagnostics.ps1','GuiTests.ps1','Mode-console.cmd','Brand.ps1','BrandTests.ps1','Profiles.ps1','ProfileTests.ps1','Atomic.ps1','Bootstrap.ps1','Repair.ps1','RepairTests.ps1','Reset.ps1','ResetTests.ps1','SHA256.txt','Core.ps1','EA.ps1','Inventory.ps1','Api.ps1','Artwork.ps1','Artwork.cs','Sync.ps1','SelfTests.ps1','TransportTests.cs','Transport-Test.pfx','Native.cs','Launch-Game.ps1','VibeShine-Xbox.ps1','Demarrer.cmd','Exporter-retour.cmd','LIRE-MOI.txt','VALIDATION.txt','SOURCES.txt')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $script:Runtime $file) -Force
        }
    }
}
function Record-Error([Management.Automation.ErrorRecord]$Record) {
    if ($script:SelfTestStatus -eq 'running') { $script:SelfTestStatus='failed' }
    # Store locations, never InvocationInfo.Line or the complete ErrorRecord:
    # those can contain command arguments and credential-related local values.
    $script:LastError=[ordered]@{
        time=(Get-Date).ToString('o');version=$script:Version;run_id=$script:RunId;stage=$script:Stage
        message=(Redact $Record.Exception.Message)
        exception_type=$Record.Exception.GetType().FullName
        file_io=(Atomic-FailureSummary $Record)
        script=[IO.Path]::GetFileName($Record.InvocationInfo.ScriptName)
        line=$Record.InvocationInfo.ScriptLineNumber
        stack=(Redact $Record.ScriptStackTrace)
        selftests_passed=$script:SelfTestCount;selftest_checkpoint=$script:SelfTestCheckpoint
    }
    Write-Json (Join-Path $script:Data 'last-error.json') $script:LastError
}
function Save-Report {
    $summary=@()
    foreach ($r in @($script:LastPlan)) { $summary+=@{key=$r.key;title=$r.title;action=$r.action;reason=$r.reason;changed_fields=@(Field $r 'changed_fields' @() | Where-Object { $null -ne $_ })} }
    $lastRun=Read-OptionalJson (Join-Path $script:Data 'last-run.json')
    $lastError=$(if ($null -ne $script:LastError) { $script:LastError } else { Read-OptionalJson (Join-Path $script:Data 'last-error.json') })
    $lastRunOrigin='not_recorded'
    if ($lastRun) { $lastRunOrigin=$(if ((Field $lastRun 'run_id') -eq $script:RunId) {'current_run'} else {'previous_run'}) }
    $report=[ordered]@{
        schema='opi5-xbox-return/1';version=$script:Version;time=(Get-Date).ToString('o')
        run_id=$script:RunId
        powershell=$PSVersionTable.PSVersion.ToString()
        selftests=$script:SelfTestCount
        selftests_current=@{status=$script:SelfTestStatus;checkpoint=$script:SelfTestCheckpoint}
        inventory=$script:LastInventory;plan=$summary
        inventory_context=$script:InventoryInfo;plan_context=$script:PlanInfo
        repairs=@($script:Repairs.ToArray())
        reset=(Get-ResetSummary)
        rollback=(Get-UndoSummary)
        stream_profiles=@(foreach ($id in @(Keys $script:StreamProfiles.games)) { $profile=Field $script:StreamProfiles.games $id;@{uuid=$id;key=$profile.key;mode=$profile.mode} })
        bootstrap=(Read-OptionalJson (Join-Path $script:Data 'bootstrap-health.json'))
        last_run=$lastRun
        last_run_context=@{origin=$lastRunOrigin;version=(Field $lastRun 'version' 'unknown')}
        last_error=$lastError
        last_error_context=@{origin=$(if (-not $lastError) {'not_recorded'} elseif ($null -ne $script:LastError) {'current_run'} else {'previous_run'});version=(Field $lastError 'version' 'unknown')}
        privacy='Aucun jeton, mot de passe, apps.json brut, sauvegarde privee ou SID.'
    }
    $report.repairs=@(Repair-History)
    $text=Redact (Json $report)
    Write-AtomicBytes (Join-Path $script:Data 'rapport-partage.json') ([Text.Encoding]::UTF8.GetBytes($text))
}
function Export-Return {
    if (-not $script:LastInventory) {
        $script:LastInventory=Read-OptionalJson (Join-Path $script:Data 'last-inventory.json')
        if ($script:LastInventory) { $script:InventoryInfo=@{origin='cached_previous_run';version=(Field $script:LastInventory 'version' 'unknown');created=(Field $script:LastInventory 'created' '')} }
    }
    if (@($script:LastPlan).Count -eq 0 -and $script:PlanInfo.origin -ne 'current_run') {
        $cachedPlan=Read-OptionalJson (Join-Path $script:Data 'last-plan.json')
        $script:LastPlan=@(Field $cachedPlan 'rows' @() | Where-Object { $null -ne $_ })
        if ($cachedPlan) { $script:PlanInfo=@{origin='cached_previous_run';version=(Field $cachedPlan 'version' 'unknown');created=(Field $cachedPlan 'created' '')} }
    }
    Save-Report
    $desktop=[Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop=$script:Data }
    $name='OPi5-VibeShine-Retour-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
    $folder=Join-Path (Join-Path $script:Data 'Returns') $name
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:Data 'rapport-partage.json') -Destination (Join-Path $folder 'rapport.json')
    $logDir=Join-Path $script:Data 'Logs'
    $logs=@(Get-ChildItem -LiteralPath $logDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20)
    if ($logs.Count -gt 0) {
        $out=Join-Path $folder 'lancements'
        [IO.Directory]::CreateDirectory($out) | Out-Null
        foreach ($logFile in $logs) {
            if ($logFile.Length -gt 1048576) { continue }
            try {
                [IO.File]::WriteAllText((Join-Path $out $logFile.Name),(Redact (Read-Text $logFile.FullName 1048576)),(New-Object Text.UTF8Encoding($false)))
            } catch {}
        }
    }
    $lines=@(('OPi5 / VibeShine / Xbox - retour '+$script:Version),
        'Contenu : inventaire, plan, resultat, erreurs et journaux de lancement selectionnes.',
        'Exclus : identifiants de connexion, jetons API, sauvegardes du catalogue et commandes personnelles.',
        ('Autotests de cette execution : '+$script:SelfTestStatus+'; reussis : '+$script:SelfTestCount),
        ('Origine inventaire : '+$script:InventoryInfo.origin+'; version : '+$script:InventoryInfo.version),
        ('Origine plan : '+$script:PlanInfo.origin+'; version : '+$script:PlanInfo.version),
        'Les chemins du profil Windows sont masques.')
    [IO.File]::WriteAllLines((Join-Path $folder 'resume.txt'),$lines,(New-Object Text.UTF8Encoding($false)))
    $zip=Join-Path $desktop ($name+'-partage.zip')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($folder,$zip)
    Write-Host ('ZIP de retour : '+$zip) -ForegroundColor Cyan
    return $zip
}
function Refresh-Inventory {
    Write-Host 'Lecture de la bibliotheque Xbox et des installations...' -ForegroundColor Cyan
    $script:LastInventory=Get-Inventory
    $script:LastInventory['run_id']=$script:RunId
    $script:InventoryInfo=@{origin='current_run';version=$script:Version;created=$script:LastInventory.created}
    $artworkIndex=0;$artworkTotal=@($script:LastInventory.ready).Count
    foreach ($g in @($script:LastInventory.ready)) {
        Operation-Checkpoint
        if (-not $Unattended) { Write-Progress -Activity 'Pochettes des jeux' -Status $g.title -PercentComplete ([int](100*$artworkIndex/[math]::Max(1,$artworkTotal))) }
        try { Resolve-Artwork $g $script:Data (-not [bool]$Unattended) }
        catch { Note 'pochette' ('Preparation impossible pour '+$g.title+' : '+$_.Exception.Message) }
        Operation-Checkpoint
        $artworkIndex++
    }
    if (-not $Unattended) { Write-Progress -Activity 'Pochettes des jeux' -Completed }
    $script:LastInventory.notes=@($script:Notes.ToArray())
    Write-Json (Join-Path $script:Data 'last-inventory.json') $script:LastInventory
    Write-Host (@($script:LastInventory.ready).Count.ToString()+' jeu(x) importable(s).')
    foreach ($g in @($script:LastInventory.ready)) { Write-Host ('  '+$g.title+' ['+$g.kind+'] | image : '+$g.artwork_origin) }
    foreach ($p in @($script:LastInventory.pending)) { Write-Host ('  En attente : '+$p.key+' '+$p.title+' | '+$p.reason) -ForegroundColor Yellow }
    foreach ($n in @($script:LastInventory.notes)) { Write-Host ('  Note : '+$n.message) -ForegroundColor Yellow }
}
function Local-Apps {
    # This path was located by PL's audit. The API is authoritative before any write.
    $path=Join-Path $env:ProgramFiles 'Sunshine\config\apps.json'
    $root=Read-Json $path
    if (-not $root -or $null -eq (Field $root 'apps')) {
        Write-Host 'Catalogue local introuvable. La connexion API est requise pour un apercu des doublons.'
        return @{apps=@()}
    }
    return $root
}
function Show-Preview {
    $script:StreamProfiles=Load-StreamProfiles
    $canRepair=Test-UndoAllowsSync $true
    Refresh-Inventory
    $state=Load-State
    if ($script:Authorization) {
        $root=Get-Apps
        if ($canRepair) {
            Repair-ManagedState $state $root.apps $script:LastInventory.ready $script:Runtime $script:Data
            Recover-Pending $state $root.apps
        }
        Write-Host 'Catalogue de reference : API VibeShine.'
    } else {
        $root=Local-Apps
        Write-Host 'Catalogue local preliminaire : les doublons seront reverifies par API avant tout ajout.'
    }
    $script:LastPlan=@(Build-Plan $script:LastInventory.ready $root.apps $state $script:Runtime $script:Data)
    $script:PlanInfo=@{origin='current_run';version=$script:Version;created=(Get-Date).ToString('o')}
    Plan-Summary $script:LastPlan | Format-Table -AutoSize -Wrap | Out-Host
    Write-Json (Join-Path $script:Data 'last-plan.json') @{version=$script:Version;created=$script:PlanInfo.created;run_id=$script:RunId;rows=@($script:LastPlan | ForEach-Object {
        @{key=$_.key;title=$_.title;action=$_.action;reason=$_.reason;changed_fields=@($_.changed_fields)}
    })}
    Save-Report
    Write-Host 'Apercu termine. Aucune entree ajoutee ou retiree par le synchronisateur.'
}
function Pilot-Games($Games) {
    $chosen=@()
    $steam=@($Games | Where-Object { $_.key -eq 'steam:990080' })
    if ($steam.Count -eq 0) { $steam=@($Games | Where-Object { $_.kind -eq 'steam' } | Select-Object -First 1) }
    $xbox=@($Games | Where-Object { $_.aumid -ieq 'Microsoft.ForzaMotorsport_8wekyb3d8bbwe!ReleaseFinal' })
    if ($xbox.Count -eq 0) { $xbox=@($Games | Where-Object { $_.kind -eq 'xbox' } | Select-Object -First 1) }
    $chosen+=@($steam);$chosen+=@($xbox)
    return $chosen
}
function Sync-Games([bool]$Pilot,[bool]$EaPilot=$false,[bool]$EaOnly=$false) {
    if (-not $script:Authorization) { throw 'Faire le choix 2 pour connecter VibeShine avant de synchroniser.' }
    $script:StreamProfiles=Load-StreamProfiles
    $script:SyncOutcome=''
    if (-not (Test-UndoAllowsSync ([bool]$Unattended))) {
        $script:SyncOutcome='Retour arrière en cours. Reprendre l’annulation depuis Maintenance.'
        Write-Json (Join-Path $script:Data 'last-run.json') @{version=$script:Version;run_id=$script:RunId;time=(Get-Date).ToString('o');status='paused_rollback';reason=$script:SyncOutcome}
        return
    }
    if (-not (Test-ResetAllowsSync ([bool]$Unattended))) {
        $script:SyncOutcome='Synchronisation en pause après remise à zéro.' 
        Write-Json (Join-Path $script:Data 'last-run.json') @{version=$script:Version;run_id=$script:RunId;time=(Get-Date).ToString('o');status='paused_after_reset';reason='Remise a zero terminee; reimport manuel requis avant automatisation.'}
        return
    }
    if ($Unattended -and -not (Session-IsIdle)) {
        $script:SyncOutcome='Passage reporté pendant une session Moonlight active.'
        Write-Json (Join-Path $script:Data 'last-run.json') @{version=$script:Version;run_id=$script:RunId;time=(Get-Date).ToString('o');status='skipped_busy';reason='Session Moonlight active; nouvel essai au prochain passage.'}
        return
    }
    Refresh-Inventory
    $games=@($script:LastInventory.ready)
    if ($Pilot) { $games=@(Pilot-Games $games) }
    if ($EaPilot -or $EaOnly) { $games=@(EA-SelectGames $games $EaPilot) }
    if ($games.Count -eq 0) {
        $script:SyncOutcome='Aucun jeu importable dans cette sélection.'
        if (-not $Unattended) { throw 'Aucun jeu importable dans cette selection.' }
        Write-Json (Join-Path $script:Data 'last-run.json') @{version=$script:Version;run_id=$script:RunId;time=(Get-Date).ToString('o');status='no_supported_games';reason='Aucun retrait effectue.'}
        return
    }
    Session-Idle
    $root=Get-Apps
    $state=Load-State
    Repair-ManagedState $state $root.apps $script:LastInventory.ready $script:Runtime $script:Data
    Recover-Pending $state $root.apps
    $script:LastPlan=@(Build-Plan $games $root.apps $state $script:Runtime $script:Data)
    $script:PlanInfo=@{origin='current_run';version=$script:Version;created=(Get-Date).ToString('o')}
    Plan-Summary $script:LastPlan | Format-Table -AutoSize -Wrap | Out-Host
    $allKeys=@($script:LastInventory.ready | ForEach-Object { $_.key })
    $missing=@()
    foreach ($uuid in @(Keys $state.managed)) {
        $record=Field $state.managed $uuid
        if ($record.key -notin $allKeys) { $missing+=$record.key;Write-Host ('Absent de ce scan, conserve : '+$record.key) -ForegroundColor Yellow }
    }
    Write-Json (Join-Path $script:Data 'last-plan.json') @{version=$script:Version;created=$script:PlanInfo.created;run_id=$script:RunId;rows=@($script:LastPlan | ForEach-Object { @{key=$_.key;title=$_.title;action=$_.action;reason=$_.reason;changed_fields=@($_.changed_fields)} })}
    Save-Report
    if (-not $Unattended -and @($script:LastPlan | Where-Object { $_.action -in @('add','update') }).Count -gt 0) {
        if ((Read-Host 'Taper APPLIQUER pour enregistrer ce plan, ou Entree pour revenir') -cne 'APPLIQUER') { return }
    }
    Apply-Plan $script:LastPlan $games $state $root
    $addCount=@($script:LastPlan | Where-Object { $_.action -eq 'add' }).Count
    $updateCount=@($script:LastPlan | Where-Object { $_.action -eq 'update' }).Count
    $conflictCount=@($script:LastPlan | Where-Object { $_.action -eq 'conflict' }).Count
    $script:SyncOutcome=$(if ($addCount+$updateCount -eq 0) {'Catalogue vérifié : aucune écriture nécessaire.'} else {$addCount.ToString()+' ajout(s), '+$updateCount+' mise(s) à jour vérifiée(s).'})
    if ($conflictCount -gt 0) { $script:SyncOutcome+=' '+$conflictCount+' entrée(s) à vérifier; détails dans la bibliothèque.' }
    Write-Json (Join-Path $script:Data 'last-run.json') @{
        version=$script:Version;run_id=$script:RunId
        time=(Get-Date).ToString('o');selection=$(if ($EaPilot) {'ea-pilot'} elseif ($EaOnly) {'ea'} elseif ($Pilot) {'pilot'} else {'all'})
        added=@($script:LastPlan | Where-Object { $_.action -eq 'add' }).Count
        updated=@($script:LastPlan | Where-Object { $_.action -eq 'update' }).Count
        unchanged=@($script:LastPlan | Where-Object { $_.action -eq 'unchanged' }).Count
        existing=@($script:LastPlan | Where-Object { $_.action -eq 'existing' }).Count
        conflicts=@($script:LastPlan | Where-Object { $_.action -eq 'conflict' }).Count
        missing_preserved=@($missing);status=$(if (@($script:LastPlan | Where-Object { $_.action -eq 'conflict' }).Count -gt 0) {'completed_with_conflicts'} else {'completed'})
    }
    Write-Json (Join-Path $script:Data 'last-error.json') $null
    $script:LastError=$null
    if (@($script:LastPlan | Where-Object { $_.action -eq 'conflict' }).Count -eq 0) { Complete-ResetReimport }
    Save-Report
}
function Task-Name {
    return 'OPi5-VibeShine-Xbox-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
function Repair-AutomationRuntime {
    $task=Get-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $task) { return }
    $actions=@($task.Actions)
    if ($actions.Count -ne 1 -or -not (Test-ManagedAutomationAction $actions[0] $script:Data)) {
        Repair-Event 'schedule' 'custom_preserved' 'Action de tache personnalisee conservee; verifier son choix de version.'
        return
    }
    $arguments=Automation-Arguments $script:Data $script:Version
    if ([string]$actions[0].Arguments -ceq $arguments) { return }
    $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action=New-ScheduledTaskAction -Execute $ps -Argument $arguments
    $wasEnabled=[bool]$task.Settings.Enabled
    $null=Set-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -Action $action -Settings $task.Settings -ErrorAction Stop
    $check=Get-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -ErrorAction Stop
    if (@($check.Actions).Count -ne 1 -or [string]$check.Actions[0].Arguments -cne $arguments -or
        [bool]$check.Settings.Enabled -ne $wasEnabled) { throw 'Migration de la tache automatique non confirmee; verifier le choix 9 avant de synchroniser.' }
    Repair-Event 'schedule' 'version_updated' ('Tache existante dirigee vers '+$script:Version+'; activation et declencheurs conserves.')
}
function Enable-Automation {
    if (-not $script:Authorization) { throw 'Connecter VibeShine avant d activer la tache.' }
    $null=Test-UndoAllowsSync $false
    if (-not (Test-ResetAllowsSync $true)) { throw 'Reset en pause : faire le choix 4 et valider le reimport avant de reactiver la tache.' }
    Write-Host 'La tache verifiera les jeux une minute apres votre ouverture de session, puis toutes les dix minutes.'
    Write-Host 'Elle ajoutera et actualisera les entrees gerees, sans retirer les jeux absents.'
    if ((Read-Host 'Apres validation des lancements Moonlight, taper ACTIVER') -cne 'ACTIVER') { return }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $principal=New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $identity
    $trigger.Delay='PT1M'
    $periodic=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 10)
    $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments=Automation-Arguments $script:Data $script:Version
    $action=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $script:Runtime
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName (Task-Name) -Action $action -Trigger @($trigger,$periodic) -Principal $principal -Settings $settings -Description 'Jeux PC Xbox vers VibeShine : ouverture de session et toutes les 10 minutes; aucune suppression automatique.' -Force | Out-Null
    Write-Host 'Tache activee pour ce compte Windows.' -ForegroundColor Green
}
function Disable-Automation {
    $task=Get-ScheduledTask -TaskName (Task-Name) -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName (Task-Name) -Confirm:$false }
    Write-Host 'Tache de synchronisation desactivee.'
}
function Show-Status {
    $state=Load-State
    Write-Host ('Entrees gerees : '+@(Keys $state.managed).Count+' | ecritures a verifier : '+@(Keys $state.pending).Count)
    Write-Host ('Connexion chargee : '+[bool]$script:Authorization)
    $reset=Get-ResetSummary
    if ($reset) { Write-Host ('Remise a zero : '+$reset.status+' | automatisation retenue : '+$reset.automatic_hold+' | sauvegarde : '+$reset.backup_id) }
    $undo=Get-UndoSummary
    if ($undo) { Write-Host ('Retour arrière : '+$undo.status+' | opérations rétablies : '+$undo.restored+' / '+$undo.total) }
    $task=Get-ScheduledTask -TaskName (Task-Name) -ErrorAction SilentlyContinue
    if ($task) {
        $info=Get-ScheduledTaskInfo -TaskName (Task-Name)
        Write-Host ('Tache : '+$task.State+' | dernier code : '+$info.LastTaskResult+' | prochain passage : '+$info.NextRunTime)
    } else { Write-Host 'Synchronisation automatique desactivee.' }
    $last=Read-OptionalJson (Join-Path $script:Data 'last-run.json')
    if ($last) { Write-Host ('Dernier passage : '+$last.time+' | '+$last.status) }
    foreach ($repair in @(Repair-History | Select-Object -Last 10)) { Write-Host ('  Reparation : '+$repair.area+' / '+$repair.action+' / '+$repair.detail) }
    $inventory=Read-OptionalJson (Join-Path $script:Data 'last-inventory.json')
    if ($inventory) {
        foreach ($game in @($inventory.ready)) { Write-Host ('  '+$game.title+' | image : '+$game.artwork_origin) }
        foreach ($game in @($inventory.pending)) { Write-Host ('  En attente : '+$game.key+' '+$game.title+' | '+$game.reason) -ForegroundColor Yellow }
    }
}
if ($FunctionsOnly) { return }

try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Utiliser Windows PowerShell 5.1 64 bits sur le PC de jeux.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if ($identity.IsSystem -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Lancer normalement dans la session qui utilise Xbox app, sans Executer en tant qu administrateur.'
    }
    [IO.Directory]::CreateDirectory($script:Data) | Out-Null
    try { $lock=[IO.File]::Open((Join-Path $script:Data 'sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch {
        if ($Unattended) { exit 0 }
        throw 'Un autre exemplaire du synchronisateur est ouvert. Faire 0 dans son menu avant de continuer.'
    }
    $script:Stage='autotests';$script:SelfTestStatus='running'
    if (Test-Path -LiteralPath (Legacy-DataRoot) -PathType Container) {
        try { $legacyLock=[IO.File]::Open((Join-Path (Legacy-DataRoot) 'sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'Fermer les anciens menus du synchronisateur avant de lancer OPi5.' }
    }
    $count=Invoke-SelfTests
    $script:Repairs.Clear()
    $script:AtomicWriteEvents.Clear();$script:AtomicRetained.Clear()
    $bootstrap=Read-OptionalJson (Join-Path $script:Data 'bootstrap-health.json')
    if ($bootstrap -and $bootstrap.version -eq $script:Version) {
        foreach ($write in @(Field $bootstrap 'file_writes' @())) { [void]$script:AtomicWriteEvents.Add($write) }
        foreach ($item in @(@($bootstrap.runtime)+@($bootstrap.backup) | Where-Object { $_.action -eq 'repaired' })) {
            Repair-Event 'program' 'restored' ([string]$item.file)
        }
    }
    $script:SelfTestStatus='passed';$script:Stage='enregistrement des autotests'
    Write-Json (Join-Path $script:Data 'selftests.json') @{passed=$count;version=$script:Version;time=(Get-Date).ToString('o');runtime='Windows PowerShell';game_launches_tested=$false}
    $script:Stage='installation du synchronisateur'
    Install-Tool
    $script:Stage='lecture des profils de diffusion'
    try { $script:StreamProfiles=Load-StreamProfiles }
    catch {
        if ($Action -ne 'Gui') { throw }
        $script:GuiLocalError=Redact $_.Exception.Message
        $script:StreamProfiles=@{schema='opi5-stream-profiles/1';games=@{}}
    }
    if ($Action -notin @('Export','SelfTest')) {
        $script:Stage='mise a jour de la tache existante'
        Migrate-LegacyAutomation
        Repair-AutomationRuntime
    }
    Write-Host ('OPi5 - VibeShine / Xbox '+$script:Version+' | '+$count+' autotests reussis') -ForegroundColor Cyan
    $script:Stage='lecture de la connexion locale'
    try { Load-Connection } catch { if ($Unattended) { throw };Write-Host $_.Exception.Message -ForegroundColor Yellow }
    $script:Stage='action '+$Action
    switch ($Action) {
        'Gui' {
            Gui-RefreshData -Online
            Gui-PublishSnapshot
            $lock.Dispose();$lock=$null
            if ($legacyLock) { $legacyLock.Dispose();$legacyLock=$null }
            Start-GuiEngine
        }
        'SelfTest' { }
        'Preview' { Show-Preview }
        'SyncPilot' { Sync-Games $true }
        'SyncAll' { Sync-Games $false }
        'SyncEAPilot' { Sync-Games $false $true }
        'SyncEA' { Sync-Games $false $false $true }
        'Export' { $null=Export-Return }
        'Menu' {
            do {
                Write-Host ''
                Write-Host '  1  Analyser et afficher l apercu'
                Write-Host '  2  Connecter VibeShine (une fois)'
                Write-Host '  3  Synchroniser le pilote : un Steam + un Xbox'
                Write-Host '  4  Synchroniser tous les jeux pris en charge'
                Write-Host '  5  Annuler la derniere synchronisation'
                Write-Host '  6  Creer le ZIP de retour sur le Bureau'
                Write-Host '  7  Activer la synchronisation automatique (session + 10 min)'
                Write-Host '  8  Desactiver cette synchronisation automatique'
                Write-Host '  9  Etat de la synchronisation et des images'
                Write-Host ' 10  Synchroniser le pilote EA : PGA Tour ou premier jeu EA'
                Write-Host ' 11  Synchroniser tous les jeux EA seulement'
                Write-Host ' 12  Remise a zero : retirer les entrees creees par OPi5'
                Write-Host ' 13  Restaurer la derniere remise a zero'
                Write-Host ' 14  Profil de diffusion par jeu : DLSS/FSR Frame Generation'
                Write-Host '  0  Quitter'
                $choice=Read-Host 'Choix'
                $script:Stage='menu '+$choice
                try {
                    switch ($choice) {
                        '1' { Show-Preview }
                        '2' { Connect-Vibe }
                        '3' { Sync-Games $true }
                        '4' { Sync-Games $false }
                        '5' { Undo-LastSync }
                        '6' { $null=Export-Return }
                        '7' { Enable-Automation }
                        '8' { Disable-Automation }
                        '9' { Show-Status }
                        '10' { Sync-Games $false $true }
                        '11' { Sync-Games $false $false $true }
                        '12' { Reset-ManagedGames }
                        '13' { Undo-ManagedReset }
                        '14' { Configure-StreamProfile }
                    }
                } catch {
                    $failure=$_
                    try { Record-Error $failure } catch { Write-Host 'Le diagnostic local n a pas pu etre enregistre.' -ForegroundColor Yellow }
                    Write-Host ('ERREUR : '+$failure.Exception.Message) -ForegroundColor Red
                    Write-Host 'Le choix 6 permet de joindre le diagnostic.'
                }
            } while ($choice -ne '0')
        }
    }
} catch {
    $failure=$_
    $cause=$failure.Exception
    while ($cause.InnerException) { $cause=$cause.InnerException }
    if ($GuiBridge -and $cause -is [OperationCanceledException]) {
        $GuiBridge.Publish('fatal','Démarrage annulé. Aucun changement du catalogue n’a été appliqué.',-1,$null)
        return
    }
    try { Record-Error $failure } catch { Write-Host 'Le diagnostic local n a pas pu etre enregistre.' -ForegroundColor Yellow }
    Write-Host ('ERREUR : '+$failure.Exception.Message) -ForegroundColor Red
    if (-not $Unattended) {
        try { $zip=Export-Return;if ($GuiBridge) { $GuiBridge.Publish('export',$zip,-1,$null) } } catch { }
    }
    if ($GuiBridge) { $GuiBridge.Publish('fatal',(Gui-Text (Redact $failure.Exception.Message)),-1,$null) }
    exit 1
} finally {
    $script:Authorization=''
    if ($lock) { $lock.Dispose() }
    if ($legacyLock) { $legacyLock.Dispose() }
}

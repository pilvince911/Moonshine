#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory=$true)][ValidatePattern('^Moonshine\.Sync\.[a-f0-9]{32}$')][string]$PipeName)
# Private stdin carries the temporary token. stdout is a bounded event protocol.
$ErrorActionPreference='Stop'
$script:MoonshineChannel=New-Object IO.Pipes.NamedPipeClientStream('.', $PipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None, [Security.Principal.TokenImpersonationLevel]::Identification)
$script:MoonshineChannel.Connect(30000)
$encoding=New-Object Text.UTF8Encoding($false)
[Console]::SetIn((New-Object IO.StreamReader($script:MoonshineChannel,$encoding,$false,4096,$true)))
$writer=New-Object IO.StreamWriter($script:MoonshineChannel,$encoding,4096,$true);$writer.AutoFlush=$true
[Console]::SetOut($writer)
$script:MoonshineBoot=$null;$script:EmbeddedCancel=$null;$script:MoonshineLock=$null;$script:MoonshineOldLock=$null
$script:MoonshineLastLog='';$script:MoonshinePhase='starting'
function Emit-Moonshine([string]$Type,$Data) {
    $record=@{type=$Type;data=$Data}
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $record -Depth 60 -Compress))
    [Console]::Out.Flush()
}
function Write-Host {
    [CmdletBinding(PositionalBinding=$false)]
    param([Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Object,[ConsoleColor]$ForegroundColor,[ConsoleColor]$BackgroundColor,[switch]$NoNewline,[object]$Separator=' ')
    if ($script:SelfTestStatus -eq 'running') { return }
    $text=(@($Object | ForEach-Object { [string]$_ }) -join [string]$Separator).Trim()
    if ($text) { $script:MoonshineLastLog=Redact $text;Emit-Moonshine 'log' @{message=$script:MoonshineLastLog} }
}
function Write-Progress {
    param([string]$Activity,[string]$Status,[int]$PercentComplete=-1,[switch]$Completed,[int]$Id=0,[int]$ParentId=-1,[string]$CurrentOperation)
    if (-not $Completed) { Emit-Moonshine 'progress' @{message=($Activity+' · '+$Status);percent=$PercentComplete} }
}
function Out-Host {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true)]$InputObject)
    process { }
}
function Publish-MoonshineSnapshot {
    $apps=@();try { $apps=@((Get-Apps).apps) } catch { }
    $rows=@()
    foreach ($game in @(Field $script:LastInventory 'ready' @() | Where-Object { $null -ne $_ })) {
        $plan=@($script:LastPlan | Where-Object { $_.key -eq $game.key } | Select-Object -First 1)
        $owned=@($apps | Where-Object { $_.uuid -eq $game.uuid -and (Owned $_ $game.key) })
        $r=[ordered]@{uuid=$game.uuid;key=$game.key;title=$game.title;platform=$game.kind;action='unknown';reason='';changed_fields=@();managed=($owned.Count -eq 1)}
        if ($plan.Count) { $r.action=$plan[0].action;$r.reason=$plan[0].reason;$r.changed_fields=@($plan[0].changed_fields) }
        $profile=Field $script:StreamProfiles.games ([string]$game.uuid);$r['profile']=$(if ($profile) {$profile.mode} else {'unmanaged'})
        $rows+=@($r)
    }
    foreach ($entry in @(Field $script:LastInventory 'pending' @() | Where-Object { $null -ne $_ })) {
        $rows+=@{uuid='';key=$entry.key;title=$(if ($entry.title) {$entry.title} else {$entry.key});platform=([string]$entry.key).Split(':')[0];action='pending';reason=$entry.reason;changed_fields=@();managed=$false;profile='unmanaged'}
    }
    $snapshot=@{schema='moonshine-snapshot/1';version=$script:Version;created=(Get-Date).ToString('o');games=@($rows);tests=$script:SelfTestCount;
        reset=(Get-ResetSummary);rollback=(Get-UndoSummary);creation_profile=[string]$script:CreationStreamMode;scope=[string]$script:MoonshineBoot.scope;cached=($script:InventoryInfo.origin -ne 'current_run');inventory_created=[string](Field $script:LastInventory 'created' '')}
    Write-Json (Join-Path $script:Data 'moonshine-snapshot.json') $snapshot
    Emit-Moonshine 'snapshot' $snapshot
}
function Read-Host([string]$Prompt,[switch]$AsSecureString) {
    Operation-Checkpoint
    if ($AsSecureString) { throw 'Connexion gérée par Moonshine; aucune saisie de mot de passe dans le moteur.' }
    $expected='';$typed=$false
    if ($Prompt -like 'Taper APPLIQUER*') { $expected='APPLIQUER' }
    elseif ($Prompt -like 'Taper REINITIALISER*') { $expected='REINITIALISER';$typed=$true }
    elseif ($Prompt -like 'Taper RESTAURER*') { $expected='RESTAURER' }
    elseif ($Prompt -like 'Taper ANNULER*') { $expected='ANNULER' }
    elseif ($Prompt -like '*taper ACTIVER*') { $expected='ACTIVER' }
    else { throw 'Confirmation interne non reconnue; aucune modification.' }
    Publish-MoonshineSnapshot
    $details=@()
    if ($expected -eq 'APPLIQUER') { foreach ($row in @($script:LastPlan | Where-Object { $_.action -in @('add','update') })) { $details+=@{title=$row.title;action=$row.action;reason=$row.reason} } }
    elseif ($expected -eq 'REINITIALISER') {
        foreach ($row in @(Get-Variable -Name targets -Scope 1 -ValueOnly -ErrorAction SilentlyContinue)) { $details+=@{title=$row.title;action='remove';reason='Retrait de VibeShine; jeu installé conservé.'} }
    } else {
        $journal=Get-Variable -Name journal -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
        foreach ($row in @($journal.operations)) { $details+=@{title=$(if ($row.title) {$row.title} else {$row.key});action='restore';reason='Personnalisations ultérieures protégées.'} }
    }
    Emit-Moonshine 'prompt' @{message=$Prompt;expected=$expected;typed=$typed;rows=$details}
    $line=[Console]::In.ReadLine()
    if ($null -eq $line -or $line.Length -gt 4096) { throw [OperationCanceledException]::new('Fenêtre de confirmation fermée.') }
    $reply=ConvertFrom-Json -InputObject $line -ErrorAction Stop
    Operation-Checkpoint
    if ([string]$reply.answer -cne $expected) { $script:MoonshinePhase='declined';return '' }
    if ($expected -in @('REINITIALISER','ANNULER')) { Write-Json (Join-Path $script:Data 'moonshine-auto.json') @{schema='moonshine-auto/1';enabled=$false;interval_minutes=10} }
    return $expected
}
function Takeover-MoonshineAutomation {
    if (Get-MoonshineTrialId) { return }
    $marker=Join-Path $script:Data 'moonshine-takeover.json'
    $existing=Read-Json $marker
    if ($existing) {
        if ($existing.schema -ne 'moonshine-takeover/1' -or $existing.state -notin @('pending','complete') -or $existing.automatic -isnot [bool]) { throw 'Journal de reprise de l automatisation invalide.' }
        if ($existing.state -eq 'complete') { return }
    }
    $task=Get-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -ErrorAction SilentlyContinue
    $enabled=$(if ($existing) {[bool]$existing.automatic} else {$false})
    if ($task) {
        if (@($task.Actions).Count -ne 1 -or -not (Test-ManagedAutomationAction $task.Actions[0] $script:Data)) { throw 'Tâche OPi5 personnalisée détectée. La vérifier avant la reprise par Moonshine.' }
        if (-not $existing) { $enabled=[bool]$task.Settings.Enabled }
        $backup=Join-Path $script:Data 'Recovery\moonshine-previous-task.xml'
        if (-not $existing) {
            Write-AtomicBytes $backup ([Text.Encoding]::UTF8.GetBytes((Export-ScheduledTask -TaskName (Task-Name) -TaskPath '\')))
        } elseif (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
            throw 'Sauvegarde de la tâche précédente absente; reprise automatique suspendue.'
        }
        # Persist intent before disabling the scheduled task; interruption is recoverable.
        Write-Json $marker @{schema='moonshine-takeover/1';state='pending';automatic=$enabled}
        $null=Pause-ResetAutomation
    }
    $pending=Read-Json $marker
    if ($pending -and $pending.state -eq 'pending') { $enabled=[bool]$pending.automatic;$null=Pause-ResetAutomation }
    Write-Json (Join-Path $script:Data 'moonshine-auto.json') @{schema='moonshine-auto/1';enabled=$enabled;interval_minutes=10}
    Write-Json $marker @{schema='moonshine-takeover/1';state='complete';automatic=$enabled}
}
try {
    $line=[Console]::In.ReadLine()
    if ($null -eq $line -or $line.Length -gt 65536) { throw 'Démarrage interne absent ou trop volumineux.' }
    $script:MoonshineBoot=ConvertFrom-Json -InputObject $line -ErrorAction Stop;$line=$null
    if ($script:MoonshineBoot.protocol -ne 'moonshine-worker/1' -or $script:MoonshineBoot.action -notin @('preview','sync','auto','reset','restore','undo','profile','creation_profile','export','enable_auto','disable_auto') -or
        $script:MoonshineBoot.scope -notin @('all','ea','pilot','ea-pilot') -or
        $script:MoonshineBoot.cancel_event -notmatch '^Global\\Moonshine\.Sync\.[a-f0-9]{32}$') { throw 'Commande interne invalide.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Le moteur doit utiliser la session Windows normale, sans élévation.' }
    if ($identity.IsSystem -or $identity.User.Value -cne $script:MoonshineBoot.user_sid) { throw 'Le moteur ne correspond pas au compte Windows sélectionné.' }
    $script:EmbeddedCancel=[Threading.EventWaitHandle]::OpenExisting([string]$script:MoonshineBoot.cancel_event)
    . (Join-Path $PSScriptRoot 'VibeShine-Xbox.ps1') -FunctionsOnly
    . (Join-Path $PSScriptRoot 'Bootstrap.ps1') -FunctionsOnly
    if ([string]$script:MoonshineBoot.trial_id -cne [string](Get-MoonshineTrialId)) { throw 'Le moteur ne correspond pas au contexte d essai selectionne.' }
    $script:Unattended=$script:MoonshineBoot.action -eq 'auto'
    Validate-Connection @{url=$script:MoonshineBoot.url;pin=$script:MoonshineBoot.pin}
    if ([string]$script:MoonshineBoot.token -match '[\r\n\x00]' -or ([string]$script:MoonshineBoot.token).Length -lt 16 -or ([string]$script:MoonshineBoot.token).Length -gt 512) { throw 'Jeton interne invalide.' }
    $script:Connection=@{url=[string]$script:MoonshineBoot.url;pin=[string]$script:MoonshineBoot.pin}
    $script:Authorization='Bearer '+[string]$script:MoonshineBoot.token;$script:MoonshineBoot.token=$null
    [IO.Directory]::CreateDirectory($script:Data) | Out-Null
    $bootstrapLock=[IO.File]::Open((Join-Path $script:Data 'bootstrap.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if (-not (Package-Valid $PSScriptRoot)) { throw 'Moteur embarqué incomplet; réinstaller les fichiers Moonshine.' }
        Import-LegacyData $script:Data (Legacy-DataRoot)
        $hashes=Package-Hashes $PSScriptRoot
        $null=Repair-PackageTree $PSScriptRoot $script:Runtime $hashes (Join-Path $script:Data 'Recovery')
        $null=Repair-PackageTree $PSScriptRoot (Join-Path (Join-Path $script:Data 'Packages') $script:Version) $hashes (Join-Path $script:Data 'Recovery')
        Set-MoonshineTrialMarkers $script:Runtime
        Set-MoonshineTrialMarkers (Join-Path (Join-Path $script:Data 'Packages') $script:Version)
    } finally { $bootstrapLock.Dispose() }
    $script:MoonshineLock=[IO.File]::Open((Join-Path $script:Data 'sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if (Test-Path -LiteralPath (Legacy-DataRoot)) { $script:MoonshineOldLock=[IO.File]::Open((Join-Path (Legacy-DataRoot) 'sync.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    Emit-Moonshine 'progress' @{message='Vérification du moteur et des données locales…';percent=-1}
    $script:SelfTestStatus='running';$script:SelfTestCount=Invoke-SelfTests;$script:SelfTestStatus='passed'
    $script:Repairs.Clear();$script:AtomicWriteEvents.Clear();$script:AtomicRetained.Clear()
    $script:StreamProfiles=Load-StreamProfiles
    $script:CreationStreamMode=$(if ($script:MoonshineBoot.action -eq 'creation_profile') {'unmanaged'} else {Read-CreationStreamMode})
    Migrate-LegacyAutomation
    Takeover-MoonshineAutomation
    Operation-Checkpoint
    $script:MoonshinePhase='running'
    switch ([string]$script:MoonshineBoot.action) {
        'preview' { Show-Preview }
        {$_ -in @('sync','auto')} {
            switch ([string]$script:MoonshineBoot.scope) {
                'pilot' { Sync-Games $true }
                'ea' { Sync-Games $false $false $true }
                'ea-pilot' { Sync-Games $false $true }
                default { Sync-Games $false }
            }
        }
        'reset' { Reset-ManagedGames }
        'restore' { Undo-ManagedReset }
        'undo' { Undo-LastSync }
        'profile' {
            if ($script:MoonshineBoot.game_id -notmatch '^706c6f73-7862-8[a-f0-9]{3}-8[a-f0-9]{3}-[a-f0-9]{12}$' -or $script:MoonshineBoot.mode -notin @('game-provided','off','unmanaged')) { throw 'Jeu ou profil invalide.' }
            $selected=@((Get-Apps).apps | Where-Object { $_.uuid -eq $script:MoonshineBoot.game_id })
            if ($selected.Count -ne 1) { throw 'Entrée à actualiser avant de changer son profil.' }
            Save-GameStreamProfile $selected[0] $script:MoonshineBoot.mode
            Write-Host 'Profil enregistré. Synchroniser pour appliquer le plan proposé.'
        }
        'creation_profile' {
            Save-CreationStreamMode ([string]$script:MoonshineBoot.mode)
            $script:CreationStreamMode=Read-CreationStreamMode
            Write-Host 'Préréglage de création enregistré. Les fiches existantes conservent leurs réglages.'
        }
        'export' { $null=Export-Return }
        'enable_auto' {
            $null=Test-UndoAllowsSync $false
            if (-not (Test-ResetAllowsSync $true)) { throw 'Réimport manuel requis après la remise à zéro.' }
            if ((Read-Host 'Après validation des lancements, taper ACTIVER') -ceq 'ACTIVER') {
                $null=Pause-ResetAutomation
                Write-Json (Join-Path $script:Data 'moonshine-auto.json') @{schema='moonshine-auto/1';enabled=$true;interval_minutes=10}
                Write-Host 'Synchronisation Moonshine activée : session et toutes les dix minutes.'
            }
        }
        'disable_auto' {
            Write-Json (Join-Path $script:Data 'moonshine-auto.json') @{schema='moonshine-auto/1';enabled=$false;interval_minutes=10}
            Write-Host 'Synchronisation automatique Moonshine désactivée.'
        }
    }
    if (-not $script:LastInventory) { $script:LastInventory=Read-InventoryCache }
    # Recompute the display against the actual catalog after an applied change.
    if ($script:LastInventory -and $script:MoonshinePhase -ne 'declined') {
        $state=Load-State;$root=Get-Apps
        $displayGames=@($script:LastInventory.ready)
        switch ([string]$script:MoonshineBoot.scope) {
            'pilot' { $displayGames=@(Pilot-Games $displayGames) }
            'ea' { $displayGames=@(EA-SelectGames $displayGames $false) }
            'ea-pilot' { $displayGames=@(EA-SelectGames $displayGames $true) }
        }
        $script:LastPlan=@(Build-Plan $displayGames $root.apps $state $script:Runtime $script:Data)
    }
    Publish-MoonshineSnapshot;Save-Report
    Emit-Moonshine 'complete' @{message=$(if ($script:MoonshinePhase -eq 'declined') {'Confirmation refusée; aucune application du plan.'} elseif ($script:SyncOutcome) {$script:SyncOutcome} else {'Opération terminée et état relu.'})}
} catch {
    $failure=$_;$cause=$failure.Exception;while ($cause.InnerException) { $cause=$cause.InnerException }
    if ($cause -is [OperationCanceledException]) { Emit-Moonshine 'cancelled' @{message='Opération annulée à un point de reprise sûr.'} }
    else {
        try { Record-Error $failure;Save-Report } catch { }
        $message=$failure.Exception.Message
        if (Get-Command Redact -ErrorAction SilentlyContinue) { $message=Redact $message }
        Emit-Moonshine 'error' @{message=$message}
    }
    exit 1
} finally {
    $script:Authorization='';if ($script:MoonshineBoot) { $script:MoonshineBoot.token=$null }
    if ($script:EmbeddedCancel) { $script:EmbeddedCancel.Dispose() }
    if ($script:MoonshineOldLock) { $script:MoonshineOldLock.Dispose() };if ($script:MoonshineLock) { $script:MoonshineLock.Dispose() }
    if ($script:MoonshineChannel) { $script:MoonshineChannel.Dispose() }
}

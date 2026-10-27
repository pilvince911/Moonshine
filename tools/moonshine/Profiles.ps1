#Requires -Version 5.1
$script:StreamProfiles=[ordered]@{schema='opi5-stream-profiles/1';games=[ordered]@{}}
function Test-StreamProfileShape($Root) {
    $map=Field $Root 'games'
    if ((Field $Root 'schema') -ne 'opi5-stream-profiles/1' -or $null -eq $map -or
        -not ($map -is [Collections.IDictionary] -or $map.GetType().FullName -eq 'System.Management.Automation.PSCustomObject')) { return $false }
    foreach ($id in @(Keys $map)) {
        $profile=Field $map $id
        if (-not $profile.key -or $id -ne (Stable-Id $profile.key) -or $profile.mode -notin @('game-provided','off')) { return $false }
    }
    return $true
}
function Read-StreamProfileRoot {
    $path=Join-Path $script:Data 'stream-profiles.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [ordered]@{schema='opi5-stream-profiles/1';games=[ordered]@{}} }
    $root=Read-Json $path
    if (-not (Test-StreamProfileShape $root)) { throw 'Profils de diffusion invalides; fichier conservé, aucune modification automatique des réglages.' }
    return [ordered]@{schema='opi5-stream-profiles/1';games=(To-Map $root.games)}
}
function Resume-StreamProfileCommit([bool]$Recovered=$true) {
    $path=Join-Path $script:Data 'stream-profile-change.json'
    $journal=Read-Json $path
    if ($null -eq $journal) { return }
    if ((Field $journal 'schema') -ne 'opi5-stream-profile-change/1' -or
        -not (Test-StateShape $journal.state_before) -or -not (Test-StateShape $journal.state_after) -or
        -not (Test-StreamProfileShape $journal.profiles_before) -or -not (Test-StreamProfileShape $journal.profiles_after)) { throw 'Journal de changement de profil invalide; aucune synchronisation.' }
    $state=Load-State;$profiles=Read-StreamProfileRoot
    if ((-not (Same $state $journal.state_before) -and -not (Same $state $journal.state_after)) -or
        (-not (Same $profiles $journal.profiles_before) -and -not (Same $profiles $journal.profiles_after))) { throw 'Données modifiées pendant un changement de profil interrompu. Fichiers conservés; joindre le diagnostic.' }
    Save-State (State-Map $journal.state_after)
    Write-Json (Join-Path $script:Data 'stream-profiles.json') $journal.profiles_after
    Write-Json $path $null
    if ($Recovered) { Repair-Event 'stream-profile' 'commit_recovered' 'Choix de profil local terminé après interruption; catalogue VibeShine inchangé.' }
}
function Load-StreamProfiles {
    Resume-StreamProfileCommit
    return Read-StreamProfileRoot
}
function Get-GameStreamFields($Game) {
    $profile=Field $script:StreamProfiles.games $Game.uuid
    if (-not $profile -or $profile.key -ne $Game.key) { return [ordered]@{} }
    return [ordered]@{'frame-generation-mode'=$profile.mode;
        'frame-generation-provider'=$(if ($profile.mode -eq 'game-provided') { 'game-provided' } else { 'lossless-scaling' });
        'lossless-scaling-enabled'=$false;'lossless-scaling-framegen'=$false}
}
function Save-GameStreamProfile($App,[string]$Mode) {
    $null=Test-UndoAllowsSync $false
    $null=Test-ResetAllowsSync $false
    $key=[string](Field $App 'opi5-xbox-key')
    if (-not $key -or -not (Owned $App $key) -or $Mode -notin @('game-provided','off','unmanaged')) { throw 'Profil reserve a une entree OPi5 verifiee et a un mode connu.' }
    $root=Load-StreamProfiles;$beforeRoot=Clone-Object $root
    $state=Load-State;$beforeState=Clone-Object $state
    if (Field $state.pending ([string]$App.uuid)) { throw 'Écriture précédente à vérifier : analyser avant de changer le profil.' }
    if ($Mode -eq 'unmanaged') { $root.games.Remove([string]$App.uuid) }
    else {
        $known=Field $state.managed ([string]$App.uuid)
        if (-not $known -or $known.key -ne $key) { throw 'Synchroniser cette entrée avant de configurer son profil.' }
        # The explicitly selected mode adopts only these four current fields.
        # A journal commits that baseline and the profile together on recovery.
        $record=To-Map $known;$baseline=To-Map $known.fields
        foreach ($name in @('frame-generation-mode','frame-generation-provider','lossless-scaling-enabled','lossless-scaling-framegen')) { $baseline[$name]=Field $App $name }
        $record.fields=$baseline;$state.managed[[string]$App.uuid]=$record
        $root.games[[string]$App.uuid]=@{key=$key;mode=$Mode}
    }
    if ((Same $beforeRoot $root) -and (Same $beforeState $state)) { $script:StreamProfiles=$root;return }
    $path=Join-Path $script:Data 'stream-profiles.json'
    if (Test-Path -LiteralPath $path) { Preserve-RecoveryFile $path 'stream-profile' }
    Write-Json (Join-Path $script:Data 'stream-profile-change.json') @{schema='opi5-stream-profile-change/1';
        state_before=$beforeState;state_after=$state;profiles_before=$beforeRoot;profiles_after=$root}
    Resume-StreamProfileCommit $false
    $script:StreamProfiles=$root
}

function Configure-StreamProfile {
    if ($Unattended) { throw 'Choix de profil reserve au menu interactif.' }
    if (-not $script:Authorization) { throw 'Connecter VibeShine avec le choix 2.' }
    $root=Get-Apps
    $apps=@($root.apps | Where-Object { $key=[string](Field $_ 'opi5-xbox-key');$key -and (Owned $_ $key) } | Sort-Object name)
    if ($apps.Count -eq 0) { Write-Host 'Synchroniser les jeux avec le choix 4 avant de configurer un profil.';return }
    for ($i=0;$i -lt $apps.Count;$i++) { Write-Host (($i+1).ToString()+'  '+$apps[$i].name) }
    $text=Read-Host 'Numero du jeu, ou Entree pour revenir'
    if (-not $text) { return }
    $index=0
    if (-not [int]::TryParse($text,[ref]$index) -or $index -lt 1 -or $index -gt $apps.Count) { throw 'Numero de jeu invalide.' }
    Write-Host '1  Generation d images fournie par le jeu (DLSS/FSR Frame Generation active dans ce jeu)'
    Write-Host '2  Aucune generation d images coordonnee par VibeShine'
    Write-Host '3  Ne plus gerer ce profil; conserver les reglages VibeShine actuels'
    $choice=Read-Host 'Profil, ou Entree pour revenir'
    if (-not $choice) { return }
    $mode=switch ($choice) {
        '1' { 'game-provided' }
        '2' { 'off' }
        '3' { 'unmanaged' }
        default { throw 'Profil invalide.' }
    }
    Write-Host 'Ce profil ne change pas les options graphiques du jeu. DLSS et FG doivent etre actives dans le jeu.'
    Write-Host 'Pour FG : verifier ecran virtuel, capture WGC et RTSS dans le controle de sante VibeShine.'
    if ((Read-Host 'Taper CONFIGURER pour enregistrer ce choix local, ou Entree pour revenir') -cne 'CONFIGURER') { return }
    Save-GameStreamProfile $apps[$index-1] $mode
    Write-Host 'Profil enregistre. Choix 1 pour voir le plan, puis 4 et APPLIQUER pour le synchroniser.' -ForegroundColor Green
}

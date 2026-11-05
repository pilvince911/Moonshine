#Requires -Version 5.1
$script:MoonshineTrialBase=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OPi5\Moonshine-Trial'
function Write-MoonshineTrialAtomic([string]$Path,[byte[]]$Bytes) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,$Path+'.previous') }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Get-MoonshineKitPath([string]$Root,[string]$Relative) {
    if (-not $Relative -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|[:\r\n]|^[\\/]' -or $Relative.IndexOf([char]0) -ge 0) { throw 'Chemin du paquet invalide.' }
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin hors du paquet.' }
    return $full
}
function Read-MoonshineTrialManifest([string]$KitRoot) {
    $path=Join-Path $KitRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 4194304) { throw 'Manifeste du paquet absent ou trop volumineux.' }
    $manifest=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
    if ($manifest.schema -ne 'moonshine-trial-kit/1' -or $manifest.commit -cnotmatch '\A[a-f0-9]{40}\z' -or $manifest.files -isnot [array] -or $manifest.files.Count -gt 20000) { throw 'Format du paquet non reconnu.' }
    $seen=@{}
    foreach ($row in $manifest.files) {
        $file=Get-MoonshineKitPath $KitRoot $row.path
        if ($seen.ContainsKey($file) -or $row.sha256 -cnotmatch '\A[a-f0-9]{64}\z' -or $row.size -lt 0) { throw 'Entree de manifeste invalide.' }
        $seen[$file]=$true
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -ne $row.size -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $row.sha256) { throw ('Fichier du paquet absent ou modifie : '+$row.path+'. Extraire de nouveau le ZIP complet.') }
    }
    foreach ($required in @('Package/sunshine.exe','Package/tools/moonshine/SHA256.txt','Package/moonshine-trial-only.txt','Package/tools/moonshine/moonshine-trial-only.txt')) {
        if (-not $seen.ContainsKey((Get-MoonshineKitPath $KitRoot $required))) { throw ('Paquet incomplet : '+$required) }
    }
    return $manifest
}
function Get-MoonshineTrialInstance([string]$KitRoot) {
    $manifest=Read-MoonshineTrialManifest $KitRoot
    [IO.Directory]::CreateDirectory($script:MoonshineTrialBase) | Out-Null
    $lockPath=Join-Path $script:MoonshineTrialBase 'instances.lock'
    try { $lock=New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'Un autre lanceur prepare un essai. Fermer la seconde fenetre et recommencer.' }
    try {
        $indexPath=Join-Path $script:MoonshineTrialBase 'instances.json';$index=@{}
        if (Test-Path -LiteralPath $indexPath) {
            try {
                $loaded=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($indexPath))
                if ($loaded.schema -ne 'moonshine-trial-instances/1') { throw 'schema' }
                foreach ($property in $loaded.instances.PSObject.Properties) {
                    if ($property.Name -cnotmatch '\A[a-f0-9]{40}\z' -or $property.Value -cnotmatch '\A[a-f0-9]{32}\z') { throw 'identite' }
                    $index[$property.Name]=[string]$property.Value
                }
            } catch {
                Copy-Item -LiteralPath $indexPath -Destination ($indexPath+'.damaged-'+[guid]::NewGuid().ToString('N')) -Force
                throw 'Index des essais illisible; copie de recuperation conservee. Les donnees restent en place.'
            }
        }
        if (-not $index.ContainsKey($manifest.commit)) {
            $index[$manifest.commit]=[guid]::NewGuid().ToString('N')
            $json=ConvertTo-Json -InputObject @{schema='moonshine-trial-instances/1';instances=$index} -Depth 5
            Write-MoonshineTrialAtomic $indexPath ([Text.Encoding]::UTF8.GetBytes($json))
        }
        $id=$index[$manifest.commit];$root=Join-Path $script:MoonshineTrialBase $id
        return @{Id=$id;Root=$root;Package=(Join-Path $root 'Package');KitRoot=[IO.Path]::GetFullPath($KitRoot);Manifest=$manifest;ProcessFile=(Join-Path $root 'host-process.json')}
    } finally { $lock.Dispose() }
}
function Prepare-MoonshineTrialInstance($Instance) {
    # Recheck the extracted source before repairing only the private trial copy.
    $manifest=Read-MoonshineTrialManifest $Instance.KitRoot
    foreach ($row in @($manifest.files | Where-Object { $_.path.StartsWith('Package/') })) {
        $source=Get-MoonshineKitPath $Instance.KitRoot $row.path
        $target=Get-MoonshineKitPath $Instance.Root $row.path
        $current=(Test-Path -LiteralPath $target -PathType Leaf)
        if ($current -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ieq $row.sha256) { continue }
        if ($current) {
            $recovery=Join-Path (Join-Path $Instance.Root ('Recovery\'+[guid]::NewGuid().ToString('N'))) $row.path
            [IO.Directory]::CreateDirectory((Split-Path -Parent $recovery)) | Out-Null
            Copy-Item -LiteralPath $target -Destination $recovery
        }
        $bytes=[IO.File]::ReadAllBytes($source)
        Write-MoonshineTrialAtomic $target $bytes
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $row.sha256) { throw 'Reparation du paquet non verifiee; aucun demarrage.' }
    }
    foreach ($folder in @($Instance.Package,(Join-Path $Instance.Package 'tools\moonshine'))) {
        [IO.File]::WriteAllText((Join-Path $folder 'moonshine-trial-id.txt'),$Instance.Id,[Text.Encoding]::ASCII)
    }
    $config=Join-Path $Instance.Package 'config\moonshine.conf'
    if (-not (Test-Path -LiteralPath $config)) {
        $lines=@('sunshine_name = Moonshine Essai','port = 48989','upnp = disabled','system_tray = disabled','install_steam_audio_drivers = disabled','origin_web_ui_allowed = pc','update_check_interval = 0')
        Write-MoonshineTrialAtomic $config ([Text.Encoding]::UTF8.GetBytes(($lines -join [Environment]::NewLine)))
    }
    return $config
}
function Get-MoonshineOwnedTrialProcess($Instance) {
    if (-not (Test-Path -LiteralPath $Instance.ProcessFile -PathType Leaf)) { return $null }
    try {
        $state=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Instance.ProcessFile))
        if ($state.id -cne $Instance.Id -or $state.pid -isnot [int] -or $state.pid -le 0) { return $null }
        $process=[Diagnostics.Process]::GetProcessById($state.pid)
        if ($process.StartTime.ToUniversalTime().ToString('o') -cne $state.started -or $process.MainModule.FileName -ine (Join-Path $Instance.Package 'sunshine.exe')) { return $null }
        return $process
    } catch { return $null }
}
function Start-MoonshineTrialInstance($Instance) {
    $existing=Get-MoonshineOwnedTrialProcess $Instance
    if ($existing -and -not $existing.HasExited) { return $existing }
    if (@(Get-Process -Name sunshine,vibeshine,Moonshine -ErrorAction SilentlyContinue).Count) { throw 'Un hote VibeShine/Sunshine/Moonshine est encore actif. Terminer le stream et arreter temporairement cet hote dans Services, puis recommencer.' }
    $busy=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -in @(48984,48989,48990,49010) })
    if ($busy.Count) { throw 'Un port de cet essai est deja occupe. Fermer cette instance avant de recommencer.' }
    $config=Prepare-MoonshineTrialInstance $Instance
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $Instance.Package 'sunshine.exe';$start.Arguments='"'+$config+'"';$start.WorkingDirectory=$Instance.Package
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.EnvironmentVariables['MOONSHINE_TRIAL_ID']=$Instance.Id
    $process=[Diagnostics.Process]::Start($start)
    $metadata=@{id=$Instance.Id;pid=$process.Id;started=$process.StartTime.ToUniversalTime().ToString('o')}
    Write-MoonshineTrialAtomic $Instance.ProcessFile ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $metadata)))
    return $process
}
function Request-MoonshineTrialStop($Instance) {
    $process=Get-MoonshineOwnedTrialProcess $Instance
    if (-not $process -or $process.HasExited) { return $false }
    try {
        $event=[Threading.EventWaitHandle]::OpenExisting(('Global\Moonshine.Trial.Stop.'+$Instance.Id),[Security.AccessControl.EventWaitHandleRights]::Modify)
        try { $null=$event.Set();return $true } finally { $event.Dispose() }
    } catch { throw 'L''hote prepare encore son demarrage ou son arret est indisponible. Attendre quelques secondes et recommencer.' }
}

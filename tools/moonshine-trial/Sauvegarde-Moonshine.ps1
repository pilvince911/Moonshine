#Requires -Version 5.1
function Get-MoonshineBackupFiles([string]$Root) {
    if (((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source liée ou redirigée : sauvegarde suspendue.' }
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $queue=New-Object 'Collections.Generic.Queue[string]';$queue.Enqueue($base)
    while ($queue.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $queue.Dequeue() -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Lien ou jonction dans la source : sauvegarde suspendue.' }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
            elseif ($item.Name -notlike '*.lock' -and $item.Name -notlike '*.tmp') { @{relative=$item.FullName.Substring($base.Length);path=$item.FullName;size=$item.Length} }
        }
    }
}
function Backup-MoonshineSource([string]$ConfigFolder,$SyncRoots=$null,[string]$OutputBase='') {
    if (-not (Test-Path -LiteralPath $ConfigFolder -PathType Container) -or
        (-not (Test-Path -LiteralPath (Join-Path $ConfigFolder 'apps.json')) -and -not @(Get-ChildItem -LiteralPath $ConfigFolder -Filter '*.conf' -File).Count)) { throw 'Choisir le dossier config de VibeShine contenant apps.json ou son fichier .conf.' }
    if (-not $OutputBase) { $OutputBase=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OPi5\Moonshine-Trial\Backups' }
    if ($null -eq $SyncRoots) { $SyncRoots=@{sync_current=(Join-Path $env:LOCALAPPDATA 'OPi5\VibeShine-Xbox');sync_legacy=(Join-Path $env:LOCALAPPDATA 'plOS\VibeShine-Xbox')} }
    $roots=[ordered]@{host_config=[IO.Path]::GetFullPath($ConfigFolder)}
    foreach ($name in @($SyncRoots.Keys)) {
        if ($name -notmatch '\Async_[a-z]+\z') { throw 'Nom de source de sauvegarde invalide.' }
        if (Test-Path -LiteralPath $SyncRoots[$name] -PathType Container) { $roots[$name]=[IO.Path]::GetFullPath($SyncRoots[$name]) }
    }
    $outputFull=[IO.Path]::GetFullPath($OutputBase).TrimEnd('\')+'\'
    foreach ($root in @($roots.Values)) { if ($outputFull.StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Le dossier de sauvegarde doit être hors des sources.' } }
    $destination=Join-Path $OutputBase ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $rows=@();$bytes=0L
    foreach ($name in @($roots.Keys)) {
        foreach ($file in @(Get-MoonshineBackupFiles $roots[$name])) {
            $bytes+=$file.size
            if ($rows.Count -ge 20000 -or $bytes -gt 1073741824) { throw 'Sauvegarde trop volumineuse; originaux conservés.' }
            $rows+=@{source=$name;relative=$file.relative;original=$file.path;sha256=(Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash.ToLowerInvariant();size=$file.size}
        }
    }
    foreach ($row in $rows) {
        $copy=Join-Path (Join-Path (Join-Path $destination 'Files') $row.source) $row.relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $copy)) | Out-Null
        [IO.File]::WriteAllBytes($copy,[IO.File]::ReadAllBytes($row.original))
        if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ine $row.sha256) { throw 'Source modifiée pendant la copie; sauvegarde non certifiée.' }
    }
    foreach ($name in @($roots.Keys)) {
        $after=@(Get-MoonshineBackupFiles $roots[$name]);$before=@($rows | Where-Object { $_.source -eq $name })
        if ($after.Count -ne $before.Count) { throw 'La source a changé pendant la sauvegarde; recommencer après la fin de la synchronisation.' }
        foreach ($row in $before) { if (-not (Test-Path -LiteralPath $row.original) -or (Get-FileHash -LiteralPath $row.original -Algorithm SHA256).Hash -ine $row.sha256) { throw 'Source modifiée pendant la vérification; sauvegarde non certifiée.' } }
    }
    $manifest=@{schema='moonshine-backup/1';complete=$true;created=(Get-Date).ToString('o');machine=$env:COMPUTERNAME;user_sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;roots=$roots;files=@($rows);bytes=$bytes}
    [IO.File]::WriteAllText((Join-Path $destination 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 8),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $destination 'LIRE-MOI.txt'),'Sauvegarde privée vérifiée. Garder les certificats et identifiants sur ce PC. Restore-MoonshineBackup prépare un dossier neuf sans écraser les originaux.')
    return $destination
}
function Restore-MoonshineBackup([string]$BackupFolder,[string]$Destination) {
    $manifest=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $BackupFolder 'manifest.json')))
    if ($manifest.schema -ne 'moonshine-backup/1' -or $manifest.complete -ne $true -or $manifest.files -isnot [array] -or $manifest.files.Count -gt 20000) { throw 'Sauvegarde non certifiée.' }
    if (Test-Path -LiteralPath $Destination) { throw 'La préparation de restauration exige un dossier neuf; aucun écrasement.' }
    $seen=@{}
    foreach ($row in $manifest.files) {
        if ($row.source -notmatch '\A(host_config|sync_[a-z]+)\z' -or -not $row.relative -or $row.relative -match '(^|[\\/])\.\.([\\/]|$)|[\r\n:]|^[\\/]' -or $row.sha256 -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Entrée de sauvegarde invalide.' }
        $key=$row.source+'/'+$row.relative
        if ($seen.ContainsKey($key)) { throw 'Entrée de sauvegarde dupliquée.' };$seen[$key]=$true
        $file=Join-Path (Join-Path (Join-Path $BackupFolder 'Files') $row.source) $row.relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $row.sha256) { throw 'Sauvegarde modifiée ou incomplète; aucune restauration préparée.' }
    }
    foreach ($row in $manifest.files) {
        $source=Join-Path (Join-Path (Join-Path $BackupFolder 'Files') $row.source) $row.relative
        $target=Join-Path (Join-Path $Destination $row.source) $row.relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        [IO.File]::WriteAllBytes($target,[IO.File]::ReadAllBytes($source))
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $row.sha256) { throw 'Préparation de restauration incomplète; originaux conservés.' }
    }
    [IO.File]::WriteAllText((Join-Path $Destination 'emplacements-originaux.json'),(ConvertTo-Json -InputObject $manifest.roots -Depth 4))
    return $Destination
}

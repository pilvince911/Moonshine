#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# No downloaded or installed script is dot-sourced by this maintenance tool.
function Assert-MMSingleFile([string]$Path) {
    if (-not ('MoonshineMaintenanceFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MoonshineMaintenanceFile {
    [StructLayout(LayoutKind.Sequential)] struct Info {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
    public static void Check(string path) {
        using (var stream = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
            Info info;
            if (!GetFileInformationByHandle(stream.SafeFileHandle,out info) || info.Links!=1)
                throw new IOException("Fichier lie ou identite de fichier inconnue; originaux conserves: "+path);
        }
    }
}
'@
    }
    [MoonshineMaintenanceFile]::Check($Path)
}
function Assert-MMPlainPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or $Path -match '[\r\n]') { throw 'Un chemin local absolu est requis.' }
    $item=[IO.Path]::GetFullPath($Path)
    while ($item) {
        if (Test-Path -LiteralPath $item) {
            if ((Get-Item -LiteralPath $item -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Lien ou jonction refuse : '+$item) }
        }
        $parent=Split-Path -Parent $item
        if ($parent -eq $item) { break };$item=$parent
    }
}
function Read-MMJson([string]$Path,[long]$Limit=4194304) {
    Assert-MMPlainPath $Path
    if (-not [IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path).Length -gt $Limit) { throw ('Fichier absent ou trop volumineux : '+$Path) }
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
}
function Write-MMJson([string]$Path,$Value) {
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 30),(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,$Path+'.previous') }
        else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Set-MMPrivateDirectory([string]$Path) {
    Assert-MMPlainPath $Path;[IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Protect-MMArchivedTree([string]$Root) {
    Set-MMPrivateDirectory $Root
    $pending=New-Object 'Collections.Generic.Queue[string]';$pending.Enqueue($Root)
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Un lien est apparu dans l archive. Verification manuelle requise.' }
            if ($item.PSIsContainer) { Set-MMPrivateDirectory $item.FullName;$pending.Enqueue($item.FullName);continue }
            $acl=New-Object Security.AccessControl.FileSecurity
            Assert-MMSingleFile $item.FullName
            $acl.SetAccessRuleProtection($true,$false)
            foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
                $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','Allow')))
            }
            $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
            Set-Acl -LiteralPath $item.FullName -AclObject $acl
        }
    }
}
function Get-MMContext([string]$OwnerSid) {
    if ($OwnerSid -cnotmatch '\AS-1-(?:5-21|12-1)-[0-9-]+\z') { throw 'Compte Windows invalide.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Ouvrir le fichier CMD et accepter la confirmation Windows.' }
    $profile=(Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$OwnerSid) -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
    $profile=[Environment]::ExpandEnvironmentVariables($profile);Assert-MMPlainPath $profile
    return @{OwnerSid=$OwnerSid;Profile=$profile;Local=(Join-Path $profile 'AppData\Local');ProgramFiles=[Environment]::GetFolderPath('ProgramFiles');BackupBase=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Moonshine-Migration')}
}
function Get-MMTree([string]$Root) {
    Assert-MMPlainPath $Root
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $pending=New-Object 'Collections.Generic.Queue[string]';$pending.Enqueue($Root)
    $files=New-Object 'Collections.Generic.List[object]';$bytes=0L
    while ($pending.Count) {
        $directory=$pending.Dequeue();Assert-MMPlainPath $directory
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Lien ou jonction refuse : '+$item.FullName) }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName);continue }
            # Cooperative locks are held separately, never copied as live files.
            if ($item.Name -in @('sync.lock','bootstrap.lock')) { continue }
            Assert-MMSingleFile $item.FullName
            $bytes+=$item.Length
            if ($files.Count -ge 50000 -or $bytes -gt 4294967296) { throw 'Dossier trop volumineux pour ce kit (4 Gio / 50 000 fichiers). Originaux conserves.' }
            $files.Add([pscustomobject]@{path=$item.FullName.Substring($prefix.Length);size=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()})
        }
    }
    return @($files.ToArray() | Sort-Object path)
}
function Test-MMTreeEqual($Left,$Right) {
    return (ConvertTo-Json -InputObject @($Left) -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @($Right) -Depth 6 -Compress)
}
function Copy-MMVerifiedTree([string]$Source,[string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { throw 'La destination de sauvegarde existe deja.' }
    $before=@(Get-MMTree $Source);[IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($row in $before) {
        $from=Join-Path $Source $row.path;$to=Join-Path $Destination $row.path
        Assert-MMPlainPath $from;Assert-MMPlainPath $to
        [IO.Directory]::CreateDirectory((Split-Path -Parent $to)) | Out-Null
        [IO.File]::Copy($from,$to,$false)
    }
    if (-not (Test-MMTreeEqual $before @(Get-MMTree $Destination)) -or -not (Test-MMTreeEqual $before @(Get-MMTree $Source))) { throw 'Des fichiers ont change pendant la copie. Aucun retrait autorise.' }
    return @($before)
}
function Test-MMTrial([string]$Root,[string]$Id) {
    if ($Id -cnotmatch '\A[a-f0-9]{32}\z') { return $false }
    try {
        foreach ($relative in @('Package\moonshine-trial-id.txt','Package\tools\moonshine\moonshine-trial-id.txt')) {
            $path=Join-Path $Root $relative;Assert-MMPlainPath $path
            if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 128 -or [IO.File]::ReadAllText($path).Trim() -cne $Id) { return $false }
        }
        return $true
    } catch { return $false }
}
function Test-MMLegacyRoot([string]$Root) {
    try {
        foreach ($name in @('state.json','state.last-good.json')) {
            if (-not [IO.File]::Exists((Join-Path $Root $name))) { continue }
            $state=Read-MMJson (Join-Path $Root $name)
            if ($state.schema -in @('opi5-xbox-state/1','plos-xbox-state/1') -and $null -ne $state.managed) { return $true }
        }
    } catch { }
    return $false
}
function Test-MMPreviewReceipt($Receipt,[string]$OwnerSid) {
    return $Receipt.schema -ceq 'moonshine-service-receipt/1' -and $Receipt.name -ceq 'MoonshineService' -and $Receipt.owner_sid -ceq $OwnerSid -and $Receipt.id -cmatch '\A[a-f0-9]{32}\z' -and $Receipt.commit -cmatch '\A[a-f0-9]{40}\z'
}
function Get-MMCandidates($Context) {
    $items=New-Object 'Collections.Generic.List[object]'
    foreach ($relative in @('OPi5\VibeShine-Xbox','plOS\VibeShine-Xbox')) {
        $path=Join-Path $Context.Local $relative
        if (Test-Path -LiteralPath $path) { $items.Add([pscustomobject]@{path=$path;kind='synchroniseur';known=(Test-MMLegacyRoot $path);id='';sync=$path}) }
    }
    $base=Join-Path $Context.Local 'OPi5\Moonshine-Trial';Assert-MMPlainPath $base
    if (Test-Path -LiteralPath $base) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction Stop)) {
            if ($folder.Name -cnotmatch '\A[a-f0-9]{32}\z') { continue }
            $items.Add([pscustomobject]@{path=$folder.FullName;kind='essai portable';known=(Test-MMTrial $folder.FullName $folder.Name);id=$folder.Name;sync=(Join-Path $folder.FullName 'Sync')})
        }
    }
    $preview=Join-Path $Context.ProgramFiles 'Moonshine-Preview'
    if (Test-Path -LiteralPath $preview) {
        $known=$false;$id=''
        try {
            $receipt=Read-MMJson (Join-Path $preview 'service-receipt.json')
            $known=Test-MMPreviewReceipt $receipt $Context.OwnerSid;$id=[string]$receipt.id
        } catch { }
        $items.Add([pscustomobject]@{path=$preview;kind='service 0.9';known=$known;id=$id;sync=''})
    }
    return $items.ToArray()
}
function Get-MMServiceExecutable([string]$CommandLine) {
    $match=[regex]::Match($CommandLine,'\A\s*"(?<path>[A-Za-z]:[^"\r\n]+\.exe)"(?:\s|\z)')
    if ($match.Success) { return [IO.Path]::GetFullPath($match.Groups['path'].Value) }
    $match=[regex]::Match($CommandLine,'\A(?<path>[A-Za-z]:[^\s"\r\n]+\.exe)(?:\s|\z)')
    if ($match.Success) { return [IO.Path]::GetFullPath($match.Groups['path'].Value) }
    return ''
}
function Get-MMReferences($Context) {
    $references=New-Object 'Collections.Generic.List[object]';$catalogues=New-Object 'Collections.Generic.List[string]'
    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -in @('MoonshineService','SunshineService') })) {
        $executable=Get-MMServiceExecutable ([string]$service.PathName)
        if (-not $executable) { $references.Add(@{text='';source=('Service non reconnu : '+$service.Name);unknown=$true});continue }
        $references.Add(@{text=$executable;source=('Service installe : '+$service.Name);unknown=$false})
        $folder=Split-Path -Parent $executable
        if ([IO.Path]::GetFileName($folder) -ieq 'tools') { $folder=Split-Path -Parent $folder }
        $config=Join-Path $folder 'config';$catalogues.Add($config)
    }
    foreach ($config in @($catalogues.ToArray() | Select-Object -Unique)) {
        $found=$false
        foreach ($name in @('apps.json','moonshine.conf','sunshine.conf','moonshine-service-profile.json')) {
            $path=Join-Path $config $name
            if (-not [IO.File]::Exists($path)) { continue }
            $found=$true;Assert-MMPlainPath $path
            if ((Get-Item -LiteralPath $path).Length -gt 16777216) { throw 'Un catalogue est trop volumineux pour analyser ses dependances.' }
            $text=[IO.File]::ReadAllText($path)
            # JSON text doubles backslashes; inspect both forms without evaluating it.
            $references.Add(@{text=$text.Replace('\\','\').Replace('\/','/');source=$path;unknown=$false})
            if ($name -in @('moonshine.conf','sunshine.conf') -and $text -match '(?m)^\s*file_apps\s*=') { $references.Add(@{text='';source=('Catalogue personnalise : '+$path);unknown=$true}) }
        }
        if (-not $found) { $references.Add(@{text='';source=('Profil introuvable : '+$config);unknown=$true}) }
    }
    # The 0.9 receipt binds the live user data even before its first synchronization.
    $preview=Join-Path $Context.ProgramFiles 'Moonshine-Preview'
    $receiptPath=Join-Path $preview 'service-receipt.json'
    if ([IO.File]::Exists($receiptPath)) {
        $receipt=Read-MMJson $receiptPath
        if ((Test-MMPreviewReceipt $receipt $Context.OwnerSid) -and $receipt.phase -ne 'removed') {
            $references.Add(@{text=(Join-Path $Context.Local ('OPi5\Moonshine-Trial\'+$receipt.id));source='Donnees encore utilisees par le service 0.9';unknown=$false})
        }
    }
    return $references.ToArray()
}
function Test-MMTask($Task,[string]$Data,[string]$OwnerSid) {
    if ($Task.TaskPath -cne '\' -or @($Task.Actions).Count -ne 1 -or $Task.State -eq 'Running') { return $false }
    try {
        $account=New-Object Security.Principal.NTAccount([string]$Task.Principal.UserId)
        $taskSid=if ([string]$Task.Principal.UserId -match '^S-1-') { [string]$Task.Principal.UserId } else { $account.Translate([Security.Principal.SecurityIdentifier]).Value }
        if ($taskSid -cne $OwnerSid) { return $false }
    } catch { return $false }
    $action=@($Task.Actions)[0]
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ([string]$action.Execute -ine $powershell) { return $false }
    $match=[regex]::Match([string]$action.Arguments,'\A-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "(?<script>[^"\r\n]+)" -Action SyncAll -Unattended\z',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $false }
    $prefix=[IO.Path]::GetFullPath($Data).TrimEnd('\')+'\';$scriptPath=[IO.Path]::GetFullPath($match.Groups['script'].Value)
    if (-not $scriptPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $relative=$scriptPath.Substring($prefix.Length)
    $version=[regex]::Match($relative,'\A(?<tree>versions|packages)\\(?<version>\d+\.\d+\.\d+)\\(?<file>vibeshine-xbox|bootstrap)\.ps1\z',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $version.Success -or ($version.Groups['tree'].Value -ieq 'packages' -and $version.Groups['file'].Value -ine 'bootstrap')) { return $false }
    if ($action.WorkingDirectory -and [IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\') -ine (Join-Path $Data ('versions\'+$version.Groups['version'].Value))) { return $false }
    return $true
}
function Get-MMTasks($Context,$Candidates) {
    $result=New-Object 'Collections.Generic.List[object]'
    $installed=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop)
    $definitions=@(@{name=('OPi5-VibeShine-Xbox-'+$Context.OwnerSid);data=(Join-Path $Context.Local 'OPi5\VibeShine-Xbox')},@{name=('plOS-VibeShine-Xbox-'+$Context.OwnerSid);data=(Join-Path $Context.Local 'plOS\VibeShine-Xbox')})
    foreach ($item in $Candidates) { if ($item.kind -eq 'essai portable') { $definitions+=@(@{name=('Moonshine-Trial-'+$item.id);data=$item.sync}) } }
    foreach ($definition in $definitions) {
        $task=@($installed | Where-Object { $_.TaskName -ieq $definition.name })
        if ($task.Count -gt 1) { throw 'Identite de tache ambigue.' }
        if ($task.Count -eq 1) { $task=$task[0] } else { $task=$null }
        if ($task) { $result.Add(@{name=$definition.name;data=$definition.data;known=(Test-MMTask $task $definition.data $Context.OwnerSid);xml=(Export-ScheduledTask -TaskName $definition.name -TaskPath '\' -ErrorAction Stop)}) }
    }
    return $result.ToArray()
}
function Get-MMPlan($Candidates,$References,$Tasks) {
    foreach ($candidate in $Candidates) {
        $reasons=New-Object 'Collections.Generic.List[string]'
        if (-not $candidate.known) { $reasons.Add('Identite inconnue : conservation') }
        $needle=[IO.Path]::GetFullPath($candidate.path).TrimEnd('\').Replace('/','\')
        foreach ($reference in $References) {
            if ($reference.unknown -or ([string]$reference.text).Replace('/','\').IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $reasons.Add([string]$reference.source) }
        }
        foreach ($task in $Tasks) {
            if ([string]$task.data -and ([IO.Path]::GetFullPath($task.data)+'\').StartsWith($needle+'\',[StringComparison]::OrdinalIgnoreCase) -and -not $task.known) { $reasons.Add('Tache personnalisee ou active : '+$task.name) }
        }
        [pscustomobject]@{path=$candidate.path;kind=$candidate.kind;known=$candidate.known;sync=$candidate.sync;removable=($reasons.Count -eq 0);reason=($reasons -join '; ')}
    }
}
function Assert-MMIdle {
    $services=@(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -in @('MoonshineService','SunshineService') -and $_.State -ne 'Stopped' })
    if ($services.Count) { throw 'Arreter les services Moonshine et VibeShine depuis leurs fenetres avant de sauvegarder ou nettoyer.' }
    $active=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -in @('sunshine.exe','vibeshine.exe','moonshine.exe','sunshine_display_helper.exe') -or
        ($_.Name -in @('powershell.exe','pwsh.exe') -and [string]$_.CommandLine -match '(?i)(Moonshine-Worker|Launch-Game|VibeShine-Xbox|Bootstrap|Desktop|GuiEngine)\.ps1')
    })
    if ($active.Count) { throw 'Quitter les streams et fermer les anciens synchroniseurs. Arreter Moonshine depuis sa fenetre et VibeShine depuis Services avant de sauvegarder ou nettoyer.' }
}
function Get-MMLocks($Candidates) {
    $locks=New-Object 'Collections.Generic.List[object]'
    try {
        foreach ($candidate in $Candidates) {
            if (-not $candidate.known -or -not $candidate.sync -or -not [IO.Directory]::Exists($candidate.sync)) { continue }
            foreach ($name in @('bootstrap.lock','sync.lock')) {
                $path=Join-Path $candidate.sync $name;Assert-MMPlainPath $path
                if ([IO.File]::Exists($path)) { Assert-MMSingleFile $path }
                $locks.Add([IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))
            }
        }
        return ,$locks
    } catch { foreach ($held in $locks) { $held.Dispose() };throw 'Un synchroniseur utilise encore ces donnees. Aucun retrait autorise.' }
}
function New-MMBackup($Context,$Candidates,$Plan,$Tasks) {
    if (@($Candidates | Where-Object { $_.known }).Count -eq 0) { throw 'Aucun dossier reconnu a sauvegarder. Aucun retrait autorise.' }
    Set-MMPrivateDirectory $Context.BackupBase
    $root=Join-Path $Context.BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    Set-MMPrivateDirectory $root
    $record=@{schema='moonshine-migration-backup/1';owner_sid=$Context.OwnerSid;created=(Get-Date).ToString('o');phase='copying';roots=@();plan=@($Plan);tasks=@();changes=@();vibeshine_uninstalled=$false;drivers_modified=$false}
    Write-MMJson (Join-Path $root 'backup.json') $record
    $i=0
    foreach ($candidate in $Candidates) {
        # An unknown directory is never traversed, copied or removed.
        if (-not $candidate.known) { continue }
        $key='root-'+$i.ToString('000');$i++
        $destination=Join-Path $root $key
        $files=@(Copy-MMVerifiedTree $candidate.path $destination)
        $record.roots+=@(@{source=$candidate.path;key=$key;kind=$candidate.kind;files=$files})
        Write-MMJson (Join-Path $root 'backup.json') $record
    }
    foreach ($task in $Tasks) {
        $file='task-'+$record.tasks.Count.ToString('000')+'.xml'
        [IO.File]::WriteAllText((Join-Path $root $file),[string]$task.xml,(New-Object Text.UTF8Encoding($false)))
        $record.tasks+=@(@{name=$task.name;data=$task.data;known=$task.known;file=$file;sha256=(Get-FileHash -LiteralPath (Join-Path $root $file)).Hash.ToLowerInvariant()})
    }
    $record.phase='verified';Write-MMJson (Join-Path $root 'backup.json') $record
    return @{root=$root;record=$record}
}
function Move-MMVerifiedRoot($Entry,[string]$BackupRoot) {
    $copy=Join-Path $BackupRoot $Entry.key
    if (-not (Test-MMTreeEqual @($Entry.files) @(Get-MMTree $copy)) -or -not (Test-MMTreeEqual @($Entry.files) @(Get-MMTree $Entry.source))) { throw 'La source ou sa sauvegarde a change. Retrait suspendu.' }
    $archive=Join-Path $BackupRoot ('archive-'+$Entry.key)
    if (Test-Path -LiteralPath $archive) { throw 'Archive deja presente; aucun ecrasement.' }
    # Atomically move the directory itself. Never recursively delete a user tree.
    [IO.Directory]::Move($Entry.source,$archive)
    Protect-MMArchivedTree $archive
    if (-not (Test-MMTreeEqual @($Entry.files) @(Get-MMTree $archive))) { throw 'L archive a change apres deplacement. La copie de sauvegarde verifiee reste disponible.' }
    return $archive
}
function Invoke-MMCleanup($Context,$Candidates,$Plan,$Tasks,$Backup) {
    foreach ($entry in $Backup.record.roots) {
        $row=@($Plan | Where-Object { $_.path -ceq $entry.source -and $_.removable })
        if ($row.Count -ne 1) { continue }
        # Re-read installed service/catalogue references immediately before every move.
        $current=@(Get-MMPlan $Candidates @(Get-MMReferences $Context) @(Get-MMTasks $Context $Candidates) | Where-Object { $_.path -ceq $entry.source -and $_.removable })
        if ($current.Count -ne 1) { throw 'Une dependance est apparue depuis l apercu. Originaux restants conserves.' }
        foreach ($task in $Tasks) {
            if (-not $task.known -or -not ([IO.Path]::GetFullPath($task.data)+'\').StartsWith(([IO.Path]::GetFullPath($entry.source).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { continue }
            $live=Get-ScheduledTask -TaskName $task.name -TaskPath '\' -ErrorAction Stop
            $xml=Export-ScheduledTask -TaskName $task.name -TaskPath '\' -ErrorAction Stop
            if (-not (Test-MMTask $live $task.data $Context.OwnerSid) -or $xml -cne $task.xml) { throw 'Une tache a change depuis la sauvegarde. Retrait suspendu.' }
            $saved=@($Backup.record.tasks | Where-Object { $_.name -ceq $task.name })
            if ($saved.Count -ne 1 -or (Get-FileHash -LiteralPath (Join-Path $Backup.root $saved[0].file)).Hash -ine $saved[0].sha256) { throw 'Sauvegarde de la tache non verifiee. Retrait suspendu.' }
            Unregister-ScheduledTask -TaskName $task.name -TaskPath '\' -Confirm:$false -ErrorAction Stop
            $Backup.record.changes+=@(@{action='task-removed';name=$task.name});Write-MMJson (Join-Path $Backup.root 'backup.json') $Backup.record
        }
        Assert-MMIdle
        $Backup.record.phase='archiving'
        $Backup.record.changes+=@(@{action='directory-archive-prepared';source=$entry.source;archive=(Join-Path $Backup.root ('archive-'+$entry.key))})
        Write-MMJson (Join-Path $Backup.root 'backup.json') $Backup.record
        $archive=Move-MMVerifiedRoot $entry $Backup.root
        $Backup.record.changes+=@(@{action='directory-archived';source=$entry.source;archive=$archive})
        Write-MMJson (Join-Path $Backup.root 'backup.json') $Backup.record
    }
    $Backup.record.phase='completed';Write-MMJson (Join-Path $Backup.root 'backup.json') $Backup.record
}

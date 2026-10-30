#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
$script:MoonshineUninstallKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Moonshine'
function Get-MoonshineManagerCommand([switch]$Uninstall) {
    $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $manager=Join-Path $script:MoonshineServiceRoot $(if($Uninstall){'Kit\Desinstaller-Moonshine.ps1'}else{'Kit\Gestion-Moonshine.ps1'})
    return ('"'+$ps+'" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$manager+'"'+$(if ($Uninstall) {''} else {' -TrayOnly'}))
}
function Get-MoonshineDesktopRegistration {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    $key=$null
    try {
        $key=$base.OpenSubKey($script:MoonshineUninstallKey)
        if (-not $key) { return $null }
        $values=@{};foreach ($name in $key.GetValueNames()) { $values[$name]=$key.GetValue($name) }
        return $values
    } finally { if ($key) {$key.Dispose()};$base.Dispose() }
}
function Assert-MoonshineDesktopRegistration($Receipt) {
    $values=Get-MoonshineDesktopRegistration
    if ($values -and ($values.MoonshineSchema -cne 'moonshine-desktop/1' -or $values.MoonshineId -cne $Receipt.id -or $values.MoonshineOwner -cne $Receipt.owner_sid -or $values.InstallLocation -ine $script:MoonshineServiceRoot -or $values.UninstallString -cne (Get-MoonshineManagerCommand -Uninstall))) { throw 'Une autre inscription Windows porte le nom Moonshine. Elle est conservee.' }
}
function Get-MoonshineStartupCommand([string]$OwnerSid) {
    $key=[Microsoft.Win32.Registry]::Users.OpenSubKey($OwnerSid+'\Software\Microsoft\Windows\CurrentVersion\Run')
    try { if ($key) { return [string]$key.GetValue('Moonshine','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) };return '' }
    finally { if ($key) {$key.Dispose()} }
}
function Assert-MoonshineStartupCommand([string]$OwnerSid) {
    $value=Get-MoonshineStartupCommand $OwnerSid
    if ($value -and $value -cne (Get-MoonshineManagerCommand)) { throw 'Un autre demarrage de session porte le nom Moonshine. Il est conserve.' }
}
function Register-MoonshineDesktop($Receipt) {
    Assert-MoonshineAdmin;Assert-MoonshineDesktopRegistration $Receipt;Assert-MoonshineStartupCommand $Receipt.owner_sid
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    $key=$null;$user=$null;$run=$null
    try {
        $key=$base.CreateSubKey($script:MoonshineUninstallKey)
        $values=@{DisplayName='Moonshine';DisplayVersion=[string]$Receipt.version;Publisher='Moonshine project';InstallLocation=$script:MoonshineServiceRoot;DisplayIcon=(Join-Path $script:MoonshineServiceRoot 'Kit\Moonshine.ico');UninstallString=(Get-MoonshineManagerCommand -Uninstall);URLInfoAbout='https://github.com/pilvince911/Moonshine';MoonshineSchema='moonshine-desktop/1';MoonshineId=$Receipt.id;MoonshineOwner=$Receipt.owner_sid}
        foreach ($name in $values.Keys) { $key.SetValue($name,[string]$values[$name],[Microsoft.Win32.RegistryValueKind]::String) }
        foreach ($name in @('NoModify','NoRepair')) { $key.SetValue($name,1,[Microsoft.Win32.RegistryValueKind]::DWord) }
        # The selected interactive account, even when UAC used another administrator.
        $user=[Microsoft.Win32.Registry]::Users.OpenSubKey($Receipt.owner_sid,$true)
        if (-not $user) { throw 'Le compte Windows selectionne doit etre connecte pour enregistrer son icone.' }
        $run=$user.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
        $run.SetValue('Moonshine',(Get-MoonshineManagerCommand),[Microsoft.Win32.RegistryValueKind]::String)
    } finally { if ($run) {$run.Dispose()};if ($user) {$user.Dispose()};if ($key) {$key.Dispose()};$base.Dispose() }
}
function Unregister-MoonshineDesktop($Receipt) {
    Assert-MoonshineAdmin;Assert-MoonshineDesktopRegistration $Receipt;Assert-MoonshineStartupCommand $Receipt.owner_sid
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    $run=$null
    try {
        if (Get-MoonshineDesktopRegistration) { $base.DeleteSubKeyTree($script:MoonshineUninstallKey,$false) }
        $run=[Microsoft.Win32.Registry]::Users.OpenSubKey($Receipt.owner_sid+'\Software\Microsoft\Windows\CurrentVersion\Run',$true)
        $live=Get-MoonshineStartupCommand $Receipt.owner_sid
        if ($run -and $live) { if($live -cne (Get-MoonshineManagerCommand)){throw 'Le demarrage de session a change pendant le retrait.'};$run.DeleteValue('Moonshine',$false) }
        $path=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Moonshine.lnk'
        if ([IO.File]::Exists($path)) {
            Assert-MoonshinePlainPath $path;$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($path)
            if ($link.TargetPath -ieq (Join-Path $script:MoonshineServiceRoot 'Kit\Ouvrir-Moonshine.cmd') -and -not $link.Arguments) { [IO.File]::Delete($path) }
        }
    } finally { if ($run) {$run.Dispose()};$base.Dispose() }
}
function Get-MoonshineOperationFolder([string]$OwnerSid,[string]$OperationId) {
    if ($OwnerSid -cnotmatch '\AS-1-(?:5-21|12-1)-[0-9-]+\z' -or $OperationId -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Identite d operation invalide.' }
    return Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ('Moonshine-Operations\'+$OwnerSid+'\'+$OperationId)
}
function Initialize-MoonshineOperation([string]$OwnerSid,[string]$OperationId) {
    Assert-MoonshineAdmin
    $folder=Get-MoonshineOperationFolder $OwnerSid $OperationId;Assert-MoonshinePlainPath $folder
    $root=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine-Operations';Set-MoonshineProtectedFolder $root
    foreach ($path in @((Split-Path -Parent $folder),$folder)) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
        $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))) }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($OwnerSid)),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')));Set-Acl -LiteralPath $path -AclObject $acl
    }
    return $folder
}
function Write-MoonshineOperation([string]$Folder,[string]$OwnerSid,[string]$Id,[string]$Action,[string]$Phase,[int]$Percent,[string]$Message,$Result=$null) {
    Write-MoonshineServiceJson (Join-Path $Folder 'operation.json') @{schema='moonshine-operation/1';id=$Id;owner_sid=$OwnerSid;action=$Action;phase=$Phase;percent=$Percent;message=$Message;time=(Get-Date).ToString('o');result=$Result}
}
function Backup-MoonshineInstalled([string]$OwnerSid) {
    Assert-MoonshineAdmin;Assert-MoonshineSetupIdle
    $receipt=Read-MoonshineServiceReceipt
    if ($receipt.owner_sid -cne $OwnerSid) { throw 'Cette installation appartient a un autre compte.' }
    $paths=Get-MoonshineOwnerPaths $OwnerSid
    $parent=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Moonshine-Recovery';Set-MoonshineProtectedFolder $parent -Private
    $root=Join-Path $parent ('Backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    Set-MoonshineProtectedFolder $root -Private
    Copy-MoonshinePrivateTree (Join-Path $script:MoonshineServiceRoot 'Package\config') (Join-Path $root 'config')
    $data=Join-Path $paths.Local ('Moonshine\Library\'+$receipt.id)
    if ([IO.Directory]::Exists($data)) { Copy-MoonshineLibraryData $data (Join-Path $root 'library') }
    Write-MoonshineServiceJson (Join-Path $root 'backup.json') @{schema='moonshine-installed-backup/1';id=$receipt.id;owner_sid=$OwnerSid;commit=$receipt.commit;complete=$true;source=$script:MoonshineServiceRoot}
    return @{path=$root;verified=$true}
}
function Uninstall-MoonshineInstalled([string]$OwnerSid) {
    Assert-MoonshineAdmin;Assert-MoonshineSetupIdle
    $receipt=Read-MoonshineServiceReceipt
    if ($receipt.owner_sid -cne $OwnerSid -or $receipt.mode -cne 'installed') { throw 'Installation non reconnue pour ce compte.' }
    $null=Get-MoonshineOwnedService
    Assert-MoonshineDesktopRegistration $receipt;Assert-MoonshineStartupCommand $OwnerSid
    $backup=Backup-MoonshineInstalled $OwnerSid
    Write-MoonshineServiceJson (Join-Path $backup.path 'uninstall.json') @{schema='moonshine-uninstall/1';id=$receipt.id;phase='prepared';source=$script:MoonshineServiceRoot}
    Remove-MoonshineService
    Unregister-MoonshineDesktop $receipt
    foreach($layer in @(@{view=[Microsoft.Win32.RegistryView]::Registry64;file='VkLayer_sunshine_hdr.json'},@{view=[Microsoft.Win32.RegistryView]::Registry32;file='VkLayer_sunshine_hdr_x86.json'})) {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$layer.view);$key=$null
        try {
            $key=$base.OpenSubKey('SOFTWARE\Khronos\Vulkan\ImplicitLayers',$true)
            $manifest=[IO.Path]::GetFullPath((Join-Path $script:MoonshineServiceRoot ('Package\drivers\sunshine\vulkan-layer\'+$layer.file)))
            if($key){foreach($name in $key.GetValueNames()){if([IO.Path]::IsPathRooted($name) -and [IO.Path]::GetFullPath($name) -ieq $manifest){$key.DeleteValue($name,$false)}}}
        } finally {if($key){$key.Dispose()};$base.Dispose()}
    }
    # Moving the owned root preserves all user-added files. No recursive deletion.
    Assert-MoonshinePlainPath $script:MoonshineServiceRoot
    $archive=Join-Path $backup.path 'program'
    [IO.Directory]::Move($script:MoonshineServiceRoot,$archive)
    Write-MoonshineServiceJson (Join-Path $backup.path 'uninstall.json') @{schema='moonshine-uninstall/1';id=$receipt.id;phase='completed';source=$script:MoonshineServiceRoot;program_archive=$archive;library_preserved=$true;drivers_preserved=$true}
    return @{path=$backup.path;program_archived=$true;library_preserved=$true;drivers_preserved=$true}
}
function Export-MoonshineSetupDiagnostic([string]$OwnerSid,[string]$Folder) {
    Assert-MoonshineAdmin
    $receipt=Read-MoonshineServiceReceipt
    if ($receipt.owner_sid -cne $OwnerSid) { throw 'Compte different de celui de l installation.' }
    $paths=Get-MoonshineOwnerPaths $OwnerSid
    $stage=Join-Path $Folder 'diagnostic';[IO.Directory]::CreateDirectory($stage) | Out-Null
    $service=Get-MoonshineOwnedService
    Write-MoonshineServiceJson (Join-Path $stage 'status.json') @{version=$receipt.version;commit=$receipt.commit;service_state=$(if($service){$service.State}else{'absent'});data_mode='installed';os=[Environment]::OSVersion.Version.ToString();powershell=$PSVersionTable.PSVersion.ToString()}
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:MoonshineServiceRoot 'Package\config') -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
        if ($file.Length -gt 2097152) { $lines=@(Get-Content -LiteralPath $file.FullName -Tail 2000) } else { $lines=@(Get-Content -LiteralPath $file.FullName) }
        $safe=@(foreach ($line in $lines) {
            if ($line -match '(?i)password|token|authorization|cookie|secret|private.key') { '[ligne sensible retiree]';continue }
            $value=[regex]::Replace([string]$line,[regex]::Escape($paths.Profile),'%USERPROFILE%',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $value=[regex]::Replace($value,[regex]::Escape($env:COMPUTERNAME),'%COMPUTERNAME%',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $value=[regex]::Replace($value,'\b(?:\d{1,3}\.){3}\d{1,3}\b','[adresse IP]')
            $value
        })
        [IO.File]::WriteAllLines((Join-Path $stage $file.Name),[string[]]$safe,(New-Object Text.UTF8Encoding($false)))
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=Join-Path $Folder 'diagnostic.zip';[IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
    return @{file='diagnostic.zip';contains_credentials=$false}
}

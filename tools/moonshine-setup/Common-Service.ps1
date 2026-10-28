#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
$script:MoonshineServiceName='MoonshineService'
$script:MoonshineServiceRoot=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine'
function Assert-MoonshineAdmin {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Cette opération de service demande la confirmation Windows administrateur.' }
}
function Assert-MoonshinePlainPath([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Un lien de répertoire est présent. Extraire le kit dans un dossier local ordinaire.' }
        }
        $parent=Split-Path -Parent $current
        if ($parent -eq $current) { break };$current=$parent
    }
}
function Set-MoonshineProtectedFolder([string]$Path,[switch]$Private) {
    Assert-MoonshinePlainPath $Path
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    if (-not $Private) {
        $users=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-MoonshineServiceJson([string]$Path,$Value) {
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 60 -Compress),(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,$Path+'.previous') }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Get-MoonshineServiceKitPath([string]$Root,[string]$Relative) {
    if (-not $Relative -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|[:\r\n]|^[\\/]' -or $Relative.IndexOf([char]0) -ge 0) { throw 'Chemin du manifeste invalide.' }
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\';$path=[IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $path.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fichier hors du kit.' }
    Assert-MoonshinePlainPath $path;return $path
}
function Read-MoonshineServiceManifest([string]$KitRoot) {
    $path=Get-MoonshineServiceKitPath $KitRoot 'manifest.json'
    if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 4194304) { throw 'Manifeste absent ou trop volumineux.' }
    $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path));$seen=@{}
    if ($value.mode -cne 'installed' -or $value.schema -cne 'moonshine-service-kit/1' -or $value.commit -cnotmatch '\A[a-f0-9]{40}\z' -or $value.files -isnot [array] -or $value.files.Count -gt 20000) { throw 'Kit de service invalide.' }
    foreach ($row in $value.files) {
        $file=Get-MoonshineServiceKitPath $KitRoot $row.path
        if ($seen.ContainsKey($file) -or $row.sha256 -cnotmatch '\A[a-f0-9]{64}\z' -or $row.size -lt 0) { throw 'Entrée du manifeste invalide.' }
        $seen[$file]=$true
        if (-not [IO.File]::Exists($file) -or (Get-Item -LiteralPath $file).Length -ne $row.size -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $row.sha256) { throw ('Kit incomplet ou modifié : '+$row.path) }
    }
    foreach ($required in @('Package/sunshine.exe','Package/tools/sunshinesvc.exe','Package/tools/moonshine/SHA256.txt','Package/moonshine-service-only.txt','Installation.ps1','Common-Service.ps1','Action.ps1','Gestion-Moonshine.ps1','Pilotes.ps1','Ouvrir-Moonshine.cmd','Launcher.xaml','Package/drivers/provenance.json')) {
        if (-not $seen.ContainsKey((Get-MoonshineServiceKitPath $KitRoot $required))) { throw ('Fichier requis absent : '+$required) }
    }
    if (@($value.files | Where-Object { $_.path -match '^Package/config/' -or $_.path -match 'moonshine-(?:trial-(?:only|id)|install-id)\.txt$' }).Count) { throw 'Le paquet source contient un profil personnel ou des marqueurs de l''ancien kit.' }
    return $value
}
function Copy-MoonshinePrivateTree([string]$Source,[string]$Target) {
    $script:MoonshineCopyBytes=0L;$script:MoonshineCopyFiles=0
    function Copy-PrivateDirectory([string]$From,[string]$To) {
        Assert-MoonshinePlainPath $From;[IO.Directory]::CreateDirectory($To) | Out-Null
        foreach ($item in @(Get-ChildItem -LiteralPath $From -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien détecté dans le profil; copie suspendue.' }
            $destination=Join-Path $To $item.Name
            if ($item.PSIsContainer) { Copy-PrivateDirectory $item.FullName $destination;continue }
            $script:MoonshineCopyBytes+=$item.Length;$script:MoonshineCopyFiles++
            if ($script:MoonshineCopyBytes -gt 536870912 -or $script:MoonshineCopyFiles -gt 20000) { throw 'Profil trop volumineux pour une copie automatique.' }
            Copy-Item -LiteralPath $item.FullName -Destination $destination
            if ((Get-FileHash -LiteralPath $item.FullName).Hash -cne (Get-FileHash -LiteralPath $destination).Hash) { throw 'La copie privée ne correspond pas au profil source.' }
        }
    }
    Copy-PrivateDirectory $Source $Target
}
function Read-MoonshineServiceReceipt {
    $path=Join-Path $script:MoonshineServiceRoot 'service-receipt.json';Assert-MoonshinePlainPath $path
    if (-not [IO.File]::Exists($path)) { throw 'Reçu du service absent; aucune modification de service existant.' }
    if ((Get-Item -LiteralPath $path).Length -gt 4194304) { throw 'Reçu du service trop volumineux; installation conservée.' }
    $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
    if ($value.schema -cne 'moonshine-service-receipt/1' -or $value.name -cne $script:MoonshineServiceName -or $value.id -cnotmatch '\A[a-f0-9]{32}\z' -or $value.commit -cnotmatch '\A[a-f0-9]{40}\z' -or $value.files -isnot [array] -or $value.files.Count -lt 4 -or $value.owner_sid -cnotmatch '\AS-1-(?:5-21|12-1)-[0-9-]+\z' -or $value.firewall_created -isnot [bool]) { throw 'Reçu de service invalide.' }
    foreach ($row in $value.files) { if (-not $row.path.StartsWith('Package/') -or $row.sha256 -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Empreintes du service invalides.' } }
    return $value
}
function Save-MoonshineServiceReceipt($Receipt) { Write-MoonshineServiceJson (Join-Path $script:MoonshineServiceRoot 'service-receipt.json') $Receipt }
function Get-MoonshineOwnedService {
    $service=Get-CimInstance Win32_Service -Filter "Name='MoonshineService'"
    if ($service) {
        $expected='"'+(Join-Path $script:MoonshineServiceRoot 'Package\tools\sunshinesvc.exe')+'"'
        if ($service.PathName.Trim() -cne $expected -or $service.StartName -notin @('LocalSystem','NT AUTHORITY\SYSTEM')) { throw 'Un autre service utilise le nom MoonshineService. Aucune modification.' }
    }
    return $service
}
function Assert-MoonshineInstalledPackage($Receipt) {
    foreach ($folder in @('Package','Package/tools/moonshine')) {
        $marker=Get-MoonshineServiceKitPath $script:MoonshineServiceRoot ($folder+'/moonshine-install-id.txt')
        if (-not [IO.File]::Exists($marker) -or (Get-Item -LiteralPath $marker).Length -gt 128 -or [IO.File]::ReadAllText($marker).Trim() -cne $Receipt.id) { throw 'Identifiant installé incohérent; démarrage suspendu.' }
    }
    $serviceIdentity=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $script:MoonshineServiceRoot 'Package\moonshine-service-profile.json')))
    if ($serviceIdentity.mode -cne 'installed' -or $serviceIdentity.schema -cne 'moonshine-service-preview/1' -or $serviceIdentity.id -cne $Receipt.id -or $serviceIdentity.owner_sid -cne $Receipt.owner_sid) { throw 'Le profil du service ne correspond pas au reçu.' }
    foreach ($row in $Receipt.files) {
        $path=Get-MoonshineServiceKitPath $script:MoonshineServiceRoot $row.path
        if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path).Hash -ine $row.sha256) { throw ('Fichier installé modifié; démarrage suspendu : '+$row.path) }
    }
}
function Save-MoonshineServiceKit([string]$KitRoot,$Manifest) {
    $cache=Join-Path $script:MoonshineServiceRoot 'Kit'
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    foreach ($row in $Manifest.files) {
        $source=Get-MoonshineServiceKitPath $KitRoot $row.path;$target=Get-MoonshineServiceKitPath $cache $row.path
        if ([IO.File]::Exists($target) -and (Get-FileHash -LiteralPath $target).Hash -ieq $row.sha256) { continue }
        if ([IO.File]::Exists($target)) {
            $copy=Get-MoonshineServiceKitPath (Join-Path $script:MoonshineServiceRoot ('Recovery\kit-'+[guid]::NewGuid().ToString('N'))) $row.path
            [IO.Directory]::CreateDirectory((Split-Path -Parent $copy)) | Out-Null;Copy-Item -LiteralPath $target -Destination $copy
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        if ((Get-FileHash -LiteralPath $target).Hash -ine $row.sha256) { throw 'Copie de récupération du kit non vérifiée.' }
    }
    $sourceManifest=Join-Path ([IO.Path]::GetFullPath($KitRoot)) 'manifest.json';$targetManifest=Join-Path $cache 'manifest.json'
    if ($sourceManifest -ine $targetManifest) { Copy-Item -LiteralPath $sourceManifest -Destination $targetManifest -Force }
    $null=Read-MoonshineServiceManifest $cache
}
function Repair-MoonshineServicePackage([string]$KitRoot,$Receipt) {
    $manifest=Read-MoonshineServiceManifest $KitRoot
    $service=Get-MoonshineOwnedService
    if ($service -and $service.State -ne 'Stopped') { throw 'Arrêter le service avant la réparation.' }
    if ($manifest.commit -cne $Receipt.commit) { throw 'La réparation demande exactement le kit de cette version.' }
    foreach ($name in @('repair_start_mode','repair_delayed')) {
        if ($name -notin @($Receipt.PSObject.Properties.Name)) { Add-Member -InputObject $Receipt -NotePropertyName $name -NotePropertyValue $null }
    }
    if ($Receipt.phase -ne 'repairing') {
        $Receipt.repair_start_mode=if ($service) { $service.StartMode } else { 'Manual' }
        $key='HKLM:\SYSTEM\CurrentControlSet\Services\MoonshineService'
        $Receipt.repair_delayed=[bool]((Get-ItemProperty -LiteralPath $key -Name DelayedAutoStart -ErrorAction SilentlyContinue).DelayedAutoStart -eq 1)
        $Receipt.phase='repairing';Save-MoonshineServiceReceipt $Receipt
    }
    # An interrupted repair must not autostart a partially repaired executable.
    if ($service) { Set-Service -Name $script:MoonshineServiceName -StartupType Manual }
    $recovery=Join-Path $script:MoonshineServiceRoot ('Recovery\repair-'+[guid]::NewGuid().ToString('N'))
    foreach ($row in $Receipt.files) {
        $reference=@($manifest.files | Where-Object { $_.path -ceq $row.path -and $_.sha256 -ceq $row.sha256 })
        if ($reference.Count -ne 1) { throw 'Le manifeste ne correspond pas au reçu; réparation suspendue.' }
        $target=Get-MoonshineServiceKitPath $script:MoonshineServiceRoot $row.path
        if ([IO.File]::Exists($target) -and (Get-FileHash -LiteralPath $target).Hash -ieq $row.sha256) { continue }
        if ([IO.File]::Exists($target)) {
            $backup=Get-MoonshineServiceKitPath $recovery $row.path
            [IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
            Copy-Item -LiteralPath $target -Destination $backup
        }
        $source=Get-MoonshineServiceKitPath $KitRoot $row.path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        if ((Get-FileHash -LiteralPath $target).Hash -ine $row.sha256) { throw 'Copie de réparation non vérifiée; service laissé en démarrage manuel.' }
    }
    Assert-MoonshineInstalledPackage $Receipt
    if ($service) {
        switch ($Receipt.repair_start_mode) {
            'Auto' { Set-Service -Name $script:MoonshineServiceName -StartupType Automatic;Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\MoonshineService' -Name DelayedAutoStart -Value ([int][bool]$Receipt.repair_delayed) }
            'Disabled' { Set-Service -Name $script:MoonshineServiceName -StartupType Disabled }
            default { Set-Service -Name $script:MoonshineServiceName -StartupType Manual }
        }
    }
    $Receipt.phase='installed';$Receipt.repair_start_mode=$null;$Receipt.repair_delayed=$null;Save-MoonshineServiceReceipt $Receipt
}
function Start-MoonshineService {
    Assert-MoonshineAdmin;$receipt=Read-MoonshineServiceReceipt;$service=Get-MoonshineOwnedService
    if (-not $service) { throw 'Service Moonshine non installé.' }
    if ($receipt.phase -eq 'repairing') { throw 'Une réparation interrompue doit être terminée avec Installer / réparer avant le démarrage.' }
    Assert-MoonshineInstalledPackage $receipt
    if ($service.State -eq 'Running') { return }
    if (@(Get-Process -Name sunshine,vibeshine,Moonshine -ErrorAction SilentlyContinue).Count) { throw 'Un autre hôte est actif. L''arrêter avant de démarrer Moonshine.' }
    $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -in @(48984,48989,48990,49010) })
    if ($listeners.Count) { throw 'Un port de l''essai est déjà occupé.' }
    $rule='Moonshine-'+$receipt.id
    $networkRule=Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
    if ($networkRule) {
        if (@($networkRule).Count -ne 1) { throw 'Identité de règle réseau ambiguë.' }
        $application=Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $networkRule
        $addresses=Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $networkRule
        $remote=@($addresses.RemoteAddress)
        if ($application.Program -ine (Join-Path $script:MoonshineServiceRoot 'Package\sunshine.exe') -or [string]$networkRule.Profile -ne 'Private' -or [string]$networkRule.Direction -ne 'Inbound' -or [string]$networkRule.Action -ne 'Allow' -or [string]$networkRule.Enabled -ne 'True' -or $remote.Count -ne 1 -or $remote[0] -ne 'LocalSubnet') { throw 'Règle réseau personnalisée détectée; aucune modification automatique.' }
    } else {
        New-NetFirewallRule -Name $rule -DisplayName 'Moonshine — réseau local privé' -Direction Inbound -Action Allow -Profile Private -Program (Join-Path $script:MoonshineServiceRoot 'Package\sunshine.exe') -RemoteAddress LocalSubnet | Out-Null
    }
    $receipt.firewall_created=$true;Save-MoonshineServiceReceipt $receipt
    Start-Service -Name $script:MoonshineServiceName
    $controller=Get-Service -Name $script:MoonshineServiceName
    try { $controller.WaitForStatus('Running',[TimeSpan]::FromSeconds(30)) } finally { $controller.Dispose() }
    $receipt.phase='running';Save-MoonshineServiceReceipt $receipt
}
function Stop-MoonshineService {
    Assert-MoonshineAdmin;$receipt=Read-MoonshineServiceReceipt;$service=Get-MoonshineOwnedService
    if ($service -and $service.State -ne 'Stopped') {
        Stop-Service -Name $script:MoonshineServiceName
        $controller=Get-Service -Name $script:MoonshineServiceName
        try { $controller.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45)) } finally { $controller.Dispose() }
    }
    $receipt.phase='stopped';Save-MoonshineServiceReceipt $receipt
}
function Remove-MoonshineService([switch]$ReturnToVibeShine) {
    Assert-MoonshineAdmin;Stop-MoonshineService;$receipt=Read-MoonshineServiceReceipt
    if (Get-MoonshineOwnedService) {
        & "$env:WINDIR\System32\sc.exe" delete $script:MoonshineServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Retrait du service refusé; fichiers et sauvegardes conservés.' }
    }
    if ($receipt.firewall_created) {
        $rule='Moonshine-'+$receipt.id
        $network=Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
        if ($network) {
            $application=Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $network
            if ($application.Program -ine (Join-Path $script:MoonshineServiceRoot 'Package\sunshine.exe')) { throw 'Regle reseau personnalisee conservee.' }
            $network | Remove-NetFirewallRule
        }
        $receipt.firewall_created=$false
    }
    $receipt.phase='removed';Save-MoonshineServiceReceipt $receipt
    if ($ReturnToVibeShine -and $receipt.legacy) {
        $legacy=Get-CimInstance Win32_Service -Filter "Name='SunshineService'"
        if (-not $legacy -or $legacy.PathName -cne $receipt.legacy.path) { throw 'L''ancien service a changé depuis la sauvegarde. Le vérifier dans Services avant de le démarrer.' }
        Start-Service -Name 'SunshineService'
    }
}

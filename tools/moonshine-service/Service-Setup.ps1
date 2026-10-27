#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
$script:MoonshineServiceName='MoonshineService'
$script:MoonshineServiceRoot=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine-Preview'
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
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 20),(New-Object Text.UTF8Encoding($false)))
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
    if ($value.schema -cne 'moonshine-service-kit/1' -or $value.commit -cnotmatch '\A[a-f0-9]{40}\z' -or $value.files -isnot [array] -or $value.files.Count -gt 20000) { throw 'Kit de service invalide.' }
    foreach ($row in $value.files) {
        $file=Get-MoonshineServiceKitPath $KitRoot $row.path
        if ($seen.ContainsKey($file) -or $row.sha256 -cnotmatch '\A[a-f0-9]{64}\z' -or $row.size -lt 0) { throw 'Entrée du manifeste invalide.' }
        $seen[$file]=$true
        if (-not [IO.File]::Exists($file) -or (Get-Item -LiteralPath $file).Length -ne $row.size -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $row.sha256) { throw ('Kit incomplet ou modifié : '+$row.path) }
    }
    foreach ($required in @('Package/sunshine.exe','Package/tools/sunshinesvc.exe','Package/tools/moonshine/SHA256.txt','Package/moonshine-service-only.txt')) {
        if (-not $seen.ContainsKey((Get-MoonshineServiceKitPath $KitRoot $required))) { throw ('Fichier requis absent : '+$required) }
    }
    if (@($value.files | Where-Object { $_.path -match '^Package/config/' -or $_.path -match 'moonshine-trial-(only|id)\.txt$' }).Count) { throw 'Le paquet source contient un profil personnel ou des marqueurs de l''ancien kit.' }
    return $value
}
function Get-MoonshineServiceTrial([string]$OwnerSid,[string]$TrialId) {
    if ($OwnerSid -cnotmatch '\AS-1-(?:5-21|12-1)-[0-9-]+\z' -or $TrialId -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Compte ou identifiant de l''essai invalide.' }
    $profile=(Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$OwnerSid) -Name ProfileImagePath).ProfileImagePath
    $profile=[Environment]::ExpandEnvironmentVariables($profile);Assert-MoonshinePlainPath $profile
    $root=Join-Path $profile ('AppData\Local\OPi5\Moonshine-Trial\'+$TrialId);Assert-MoonshinePlainPath $root
    $package=Join-Path $root 'Package'
    foreach ($folder in @($package,(Join-Path $package 'tools\moonshine'))) {
        $marker=Join-Path $folder 'moonshine-trial-id.txt'
        if (-not [IO.File]::Exists($marker) -or (Get-Item -LiteralPath $marker).Length -gt 128 -or [IO.File]::ReadAllText($marker).Trim() -cne $TrialId) { throw 'L''essai sélectionné ne correspond pas à ce compte Windows.' }
    }
    $config=Join-Path $package 'config\moonshine.conf'
    if (-not [IO.File]::Exists($config) -or (Get-Item -LiteralPath $config).Length -gt 1048576) { throw 'Configuration de l''essai absente.' }
    $text=[IO.File]::ReadAllText($config)
    if ($text -match '(?m)^\s*(pkey|cert|file_state|vibeshine_file_state|credentials_file|file_apps|log_path)\s*=') { throw 'Des chemins de configuration personnalisés nécessitent une migration distincte. Les fichiers existants sont conservés.' }
    return @{Root=$root;Package=$package;Config=$config;OwnerSid=$OwnerSid;Id=$TrialId}
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
    if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 65536) { throw 'Reçu du service absent; aucune modification de service existant.' }
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
        $marker=Get-MoonshineServiceKitPath $script:MoonshineServiceRoot ($folder+'/moonshine-trial-id.txt')
        if (-not [IO.File]::Exists($marker) -or (Get-Item -LiteralPath $marker).Length -gt 128 -or [IO.File]::ReadAllText($marker).Trim() -cne $Receipt.id) { throw 'Identifiant installé incohérent; démarrage suspendu.' }
    }
    $profile=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $script:MoonshineServiceRoot 'Package\moonshine-service-profile.json')))
    if ($profile.schema -cne 'moonshine-service-preview/1' -or $profile.id -cne $Receipt.id -or $profile.owner_sid -cne $Receipt.owner_sid) { throw 'Le profil du service ne correspond pas au reçu.' }
    foreach ($row in $Receipt.files) {
        $path=Get-MoonshineServiceKitPath $script:MoonshineServiceRoot $row.path
        if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path).Hash -ine $row.sha256) { throw ('Fichier installé modifié; démarrage suspendu : '+$row.path) }
    }
}
function Install-MoonshineService([string]$KitRoot,[string]$OwnerSid,[string]$TrialId) {
    Assert-MoonshineAdmin
    $manifest=Read-MoonshineServiceManifest $KitRoot
    $source=Get-MoonshineServiceTrial $OwnerSid $TrialId
    $existing=Get-MoonshineOwnedService
    if (@(Get-Process -Name sunshine,vibeshine,Moonshine -ErrorAction SilentlyContinue).Count) { throw 'Terminer le stream et arrêter l''hôte actif avant l''installation. Pour l''essai portable, utiliser son bouton Arrêter.' }
    $receiptPath=Join-Path $script:MoonshineServiceRoot 'service-receipt.json'
    if (Test-Path -LiteralPath $script:MoonshineServiceRoot) {
        $receipt=Read-MoonshineServiceReceipt
        if ($receipt.owner_sid -cne $OwnerSid -or $receipt.id -cne $TrialId -or $receipt.commit -cne $manifest.commit) { throw 'Une autre installation Moonshine est conservée ici. Aucun écrasement.' }
        Assert-MoonshineInstalledPackage $receipt
        if (-not $existing) { New-Service -Name $script:MoonshineServiceName -DisplayName 'Moonshine — essai service' -BinaryPathName ('"'+(Join-Path $script:MoonshineServiceRoot 'Package\tools\sunshinesvc.exe')+'"') -StartupType Manual | Out-Null }
        return $receipt
    }
    if ($existing) { throw 'Service existant sans reçu; installation suspendue.' }
    $finalRoot=$script:MoonshineServiceRoot
    $stage=$finalRoot+'.Stage.'+[guid]::NewGuid().ToString('N')
    $script:MoonshineServiceRoot=$stage
    try {
    Set-MoonshineProtectedFolder $script:MoonshineServiceRoot
    $private=Join-Path $script:MoonshineServiceRoot 'Recovery';Set-MoonshineProtectedFolder $private -Private
    $package=Join-Path $script:MoonshineServiceRoot 'Package';[IO.Directory]::CreateDirectory($package) | Out-Null
    $config=Join-Path $package 'config';Set-MoonshineProtectedFolder $config -Private
    # Snapshot the stopped profile before registering any executable with SCM.
    Copy-MoonshinePrivateTree (Join-Path $source.Package 'config') (Join-Path $private 'trial-config')
    Copy-MoonshinePrivateTree (Join-Path $private 'trial-config') $config
    if (Test-Path -LiteralPath (Join-Path $source.Root 'Sync')) { Copy-MoonshinePrivateTree (Join-Path $source.Root 'Sync') (Join-Path $private 'trial-sync') }
    $files=@($manifest.files | Where-Object { $_.path.StartsWith('Package/') })
    foreach ($row in $files) {
        $from=Get-MoonshineServiceKitPath $KitRoot $row.path;$to=Get-MoonshineServiceKitPath $script:MoonshineServiceRoot $row.path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $to)) | Out-Null
        Copy-Item -LiteralPath $from -Destination $to
        if ((Get-FileHash -LiteralPath $to).Hash -ine $row.sha256) { throw 'Copie du programme non vérifiée; aucun service enregistré.' }
    }
    foreach ($folder in @($package,(Join-Path $package 'tools\moonshine'))) { [IO.File]::WriteAllText((Join-Path $folder 'moonshine-trial-id.txt'),$TrialId,[Text.Encoding]::ASCII) }
    Write-MoonshineServiceJson (Join-Path $package 'moonshine-service-profile.json') @{schema='moonshine-service-preview/1';id=$TrialId;owner_sid=$OwnerSid}
    # Explicit virtual display policy; the driver's existing installation is reused.
    $lines=[IO.File]::ReadAllText((Join-Path $config 'moonshine.conf'))
    $names='sunshine_name|port|virtual_display_mode|virtual_display_layout|upnp|system_tray|install_steam_audio_drivers|origin_web_ui_allowed|update_check_interval'
    $lines=[regex]::Replace($lines,'(?m)^\s*(?:'+$names+')\s*=.*(?:\r?\n|$)','')
    $lines+="`r`nsunshine_name = Moonshine Essai`r`nport = 48989`r`nvirtual_display_mode = per_client`r`nvirtual_display_layout = exclusive`r`nupnp = disabled`r`nsystem_tray = disabled`r`ninstall_steam_audio_drivers = disabled`r`norigin_web_ui_allowed = pc`r`nupdate_check_interval = 0`r`n"
    [IO.File]::WriteAllText((Join-Path $config 'moonshine.conf'),$lines,(New-Object Text.UTF8Encoding($false)))
    $legacy=Get-CimInstance Win32_Service -Filter "Name='SunshineService'"
    $receipt=@{schema='moonshine-service-receipt/1';name=$script:MoonshineServiceName;owner_sid=$OwnerSid;id=$TrialId;commit=$manifest.commit;phase='prepared';files=$files;firewall_created=$false;legacy=$null}
    if ($legacy) { $receipt.legacy=@{name='SunshineService';path=$legacy.PathName;start_mode=$legacy.StartMode} }
    Save-MoonshineServiceReceipt $receipt
    # Publish the verified tree only when every private copy is complete.
    [IO.Directory]::Move($stage,$finalRoot)
    } finally { $script:MoonshineServiceRoot=$finalRoot }
    $package=Join-Path $finalRoot 'Package'
    New-Service -Name $script:MoonshineServiceName -DisplayName 'Moonshine — essai service' -BinaryPathName ('"'+(Join-Path $package 'tools\sunshinesvc.exe')+'"') -StartupType Manual | Out-Null
    $null=Get-MoonshineOwnedService
    $receipt.phase='installed';Save-MoonshineServiceReceipt $receipt
    return $receipt
}
function Start-MoonshineService {
    Assert-MoonshineAdmin;$receipt=Read-MoonshineServiceReceipt;$service=Get-MoonshineOwnedService
    if (-not $service) { throw 'Service Moonshine non installé.' }
    Assert-MoonshineInstalledPackage $receipt
    if ($service.State -eq 'Running') { return }
    if (@(Get-Process -Name sunshine,vibeshine,Moonshine -ErrorAction SilentlyContinue).Count) { throw 'Un autre hôte est actif. L''arrêter avant de démarrer Moonshine.' }
    $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -in @(48984,48989,48990,49010) })
    if ($listeners.Count) { throw 'Un port de l''essai est déjà occupé.' }
    $rule='MoonshineServicePreview-'+$receipt.id
    if (-not $receipt.firewall_created) {
        if (Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue) { throw 'Règle réseau existante non reconnue; aucune modification.' }
        New-NetFirewallRule -Name $rule -DisplayName 'Moonshine essai service — réseau local privé' -Direction Inbound -Action Allow -Profile Private -Program (Join-Path $script:MoonshineServiceRoot 'Package\sunshine.exe') -RemoteAddress LocalSubnet | Out-Null
        $receipt.firewall_created=$true;Save-MoonshineServiceReceipt $receipt
    }
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
        $rule='MoonshineServicePreview-'+$receipt.id
        Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        $receipt.firewall_created=$false
    }
    $receipt.phase='removed';Save-MoonshineServiceReceipt $receipt
    if ($ReturnToVibeShine -and $receipt.legacy) {
        $legacy=Get-CimInstance Win32_Service -Filter "Name='SunshineService'"
        if (-not $legacy -or $legacy.PathName -cne $receipt.legacy.path) { throw 'L''ancien service a changé depuis la sauvegarde. Le vérifier dans Services avant de le démarrer.' }
        Start-Service -Name 'SunshineService'
    }
}

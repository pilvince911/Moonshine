#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
. (Join-Path $PSScriptRoot 'Common-Service.ps1')
$script:MoonshineEngineVersion='1.0.0'
function Get-MoonshineOwnerPaths([string]$OwnerSid) {
    if ($OwnerSid -cnotmatch '\AS-1-(?:5-21|12-1)-[0-9-]+\z') { throw 'Compte Windows invalide.' }
    $profile=(Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$OwnerSid) -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
    $profile=[Environment]::ExpandEnvironmentVariables($profile);Assert-MoonshinePlainPath $profile
    $local=Join-Path $profile 'AppData\Local'
    $key='Registry::HKEY_USERS\'+$OwnerSid+'\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $known=(Get-ItemProperty -LiteralPath $key -Name 'Local AppData' -ErrorAction SilentlyContinue).'Local AppData'
    if ($known) {
        $known=[Environment]::ExpandEnvironmentVariables(([string]$known).Replace('%USERPROFILE%',$profile))
        if ([IO.Path]::GetFullPath($known).TrimEnd('\') -ine $local.TrimEnd('\')) { throw 'AppData est redirige. Les donnees existantes sont conservees; une migration adaptee est requise.' }
    }
    return @{Profile=$profile;Local=$local;OwnerSid=$OwnerSid}
}
function Set-MoonshineUserFolder([string]$Path,[string]$OwnerSid) {
    Assert-MoonshinePlainPath $Path;[IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544',$OwnerSid)) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-MoonshineSetupService([string]$OwnerSid) {
    $service=Get-CimInstance Win32_Service -Filter "Name='MoonshineService'" -ErrorAction Stop
    if (-not $service) { return $null }
    $installed='"'+(Join-Path $script:MoonshineServiceRoot 'Package\tools\sunshinesvc.exe')+'"'
    $previewRoot=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine-Preview'
    $preview='"'+(Join-Path $previewRoot 'Package\tools\sunshinesvc.exe')+'"'
    if ($service.StartName -notin @('LocalSystem','NT AUTHORITY\SYSTEM') -or $service.PathName.Trim() -cnotin @($installed,$preview)) { throw 'Le nom MoonshineService appartient a une installation non reconnue. Aucun changement.' }
    $root=if ($service.PathName.Trim() -ceq $preview) { $previewRoot } else { $script:MoonshineServiceRoot }
    $receipt=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Get-MoonshineServiceKitPath $root 'service-receipt.json')))
    if ($receipt.schema -cne 'moonshine-service-receipt/1' -or $receipt.name -cne 'MoonshineService' -or $receipt.owner_sid -cne $OwnerSid -or $receipt.id -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Le service ne correspond pas au compte selectionne.' }
    return @{Service=$service;Root=$root;Receipt=$receipt;Preview=($root -ceq $previewRoot)}
}
function Assert-MoonshineSetupIdle {
    if (@(Get-Process -Name sunshine,vibeshine,Moonshine,sunshine_display_helper -ErrorAction SilentlyContinue).Count) { throw 'Terminer les streams, arreter les hotes et attendre la restauration de l affichage avant de continuer.' }
    $services=@(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -in @('MoonshineService','SunshineService') -and $_.State -ne 'Stopped' })
    if ($services.Count) { throw 'Arreter Moonshine et VibeShine avant cette operation.' }
    $workers=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -eq 'powershell.exe' -and [string]$_.CommandLine -match '(?i)(Moonshine-Worker|Launch-Game|VibeShine-Xbox|Bootstrap|Desktop|GuiEngine)\.ps1' })
    if ($workers.Count) { throw 'Fermer les anciens synchroniseurs et lanceurs avant la copie.' }
}
function Get-MoonshinePreviewSource([string]$OwnerSid) {
    $paths=Get-MoonshineOwnerPaths $OwnerSid
    $root=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine-Preview'
    $file=Get-MoonshineServiceKitPath $root 'service-receipt.json'
    if (-not [IO.File]::Exists($file) -or (Get-Item -LiteralPath $file).Length -gt 4194304) { throw 'Profil du service 0.9 introuvable. Une installation neuve reste possible.' }
    $receipt=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file))
    if ($receipt.schema -cne 'moonshine-service-receipt/1' -or $receipt.owner_sid -cne $OwnerSid -or $receipt.id -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Profil 0.9 inconnu ou appartenant a un autre compte.' }
    foreach ($relative in @('Package/moonshine-trial-id.txt','Package/tools/moonshine/moonshine-trial-id.txt')) {
        $marker=Get-MoonshineServiceKitPath $root $relative
        if (-not [IO.File]::Exists($marker) -or (Get-Item -LiteralPath $marker).Length -gt 128 -or [IO.File]::ReadAllText($marker).Trim() -cne $receipt.id) { throw 'Marqueurs de l ancien profil incoherents.' }
    }
    $identity=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Get-MoonshineServiceKitPath $root 'Package/moonshine-service-profile.json')))
    if ($identity.schema -cne 'moonshine-service-preview/1' -or $identity.owner_sid -cne $OwnerSid -or $identity.id -cne $receipt.id) { throw 'Identite du profil 0.9 incoherente.' }
    $config=Join-Path $root 'Package\config';Assert-MoonshinePlainPath $config
    $data=Join-Path $paths.Local ('OPi5\Moonshine-Trial\'+$receipt.id+'\Sync');Assert-MoonshinePlainPath $data
    if (-not [IO.Directory]::Exists($data)) { throw 'Les donnees de l ancien essai sont absentes. Conserver la sauvegarde; choisir une installation neuve pour rescanner les jeux.' }
    return @{Root=$root;Config=$config;Data=$data;Receipt=$receipt;Id=$receipt.id}
}
function Assert-MoonshineMigrationReady([string]$Data,[string]$Config) {
    $conf=Join-Path $Config 'moonshine.conf';Assert-MoonshinePlainPath $conf
    if (-not [IO.File]::Exists($conf) -or (Get-Item -LiteralPath $conf).Length -gt 1048576) { throw 'Configuration source absente ou trop volumineuse.' }
    $text=[IO.File]::ReadAllText($conf)
    if ($text -match '(?m)^\s*(pkey|cert|file_state|vibeshine_file_state|credentials_file|file_apps|log_path)\s*=') { throw 'Des chemins personnalises necessitent une migration adaptee. Originaux conserves.' }
    $appsPath=Join-Path $Config 'apps.json'
    if ([IO.File]::Exists($appsPath)) {
        Assert-MoonshinePlainPath $appsPath
        $catalogue=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($appsPath))
        foreach ($app in @($catalogue.apps)) {
            $command=[string]$app.cmd
            if ($command.IndexOf($Data,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $owned=$app.'opi5-xbox-owner' -ceq 'opi5-xbox-sync/1' -and $app.uuid -cmatch '^706c6f73-7862-8[a-f0-9-]+$'
            $known=$command -match '\A"[A-Za-z]:[^"\r\n]+[\\/]powershell\.exe" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "[^"\r\n]+[\\/]Launch-Game\.ps1" -GameId "[a-f0-9-]+" -DataRoot "[^"\r\n]+"\z'
            if (-not $owned -or -not $known) { throw 'Une commande personnalisee depend de l ancien dossier. Elle doit etre adaptee avant migration; originaux conserves.' }
        }
    }
    $state=Join-Path $Data 'state.json'
    if ([IO.File]::Exists($state)) {
        $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($state))
        if ($value.schema -notin @('opi5-xbox-state/1','plos-xbox-state/1') -or @($value.pending.PSObject.Properties).Count) { throw 'Etat inconnu ou synchronisation en attente. Terminer la recuperation dans la 0.9 avant la migration.' }
    }
    foreach ($name in @('reset-control.json','undo-control.json')) {
        $file=Join-Path $Data $name
        if ([IO.File]::Exists($file)) {
            $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file))
            if ($name -eq 'reset-control.json') {
                if ($value.backup_id -cnotmatch '\Areset-\d{8}-\d{6}-[a-f0-9]{8}\z') { throw 'Controle de recuperation inconnu; migration suspendue.' }
                $journalPath=Join-Path $Data ('Backups\'+$value.backup_id+'\reset.json');Assert-MoonshinePlainPath $journalPath
                $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($journalPath))
                if ($value.status -notin @('reset','restored')) { throw 'Une remise a zero doit etre terminee dans la 0.9 avant la migration.' }
            } elseif ($value.status -ne 'undone') { throw 'Un retour arriere doit etre termine dans la 0.9 avant la migration.' }
        }
    }
}
function Copy-MoonshineLibraryData([string]$Source,[string]$Destination) {
    Assert-MoonshinePlainPath $Source;[IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien detecte dans les donnees; migration suspendue.' }
        if ($item.Name -in @('versions','Packages','sync.lock','bootstrap.lock')) { continue }
        $target=Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-MoonshinePrivateTree $item.FullName $target }
        else { [IO.File]::Copy($item.FullName,$target,$false);if ((Get-FileHash -LiteralPath $item.FullName).Hash -cne (Get-FileHash -LiteralPath $target).Hash) { throw 'Copie des donnees non verifiee.' } }
    }
}
function Convert-MoonshinePaths($Value,[string]$OldRoot,[string]$NewRoot) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $pattern=[regex]::Escape($OldRoot.TrimEnd('\'))+'(?=[\\/"\s]|$)'
        $value=[regex]::Replace($Value,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($m) $NewRoot},[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $runtime=[regex]::Escape($NewRoot)+'[\\/](?:versions|Packages)[\\/]\d+\.\d+\.\d+(?=[\\/"\s]|$)'
        return [regex]::Replace($value,$runtime,[Text.RegularExpressions.MatchEvaluator]{param($m) (Join-Path $NewRoot ('versions\'+$script:MoonshineEngineVersion))},[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if ($Value -is [array]) { $result=@();foreach ($item in $Value) { $result+=,(Convert-MoonshinePaths $item $OldRoot $NewRoot) };return ,$result }
    if ($Value -is [Collections.IDictionary]) { $result=[ordered]@{};foreach ($key in $Value.Keys) { $result[$key]=Convert-MoonshinePaths $Value[$key] $OldRoot $NewRoot };return ,$result }
    if ($Value -is [Management.Automation.PSCustomObject]) { $result=[ordered]@{};foreach ($property in $Value.PSObject.Properties) { $result[$property.Name]=Convert-MoonshinePaths $property.Value $OldRoot $NewRoot };return ,$result }
    return $Value
}
function Update-MoonshineMigratedJson([string]$Root,[string]$OldRoot,[string]$NewRoot) {
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' -ErrorAction Stop)) {
        Assert-MoonshinePlainPath $file.FullName
        if ($file.Length -gt 16777216) { throw 'Un fichier de migration JSON est trop volumineux.' }
        $text=[IO.File]::ReadAllText($file.FullName)
        if ($text.IndexOf($OldRoot.Replace('\','\\'),[StringComparison]::OrdinalIgnoreCase) -lt 0 -and $text.IndexOf($OldRoot,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $value=ConvertFrom-Json -InputObject $text
        Write-MoonshineServiceJson $file.FullName (Convert-MoonshinePaths $value $OldRoot $NewRoot)
    }
}
function Install-MoonshineUserRuntime([string]$Data,[string]$Package,[string]$Id) {
    $source=Join-Path $Package 'tools\moonshine'
    foreach ($relative in @('versions','Packages')) {
        $target=Join-Path $Data ($relative+'\'+$script:MoonshineEngineVersion)
        $stage=$target+'.New.'+[guid]::NewGuid().ToString('N')
        Copy-MoonshinePrivateTree $source $stage
        [IO.File]::WriteAllText((Join-Path $stage 'moonshine-install-id.txt'),$Id,[Text.Encoding]::ASCII)
        if ([IO.Directory]::Exists($target)) {
            Assert-MoonshinePlainPath $target
            $recovery=Join-Path $Data ('Recovery\runtime-'+$relative+'-'+[guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory((Split-Path -Parent $recovery)) | Out-Null
            [IO.Directory]::Move($target,$recovery)
        }
        [IO.Directory]::Move($stage,$target)
    }
}
function Bind-MoonshineInstalledService($Existing) {
    $path='"'+(Join-Path $script:MoonshineServiceRoot 'Package\tools\sunshinesvc.exe')+'"'
    if ($Existing) {
        $reply=Invoke-CimMethod -InputObject $Existing.Service -MethodName Change -Arguments @{PathName=$path;DisplayName='Moonshine';StartMode='Manual'} -ErrorAction Stop
        if ($reply.ReturnValue -ne 0) { throw ('Changement de service refuse par Windows : '+$reply.ReturnValue) }
    } else { New-Service -Name 'MoonshineService' -DisplayName 'Moonshine' -BinaryPathName $path -StartupType Manual | Out-Null }
}
function Install-MoonshineZip([string]$KitRoot,[string]$OwnerSid,[switch]$Migrate,[switch]$Automatic) {
    Assert-MoonshineAdmin;Assert-MoonshineSetupIdle
    $manifest=Read-MoonshineServiceManifest $KitRoot;$paths=Get-MoonshineOwnerPaths $OwnerSid
    $existing=Get-MoonshineSetupService $OwnerSid
    if ($existing) { Set-Service -Name 'MoonshineService' -StartupType Manual }
    $receipt=$null;$source=$null;$previous=$null
    if (Test-Path -LiteralPath $script:MoonshineServiceRoot) {
        $receipt=Read-MoonshineServiceReceipt
        if ($receipt.owner_sid -cne $OwnerSid -or $receipt.mode -cne 'installed') { throw 'Installation inconnue ou appartenant a un autre compte.' }
        if ($receipt.commit -ceq $manifest.commit) {
            Bind-MoonshineInstalledService $existing
            Save-MoonshineServiceKit $KitRoot $manifest
            Repair-MoonshineServicePackage $KitRoot $receipt
            $data=Join-Path $paths.Local ('Moonshine\Library\'+$receipt.id)
            if (-not [IO.Directory]::Exists($data)) { Set-MoonshineUserFolder $data $OwnerSid }
            Install-MoonshineUserRuntime $data (Join-Path $script:MoonshineServiceRoot 'Package') $receipt.id
            Add-MoonshineInstalledShortcut
            Set-Service -Name 'MoonshineService' -StartupType $(if ($Automatic) {'Automatic'} else {'Manual'})
            return $receipt
        }
        $source=@{Root=$script:MoonshineServiceRoot;Config=(Join-Path $script:MoonshineServiceRoot 'Package\config');Data=(Join-Path $paths.Local ('Moonshine\Library\'+$receipt.id));Id=$receipt.id;Receipt=$receipt}
    } elseif ($Migrate) { $source=Get-MoonshinePreviewSource $OwnerSid }
    if ($source) { Assert-MoonshineMigrationReady $source.Data $source.Config;$id=$source.Id } else { $id=[guid]::NewGuid().ToString('N') }
    $data=Join-Path $paths.Local ('Moonshine\Library\'+$id)
    $stage=$script:MoonshineServiceRoot+'.Stage.'+[guid]::NewGuid().ToString('N');$final=$script:MoonshineServiceRoot
    $dataExists=[IO.Directory]::Exists($data)
    if ($dataExists -and (-not $source -or $source.Data -ine $data)) {
        $marker=Join-Path $data 'moonshine-data-origin.json';Assert-MoonshinePlainPath $marker
        $origin=if ([IO.File]::Exists($marker)) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($marker)) } else { $null }
        if (-not $origin -or $origin.schema -cne 'moonshine-data-origin/1' -or $origin.owner_sid -cne $OwnerSid -or $origin.id -cne $id -or $origin.commit -cne $manifest.commit -or -not $origin.complete) { throw 'Des donnees non rattachees a cette installation existent deja. Aucun ecrasement.' }
    }
    Set-MoonshineProtectedFolder $stage
    $script:MoonshineServiceRoot=$stage
    try {
        $recovery=Join-Path $stage 'Recovery';Set-MoonshineProtectedFolder $recovery -Private
        $package=Join-Path $stage 'Package';[IO.Directory]::CreateDirectory($package) | Out-Null
        $config=Join-Path $package 'config';Set-MoonshineProtectedFolder $config -Private
        if ($source) {
            Copy-MoonshinePrivateTree $source.Config (Join-Path $recovery 'previous-config')
            Copy-MoonshinePrivateTree (Join-Path $recovery 'previous-config') $config
            Copy-MoonshineLibraryData $source.Data (Join-Path $recovery 'previous-library')
        }
        $files=@($manifest.files | Where-Object { $_.path.StartsWith('Package/') })
        foreach ($file in $files) {
            $from=Get-MoonshineServiceKitPath $KitRoot $file.path;$to=Get-MoonshineServiceKitPath $stage $file.path
            [IO.Directory]::CreateDirectory((Split-Path -Parent $to)) | Out-Null;[IO.File]::Copy($from,$to,$false)
            if ((Get-FileHash -LiteralPath $to).Hash -ine $file.sha256) { throw 'Copie du programme non verifiee.' }
        }
        foreach ($folder in @($package,(Join-Path $package 'tools\moonshine'))) { [IO.File]::WriteAllText((Join-Path $folder 'moonshine-install-id.txt'),$id,[Text.Encoding]::ASCII) }
        Write-MoonshineServiceJson (Join-Path $package 'moonshine-service-profile.json') @{schema='moonshine-service-preview/1';mode='installed';id=$id;owner_sid=$OwnerSid}
        $conf=Join-Path $config 'moonshine.conf';$lines=if ([IO.File]::Exists($conf)) {[IO.File]::ReadAllText($conf)} else {''}
        $names='sunshine_name|port|virtual_display_mode|virtual_display_layout|upnp|system_tray|install_steam_audio_drivers|origin_web_ui_allowed|update_check_interval'
        $lines=[regex]::Replace($lines,'(?m)^\s*(?:'+$names+')\s*=.*(?:\r?\n|$)','')
        $lines+="`r`nsunshine_name = Moonshine`r`nport = 48989`r`nvirtual_display_mode = per_client`r`nvirtual_display_layout = exclusive`r`nupnp = disabled`r`nsystem_tray = disabled`r`ninstall_steam_audio_drivers = disabled`r`norigin_web_ui_allowed = pc`r`nupdate_check_interval = 0`r`n"
        [IO.File]::WriteAllText($conf,$lines,(New-Object Text.UTF8Encoding($false)))
        if (-not [IO.File]::Exists((Join-Path $config 'apps.json'))) { [IO.File]::Copy((Join-Path $package 'assets\apps.json'),(Join-Path $config 'apps.json'),$false) }
        if ($source -and $source.Data -ine $data) { Update-MoonshineMigratedJson $config $source.Data $data }
        $receipt=@{schema='moonshine-service-receipt/1';mode='installed';name='MoonshineService';owner_sid=$OwnerSid;id=$id;commit=$manifest.commit;phase='prepared';files=$files;firewall_created=$false;legacy=$null;data_root=$data;version=$manifest.version}
        Save-MoonshineServiceReceipt $receipt;Save-MoonshineServiceKit $KitRoot $manifest
        Assert-MoonshineInstalledPackage $receipt
        if (-not $dataExists) {
            $dataStage=$data+'.Stage.'+[guid]::NewGuid().ToString('N')
            Set-MoonshineUserFolder $dataStage $OwnerSid
            if ($source) { Copy-MoonshineLibraryData (Join-Path $recovery 'previous-library') $dataStage;Update-MoonshineMigratedJson $dataStage $source.Data $data }
            Install-MoonshineUserRuntime $dataStage $package $id
            Write-MoonshineServiceJson (Join-Path $dataStage 'moonshine-data-origin.json') @{schema='moonshine-data-origin/1';owner_sid=$OwnerSid;id=$id;commit=$manifest.commit;complete=$true}
            [IO.Directory]::Move($dataStage,$data)
        } else { Install-MoonshineUserRuntime $data $package $id }
        if ($source -and $source.Root -ceq $final) {
            $previous=$final+'.Previous.'+[guid]::NewGuid().ToString('N')
            [IO.Directory]::Move($final,$previous)
        }
        [IO.Directory]::Move($stage,$final)
    } catch {
        if ($previous -and [IO.Directory]::Exists($previous) -and -not [IO.Directory]::Exists($final)) { [IO.Directory]::Move($previous,$final) }
        throw
    } finally { $script:MoonshineServiceRoot=$final }
    Bind-MoonshineInstalledService $existing
    if ($existing -and $existing.Preview) {
        $rule='MoonshineServicePreview-'+$existing.Receipt.id
        $network=Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
        if ($network) {
            $application=Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $network
            if ($application.Program -ine (Join-Path $existing.Root 'Package\sunshine.exe')) { throw 'Ancienne regle reseau personnalisee conservee; verifier avant de continuer.' }
            $network | Remove-NetFirewallRule
        }
        $existing.Receipt.phase='removed';Write-MoonshineServiceJson (Join-Path $existing.Root 'service-receipt.json') $existing.Receipt
    }
    $receipt.phase='installed';Save-MoonshineServiceReceipt $receipt
    Add-MoonshineInstalledShortcut
    Set-Service -Name 'MoonshineService' -StartupType $(if ($Automatic) {'Automatic'} else {'Manual'})
    return $receipt
}
function Add-MoonshineInstalledShortcut {
    $path=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Moonshine.lnk'
    $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($path)
    $target=Join-Path $script:MoonshineServiceRoot 'Kit\Ouvrir-Moonshine.cmd'
    if ([IO.File]::Exists($path) -and $link.TargetPath -ine $target) { throw 'Un autre raccourci Moonshine existe; il est conserve.' }
    $link.TargetPath=$target;$link.WorkingDirectory=Split-Path -Parent $target;$link.Description='Moonshine - bibliotheque et service Windows';$link.Save()
}
function Stop-MoonshineSelectedService([string]$OwnerSid) {
    Assert-MoonshineAdmin;$selected=Get-MoonshineSetupService $OwnerSid
    if (-not $selected) { return }
    if ($selected.Service.State -ne 'Stopped') {
        Stop-Service -Name 'MoonshineService';$controller=Get-Service -Name 'MoonshineService'
        try { $controller.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45)) } finally { $controller.Dispose() }
    }
}

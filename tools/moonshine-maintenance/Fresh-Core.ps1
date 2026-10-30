#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Only this kit's local code is loaded. Old kit scripts are never evaluated.
function Get-MMOldDistributions {
    $catalogue=Read-MMJson (Join-Path $PSScriptRoot 'Anciennes-versions.json')
    if ($catalogue.schema -cne 'moonshine-old-distributions/1' -or @($catalogue.items).Count -gt 100) { throw 'Catalogue des anciens kits invalide.' }
    return @($catalogue.items)
}
function Test-MMDistributionName([string]$Name,[string]$Expected,[switch]$Zip) {
    $suffix=if ($Zip) {'\.zip'} else {''}
    return $Name -imatch ('\A'+[regex]::Escape($Expected)+'(?: \(\d+\))?'+$suffix+'\z')
}
function Test-MMDistribution([string]$Path,$Distribution) {
    try {
        Assert-MMPlainPath $Path
        if ([IO.File]::Exists($Path)) {
            Assert-MMSingleFile $Path
            return $Distribution.archive_sha256 -cmatch '\A[a-f0-9]{64}\z' -and (Get-Item -LiteralPath $Path).Length -eq $Distribution.archive_size -and (Get-FileHash -LiteralPath $Path).Hash -ieq $Distribution.archive_sha256
        }
        $expected=@($Distribution.files | ForEach-Object { [pscustomobject]@{path=$_.path.Replace('/','\');size=[long]$_.size;sha256=$_.sha256} } | Sort-Object path)
        return Test-MMTreeEqual $expected @(Get-MMTree $Path)
    } catch { return $false }
}
function Get-MMKitFolders($Context) {
    $folders=New-Object 'Collections.Generic.List[string]'
    $values=@{Desktop=(Join-Path $Context.Profile 'Desktop');Downloads=(Join-Path $Context.Profile 'Downloads')}
    # Read the selected owner's folders, not the UAC administrator's folders.
    $shell='Registry::HKEY_USERS\'+$Context.OwnerSid+'\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    if (Test-Path -LiteralPath $shell) {
        $settings=Get-ItemProperty -LiteralPath $shell -ErrorAction Stop
        foreach ($entry in @(@{key='Desktop';name='Desktop'},@{key='{374DE290-123F-4565-9164-39C4925E467B}';name='Downloads'})) {
            $property=$settings.PSObject.Properties[$entry.key]
            if ($property -and [string]$property.Value -and -not ([string]$property.Value).Contains('%')) { $values[$entry.name]=[string]$property.Value }
        }
    }
    foreach ($path in @($values.Values)+@($Context.ExtraFolders)) {
        if (-not $path -or -not [IO.Directory]::Exists($path)) { continue }
        try {
            if (Test-MMProtectedPath $Context $path) { continue }
            Assert-MMPlainPath $path;$full=[IO.Path]::GetFullPath($path).TrimEnd('\')
            if ($full -ieq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw 'Choisir un dossier de kits, pas la racine d un disque.' }
            $null=Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop
            if (-not $folders.Contains($full)) { $folders.Add($full) }
        } catch { Write-Warning ('Dossier de kits conserve sans examen : '+$path+'; '+$_.Exception.Message) }
    }
    return $folders.ToArray()
}
function Test-MMTrialBase($Context,[string]$Base) {
    try {
        $index=Read-MMJson (Join-Path $Base 'instances.json')
        if ($index.schema -cne 'moonshine-trial-instances/1' -or $null -eq $index.instances) { return $false }
        foreach ($property in $index.instances.PSObject.Properties) {
            if ($property.Name -cnotmatch '\A[a-f0-9]{40}\z' -or [string]$property.Value -cnotmatch '\A[a-f0-9]{32}\z') { return $false }
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $Base -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            if (-not $item.PSIsContainer) {
                if ($item.Name -notin @('instances.json','instances.json.previous','instances.json.bak','instances.lock')) { return $false }
            } elseif ($item.Name -ceq 'Backups') {
                foreach ($backup in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
                    if (-not $backup.PSIsContainer) { return $false }
                    $manifest=Read-MMJson (Join-Path $backup.FullName 'manifest.json')
                    if ($manifest.schema -cne 'moonshine-backup/1' -or $manifest.complete -ne $true -or $manifest.user_sid -cne $Context.OwnerSid) { return $false }
                }
            } elseif (-not (Test-MMTrial $item.FullName $item.Name)) { return $false }
        }
        return $true
    } catch { return $false }
}
function Test-MMProtectedPath($Context,[string]$Path) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($protected in @((Join-Path $Context.ProgramFiles 'Moonshine'),(Join-Path $Context.Local 'Moonshine'),$Context.BackupBase,$PSScriptRoot)) {
        $root=[IO.Path]::GetFullPath($protected).TrimEnd('\')
        if ($full -ieq $root -or $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Get-MMAllCandidates($Context) {
    $items=New-Object 'Collections.Generic.List[object]'
    $base=Join-Path $Context.Local 'OPi5\Moonshine-Trial'
    $wholeBase=[IO.Directory]::Exists($base) -and (Test-MMTrialBase $Context $base)
    foreach ($item in @(Get-MMCandidates $Context)) {
        if ($wholeBase -and $item.kind -ceq 'essai portable') { continue }
        $items.Add($item)
    }
    if ($wholeBase) { $items.Add([pscustomobject]@{path=$base;kind='anciens essais et index';known=$true;id='';sync=''}) }
    $catalogue=@(Get-MMOldDistributions)
    foreach ($folder in @(Get-MMKitFolders $Context)) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)) {
            if (Test-MMProtectedPath $Context $entry.FullName) { continue }
            foreach ($distribution in $catalogue) {
                if (-not (Test-MMDistributionName $entry.Name $distribution.name -Zip:(-not $entry.PSIsContainer))) { continue }
                $path=$entry.FullName
                # Some ZIP extractors create an outer directory and a same-name inner directory.
                if ($entry.PSIsContainer -and [IO.Directory]::Exists((Join-Path $path $distribution.name))) {
                    $children=@(Get-ChildItem -LiteralPath $path -Force)
                    if ($children.Count -eq 1) { $path=Join-Path $path $distribution.name }
                }
                if (@($items | Where-Object { $_.path -ieq $path }).Count) { continue }
                $items.Add([pscustomobject]@{path=$path;kind='ancien kit 0.x';known=(Test-MMDistribution $path $distribution);id='';sync=''})
                break
            }
        }
    }
    $shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Moonshine Service.lnk'
    if ([IO.File]::Exists($shortcut)) {
        Assert-MMPlainPath $shortcut
        $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($shortcut)
        $target=Join-Path $Context.ProgramFiles 'Moonshine-Preview\Kit\Ouvrir-Moonshine-Service.cmd'
        $items.Add([pscustomobject]@{path=$shortcut;kind='raccourci service 0.9';known=($link.TargetPath -ieq $target -and -not $link.Arguments);id='';sync=''})
    }
    # The RC ZIP, Program Files\Moonshine and Moonshine\Library are not candidates.
    return $items.ToArray()
}
function Get-MMPreview($Context) {
    $root=Join-Path $Context.ProgramFiles 'Moonshine-Preview';Assert-MMPlainPath $root
    if (-not [IO.Directory]::Exists($root)) { return $null }
    $receipt=Read-MMJson (Join-Path $root 'service-receipt.json')
    if (-not (Test-MMPreviewReceipt $receipt $Context.OwnerSid) -or -not (Test-MMTrial $root $receipt.id)) { throw 'Ancien service 0.9 non reconnu : aucun retrait automatique.' }
    if ([IO.File]::Exists((Join-Path $root 'Package\moonshine-install-id.txt'))) { throw 'Marqueur de la nouvelle installation detecte : conservation.' }
    $profile=Read-MMJson (Join-Path $root 'Package\moonshine-service-profile.json')
    if ($profile.schema -cne 'moonshine-service-preview/1' -or $profile.id -cne $receipt.id -or $profile.owner_sid -cne $Context.OwnerSid -or ($profile.mode -and $profile.mode -cne 'trial')) { throw 'Profil de service 0.9 incoherent : conservation.' }
    $service=Get-CimInstance Win32_Service -Filter "Name='MoonshineService'" -ErrorAction Stop
    $expected='"'+(Join-Path $root 'Package\tools\sunshinesvc.exe')+'"'
    $owned=$null
    if ($service -and $service.PathName.Trim() -ceq $expected) {
        if ($service.StartName -notin @('LocalSystem','NT AUTHORITY\SYSTEM')) { throw 'Compte du service 0.9 personnalise : conservation.' }
        if ($service.State -cne 'Stopped') { throw 'Arreter Moonshine 0.9 dans Services avant le depart a neuf.' }
        $owned=$service
    } elseif ($service -and ([string]$service.PathName).IndexOf($root,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Commande du service 0.9 personnalisee : conservation.' }
    return @{root=$root;receipt=$receipt;service=$owned;expected=$expected}
}
function Get-MMEffectiveReferences($Context,[switch]$Fresh) {
    $preview=if ($Fresh) { Get-MMPreview $Context } else { $null }
    foreach ($reference in @(Get-MMReferences $Context)) {
        if ($preview) {
            if ($reference.source -cin @('Donnees encore utilisees par le service 0.9','Raccourci encore utilise par le service 0.9')) { continue }
            # .NET expands existing 8.3 components; references and candidates must
            # use the same canonical form after exact SCM ownership is established.
            $canonicalRoot=[IO.Path]::GetFullPath($preview.root).TrimEnd('\')
            $canonicalExecutable=[IO.Path]::GetFullPath((Join-Path $preview.root 'Package\tools\sunshinesvc.exe'))
            if ($preview.service -and $reference.source -ceq 'Service installe : MoonshineService' -and $reference.text -ieq $canonicalExecutable) { continue }
            if ($preview.service -and -not $reference.unknown -and ([string]$reference.source).StartsWith($canonicalRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        $reference
    }
}
function Get-MMAllTasks($Context,$Candidates) {
    $expanded=@($Candidates)
    $base=Join-Path $Context.Local 'OPi5\Moonshine-Trial'
    if ([IO.Directory]::Exists($base) -and @($Candidates | Where-Object { $_.path -ieq $base -and $_.known }).Count) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $base -Directory -Force)) {
            if (Test-MMTrial $folder.FullName $folder.Name) { $expanded+=@(@{kind='essai portable';id=$folder.Name;sync=(Join-Path $folder.FullName 'Sync')}) }
        }
    }
    return @(Get-MMTasks $Context $expanded)
}
function Get-MMAllLocks($Context,$Candidates) {
    $expanded=@($Candidates)
    $base=Join-Path $Context.Local 'OPi5\Moonshine-Trial'
    if ([IO.Directory]::Exists($base) -and @($Candidates | Where-Object { $_.path -ieq $base -and $_.known }).Count) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $base -Directory -Force)) {
            if (Test-MMTrial $folder.FullName $folder.Name) { $expanded+=@(@{known=$true;sync=(Join-Path $folder.FullName 'Sync')}) }
        }
    }
    $locks=Get-MMLocks $expanded
    try {
        if (@($Candidates | Where-Object { $_.path -ieq $base -and $_.known }).Count) {
            $path=Join-Path $base 'instances.lock';Assert-MMPlainPath $path
            if ([IO.File]::Exists($path)) { Assert-MMSingleFile $path }
            $locks.Add([IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))
        }
        return ,$locks
    } catch { foreach ($held in $locks) { $held.Dispose() };throw }
}
function Invoke-MMRetirePreview($Context,$Backup) {
    $preview=Get-MMPreview $Context
    if (-not $preview) { return }
    $entry=@($Backup.record.roots | Where-Object { $_.source -ieq $preview.root })
    $planned=@($Backup.record.plan | Where-Object { $_.path -ieq $preview.root -and $_.removable })
    if ($entry.Count -ne 1 -or $planned.Count -ne 1) { throw 'Service 0.9 sans sauvegarde et plan de retrait verifie : conservation.' }
    if (-not (Test-MMTreeEqual @($entry[0].files) @(Get-MMTree $preview.root)) -or -not (Test-MMTreeEqual @($entry[0].files) @(Get-MMTree (Join-Path $Backup.root $entry[0].key)))) { throw 'La sauvegarde du service 0.9 a change : retrait suspendu.' }
    Assert-MMIdle
    if ($preview.service) {
        $Backup.record.preview_service=@{name='MoonshineService';path=$preview.service.PathName;start_mode=$preview.service.StartMode;account=$preview.service.StartName;id=$preview.receipt.id}
        $Backup.record.phase='retiring-preview-service';Write-MMJson (Join-Path $Backup.root 'backup.json') $Backup.record
        # This exact stopped LocalSystem binding was validated again immediately above.
        & "$env:WINDIR\System32\sc.exe" delete MoonshineService | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Retrait du service 0.9 refuse. Les dossiers restent en place.' }
        $Backup.record.changes+=@(@{action='preview-service-unregistered';path=$preview.expected});Write-MMJson (Join-Path $Backup.root 'backup.json') $Backup.record
        for ($attempt=0;$attempt -lt 25;$attempt++) {
            if (-not (Get-CimInstance Win32_Service -Filter "Name='MoonshineService'" -ErrorAction Stop)) { break }
            Start-Sleep -Milliseconds 200
        }
        if (Get-CimInstance Win32_Service -Filter "Name='MoonshineService'" -ErrorAction Stop) { throw 'Windows termine le retrait. Fermer Services et les anciennes fenetres, puis relancer ce menage.' }
    }
    $name='MoonshineServicePreview-'+$preview.receipt.id
    $rules=@(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 1) {
        $rule=$rules[0];$app=Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule
        $address=Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule
        $expectedProgram=[IO.Path]::GetFullPath((Join-Path $preview.root 'Package\sunshine.exe'))
        $expandedProgram=[Environment]::ExpandEnvironmentVariables([string]$app.Program)
        $remote=@($address.RemoteAddress)
        if ([IO.Path]::IsPathRooted($expandedProgram) -and [IO.Path]::GetFullPath($expandedProgram) -ieq $expectedProgram -and [string]$rule.Profile -ceq 'Private' -and [string]$rule.Direction -ceq 'Inbound' -and [string]$rule.Action -ceq 'Allow' -and $remote.Count -eq 1 -and $remote[0] -ceq 'LocalSubnet') {
            $Backup.record.preview_firewall=@{name=$name;program=$app.Program;profile='Private';direction='Inbound';action='Allow';remote='LocalSubnet';enabled=[string]$rule.Enabled}
            Write-MMJson (Join-Path $Backup.root 'backup.json') $Backup.record
            Remove-NetFirewallRule -Name $name -ErrorAction Stop
            $Backup.record.changes+=@(@{action='preview-firewall-removed';name=$name});Write-MMJson (Join-Path $Backup.root 'backup.json') $Backup.record
        } else { Write-Host ('Regle personnalisee conservee : '+$name) -ForegroundColor Yellow }
    }
}

#Requires -Version 5.1
function Package-Asset([string]$Root,[string]$Relative) {
    if (-not $Relative -or $Relative -match '^([\\/]|[A-Za-z]:)|(^|[\\/])\.\.([\\/]|$)') { return '' }
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $path.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { return '' }
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    $parent=Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return '' }
    $stem=[regex]::Escape([IO.Path]::GetFileNameWithoutExtension($path))
    $extension=[regex]::Escape([IO.Path]::GetExtension($path))
    $choices=@(Get-ChildItem -LiteralPath $parent -File | Where-Object {
        $_.Name -match ('^'+$stem+'[.](?:scale|targetsize)-\d+(?:_[A-Za-z0-9-]+)*'+$extension+'$')
    } | Sort-Object @{Expression={if ($_.Name -match '(?:scale|targetsize)-(\d+)') {[int]$Matches[1]} else {0}};Descending=$true})
    if ($choices.Count -gt 0) { return $choices[0].FullName }
    return ''
}
function Xbox-References([string]$LocalState) {
    $rows=New-Object 'Collections.Generic.List[object]'
    $seen=@{}
    $root=Join-Path $LocalState 'ThirdPartyLibraries'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Note 'xbox' 'Aucun dossier ThirdPartyLibraries. Ouvrir Xbox app > Bibliotheque et attendre son chargement.'
        return @()
    }
    foreach ($provider in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
        if (($provider.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $provider.FullName -Filter '*.manifest' -File)) {
            try {
                $doc=Read-Json $file.FullName
                if ($null -eq $doc) { continue }
                if ((Field (Field $doc 'provider') 'enabled' $true) -eq $false) { continue }
                $cache=Field $doc 'gameCache'
                if ($null -eq $cache) { Note 'xbox' ('Format non reconnu : '+$file.Name); continue }
                foreach ($key in @(Keys $cache)) {
                    if ($key -eq 'version') { continue }
                    $record=Field $cache $key
                    $id=[string](Field $record 'id' $key)
                    $idMatch=[regex]::Match($id,'^([A-Za-z][A-Za-z0-9_-]*):(.+)$')
                    if (-not $idMatch.Success) { continue }
                    if ((Field $record 'hidden' $false) -eq $true -or (Field $record 'isHidden' $false) -eq $true) { continue }
                    if ((Field $record 'installed' $true) -eq $false -or (Field $record 'isInstalled' $true) -eq $false) { continue }
                    $origin=$idMatch.Groups[1].Value.ToLowerInvariant()
                    if ($seen.ContainsKey($id)) { continue }
                    $seen[$id]=$true
                    [void]$rows.Add([ordered]@{key=$id;origin=$origin;source=$file.FullName})
                }
            } catch { Note 'xbox' ('Manifeste ignore : '+$file.Name+'; '+$_.Exception.Message) }
        }
    }
    return $rows.ToArray()
}
function Steam-Installs {
    $roots=@()
    foreach ($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
        $item=Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        $p=Field $item 'SteamPath' (Field $item 'InstallPath')
        if ($p) { $roots+=$p }
    }
    $pf=[Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($pf) { $roots+=Join-Path $pf 'Steam' }
    $roots=@(Unique-Paths $roots)
    $libraries=@($roots)
    foreach ($root in $roots) {
        if (-not (Local-Path $root)) { continue }
        $path=Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                foreach ($m in [regex]::Matches((Read-Text $path),'(?im)"path"\s*"((?:\\.|[^"\\])*)"')) {
                    $libraries+=$m.Groups[1].Value.Replace('\\','\')
                }
            } catch { Note 'steam' $_.Exception.Message }
        }
    }
    $byId=@{}
    foreach ($root in @(Unique-Paths $libraries)) {
        if (-not (Local-Path $root)) { continue }
        $folder=Join-Path $root 'steamapps'
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter 'appmanifest_*.acf' -File)) {
            try {
                $text=Read-Text $file.FullName 2097152
                $id=Vdf-Value $text 'appid'
                $title=Vdf-Value $text 'name'
                $dir=Vdf-Value $text 'installdir'
                $flags=Vdf-Value $text 'StateFlags'
                if ($id -notmatch '^\d+$' -or -not $dir -or $dir -match '(^|[\\/])\.\.([\\/]|$)|^[\\/]|:') { continue }
                $install=Join-Path (Join-Path $folder 'common') $dir
                # Require fully installed, no stale uninstalled cache record.
                if ($flags -ne '4' -or -not (Test-Path -LiteralPath $install -PathType Container)) { continue }
                if ($id -eq '228980' -or $title -match '(?i)^Steamworks Common Redistributables$') { continue }
                if ($byId.ContainsKey($id)) {
                    if ($byId[$id].install -ine $install) { $byId[$id].ambiguous=$true }
                    continue
                }
                $cover=''
                foreach ($steamRoot in $roots) {
                    $cache=Join-Path $steamRoot 'appcache\librarycache'
                    foreach ($relative in @("${id}_library_600x900.jpg","${id}_library_600x900.png","$id\library_600x900.jpg","$id\library_600x900_2x.jpg")) {
                        $candidate=Join-Path $cache $relative
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $cover=$candidate; break }
                    }
                    if (-not $cover) {
                        $appCache=Join-Path $cache $id
                        if (Test-Path -LiteralPath $appCache -PathType Container) {
                            $posters=@(Get-ChildItem -LiteralPath $appCache -File | Where-Object { $_.Name -match '(?i)library_600x900(?:_2x)?\.(jpg|png)$' } | Sort-Object Length -Descending)
                            if ($posters.Count -gt 0) { $cover=$posters[0].FullName }
                        }
                    }
                    if ($cover) { break }
                }
                $byId[$id]=[ordered]@{id=$id;title=$title;install=$install;cover=$cover;ambiguous=$false}
            } catch { Note 'steam' ($file.Name+' : '+$_.Exception.Message) }
        }
    }
    return ,$byId
}
function Native-Installs {
    $startApps=@(Get-StartApps -ErrorAction Stop)
    $rows=New-Object 'Collections.Generic.List[object]'
    $seen=@{}
    $packages=@(Get-AppxPackage -ErrorAction Stop)
    foreach ($package in $packages) {
        if ($package.IsFramework -or $package.IsResourcePackage -or $package.NonRemovable) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$package.InstallLocation)) { continue }
        $path=Join-Path $package.InstallLocation 'MicrosoftGame.config'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $gdk=Read-Xml $path
            $exes=@($gdk.SelectNodes("//*[local-name()='Executable']") | Where-Object {
                $_.GetAttribute('Name') -match '(?i)\.exe$' -and $_.GetAttribute('TargetDeviceFamily') -in @('','PC') -and $_.GetAttribute('IsDevOnly') -ine 'true'
            })
            if ($exes.Count -eq 0) { continue } # DLC without an executable is never imported.
            $manifest=Get-AppxPackageManifest -Package $package.PackageFullName -ErrorAction Stop
            foreach ($app in $manifest.SelectNodes("/*[local-name()='Package']/*[local-name()='Applications']/*[local-name()='Application']")) {
                $appId=$app.GetAttribute('Id')
                $aumid=$package.PackageFamilyName+'!'+$appId
                if ($aumid -notmatch '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$') { continue }
                $matching=@($exes | Where-Object {
                    $_.GetAttribute('Id') -ieq $appId -or
                    (-not $_.GetAttribute('Id') -and [IO.Path]::GetFileNameWithoutExtension($_.GetAttribute('Name')) -ieq $appId)
                })
                if ($matching.Count -eq 0 -and $exes.Count -eq 1) { $matching=$exes }
                if ($matching.Count -eq 0) { continue }
                $names=@($matching | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.GetAttribute('Name')) } |
                    Where-Object { $_ -and $_ -notmatch '^(GameLaunchHelper|GamingServices|gamelauncherhelper)$' } | Sort-Object -Unique)
                if ($names.Count -eq 0) { continue }
                $menu=@($startApps | Where-Object { $_.AppID -eq $aumid })
                if ($menu.Count -ne 1) {
                    Note 'xbox-natif' ('Application sans entree unique au menu Demarrer : '+$aumid)
                    continue
                }
                $key='xbox:'+ $aumid.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key]=$true
                $cover=''
                $storeId=''
                $storeNode=$gdk.SelectSingleNode("/*[local-name()='Game']/*[local-name()='StoreId']")
                if ($storeNode -and $storeNode.InnerText.Trim() -match '^[A-Za-z0-9]{12}$') { $storeId=$storeNode.InnerText.Trim().ToUpperInvariant() }
                $visual=$gdk.SelectSingleNode("//*[local-name()='ShellVisuals']")
                foreach ($executable in $matching) {
                    foreach ($attr in @('OverrideSquare480x480Logo','OverrideLogo','OverrideSquare44x44Logo')) {
                        $candidate=Package-Asset $package.InstallLocation ($executable.GetAttribute($attr))
                        if ($candidate) { $cover=$candidate;break }
                    }
                    if ($cover) { break }
                }
                if ($visual -and -not $cover) {
                    foreach ($attr in @('Square480x480Logo','Square150x150Logo','Square44x44Logo')) {
                        $relative=$visual.GetAttribute($attr)
                        $candidate=Package-Asset $package.InstallLocation $relative
                        if ($candidate) { $cover=$candidate;break }
                    }
                }
                [void]$rows.Add([ordered]@{
                    key=$key;uuid=(Stable-Id $key);kind='xbox';title=[string]$menu[0].Name
                    aumid=$aumid;steam_id='';store_id=$storeId;install=$package.InstallLocation
                    monitor_names=@($names);cover=$cover
                    evidence='Paquet GDK enregistre et entree du menu Demarrer; visibilite Xbox a confirmer'
                    source=$path
                })
            }
        } catch { Note 'xbox-natif' ($package.Name+' : '+$_.Exception.Message) }
    }
    return $rows.ToArray()
}
function EA-Hints {
    # Selected game installation metadata only; no accounts or launcher sessions.
    $items=@()
    foreach ($path in @('HKLM:\SOFTWARE\WOW6432Node\Origin Games\*','HKLM:\SOFTWARE\Origin Games\*',
                         'HKLM:\SOFTWARE\WOW6432Node\EA Games\*','HKLM:\SOFTWARE\EA Games\*',
                         'HKLM:\SOFTWARE\WOW6432Node\EA SPORTS\*','HKLM:\SOFTWARE\EA SPORTS\*')) {
        $items+=@(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)
    }
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $items+=@(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object {
            [string](Field $_ 'Publisher') -match '(?i)(Electronic Arts|^EA\b)'
        })
    }
    $candidates=@{}
    foreach ($item in $items) {
        $install=[string](Field $item 'Install Dir' (Field $item 'InstallDir' (Field $item 'InstallLocation' (Field $item 'InstallPath'))))
        if (-not $install -or -not (Local-Path $install) -or -not (Test-Path -LiteralPath $install -PathType Container)) { continue }
        $install=[IO.Path]::GetFullPath($install).TrimEnd('\')
        $title=[string](Field $item 'DisplayName' (Field $item 'GameName' $item.PSChildName))
        if (-not $candidates.ContainsKey($install)) { $candidates[$install]=@{title=$title;ids=@();icons=@()} }
        $ids=@($candidates[$install].ids)
        foreach ($field in @('ContentID','ProductID','OfferID','GameID')) {
            foreach ($id in @(EA-IdList ([string](Field $item $field)))) {
                if ($id -notin $ids) { $ids+=$id }
            }
        }
        if ([string]$item.PSChildName -match '^\d+$' -and [string]$item.PSPath -match '(?i)\\Origin Games\\') { $ids+=[string]$item.PSChildName }
        $candidates[$install].ids=@($ids | Sort-Object -Unique)
        $icon=[string](Field $item 'DisplayIcon')
        if ($icon -and $icon -notin @($candidates[$install].icons)) { $candidates[$install].icons+=@($icon) }
    }
    $roots=@((Join-Path $env:ProgramFiles 'EA Games'))
    $pf86=[Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($pf86) { $roots+=Join-Path $pf86 'Origin Games' }
    foreach ($install in @($candidates.Keys)) {
        $parent=Split-Path -Parent $install
        if ($parent.Length -gt 3 -and $parent -ine $env:ProgramFiles -and $parent -ine $pf86) { $roots+=$parent }
    }
    foreach ($root in @(Unique-Paths $roots)) {
        if (-not (Local-Path $root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -First 500)) {
            if (($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (-not $candidates.ContainsKey($folder.FullName) -and (Test-Path -LiteralPath (Join-Path $folder.FullName '__Installer\installerdata.xml') -PathType Leaf)) {
                $candidates[$folder.FullName]=@{title=$folder.Name;ids=@();icons=@()}
            }
        }
    }
    foreach ($install in @($candidates.Keys | Sort-Object)) {
        $item=$candidates[$install]
        EA-ReadMetadata $install $item.title $item.ids $item.icons
    }
}
function Get-Inventory {
    Reset-Notes
    $localState=Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.GamingApp_8wekyb3d8bbwe\LocalState'
    $refs=@(Xbox-References $localState)
    $steam=Steam-Installs
    $ea=@(EA-Hints)
    $eaProtocol=EA-Protocol
    $eaSeen=@{}
    $ready=@(); $pending=@()
    foreach ($r in $refs) {
        if ($r.key -match '^steam:(\d+)$') {
            $id=$Matches[1]
            $g=$steam[$id]
            if ($g -and -not $g.ambiguous -and (Test-Path 'Registry::HKEY_CLASSES_ROOT\steam')) {
                $ready+=[ordered]@{
                    key=$r.key;uuid=(Stable-Id $r.key);kind='steam';title=$g.title
                    steam_id=$id;aumid='';install=$g.install;monitor_names=@();cover=$g.cover
                    source=$r.source;evidence='Manifeste Xbox + installation Steam complete'
                }
            } else {
                $pending+=[ordered]@{key=$r.key;title='';reason='Installation Steam complete et unique non confirmee, ou protocole Steam absent.'}
            }
        } elseif ($r.origin -eq 'ea') {
            $resolved=EA-BuildGame $r $ea $eaProtocol
            if ($resolved.ready) {
                $g=$resolved.ready
                if (EA-MergeGame $eaSeen $g) { $ready+=$g }
            } else { $pending+=$resolved.pending }
        } else {
            $pending+=[ordered]@{key=$r.key;title='';reason='Fournisseur non active dans cette version; commande de lancement a valider.'}
        }
    }
    try { $ready+=@(Native-Installs) } catch { Note 'xbox-natif' $_.Exception.Message }
    return [ordered]@{
        schema='opi5-xbox-inventory/1';version=$script:Version;created=(Get-Date).ToString('o')
        ready=@($ready | Sort-Object { $_.title });pending=@($pending);ea_hints=@($ea);ea_protocol=$eaProtocol
        notes=@($script:Notes.ToArray());xbox_ui_coverage_verified=$false
    }
}

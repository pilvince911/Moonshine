#Requires -Version 5.1
function EA-ValidId([string]$Id) {
    return $Id -cmatch '\A[A-Za-z0-9][A-Za-z0-9:._-]{0,149}\z'
}
function EA-IdList([string]$Value) {
    # Xbox can expose multiple aliases in one reference. Validate the entire
    # list before returning anything; never salvage part of an invalid value.
    if (-not $Value -or $Value.Length -gt 2400) { return @() }
    $parts=@($Value -split ',')
    if ($parts.Count -gt 16) { return @() }
    $ids=@()
    foreach ($part in $parts) {
        $id=$part.Trim()
        if (-not (EA-ValidId $id)) { return @() }
        if ($id -notin $ids) { $ids+=$id }
    }
    return $ids
}
function EA-ReferenceIds([string]$Key) {
    if (-not $Key.StartsWith('ea:',[StringComparison]::OrdinalIgnoreCase)) { return @() }
    return @(EA-IdList $Key.Substring(3))
}
function EA-LaunchUri([string]$Id) {
    if (-not (EA-ValidId $Id)) { throw 'Identifiant de contenu EA invalide.' }
    # Only installed games. No autoDownload and no command taken from a manifest.
    return 'origin2://game/launch?offerIds='+[Uri]::EscapeDataString($Id)
}
function EA-HelperName([string]$Name) {
    return $Name -match '(?i)(launcher|launchhelper|anticheat|crash|reporter|redist|unins|^setup$|^touchup$|^cleanup$|^activationui$|^link2ea$|^eadesktop$|^eabackgroundservice$|^dxsetup$)'
}
function EA-ResolveFile([string]$Root,[string]$Value) {
    $value=$Value.Trim().Trim('"').Replace('/','\')
    if (-not $value -or $value -match '[\r\n\x00]') { return '' }
    $value=[regex]::Replace($value,'(?i)^\[INSTALLDIR\][\\]?', '')
    if ($value -match '[\[\]%]') { return '' }
    try {
        $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
        if ([IO.Path]::IsPathRooted($value)) { $path=[IO.Path]::GetFullPath($value) }
        else { $path=[IO.Path]::GetFullPath((Join-Path $Root $value)) }
        if (-not $path.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { return '' }
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    } catch { }
    return ''
}
function EA-IconFile([string]$Root,[string]$Value) {
    # DisplayIcon is a file plus an optional resource index, never a command.
    # Only index 0 is supported by the associated-icon extractor.
    $value=$Value.Trim()
    if ($value -match ',\s*0\s*$') { $value=$value -replace ',\s*0\s*$','' }
    $path=EA-ResolveFile $Root $value
    if ($path -and [IO.Path]::GetExtension($path) -in @('.ico','.exe') -and
        -not (EA-HelperName ([IO.Path]::GetFileNameWithoutExtension($path)))) { return $path }
    return ''
}
function EA-ReadMetadata([string]$Install,[string]$Title='', $KnownIds=@(),$KnownIcons=@()) {
    $result=[ordered]@{
        title=$Title;install=$Install;ids=@($KnownIds);content_ids=@()
        manifest=(Join-Path $Install '__Installer\installerdata.xml');manifest_status='missing'
        executable_paths=@();monitor_names=@();cover='';icon_executable='';icon_candidates=@();reason='Manifeste EA local absent.'
    }
    if (-not (Test-Path -LiteralPath $result.manifest -PathType Leaf)) { return ,$result }
    try {
        $doc=Read-Xml $result.manifest
        $ids=@()
        foreach ($node in $doc.SelectNodes("//*[local-name()='contentIDs']/*[local-name()='contentID']")) {
            $value=$node.InnerText.Trim()
            if ((EA-ValidId $value) -and $value -notin $ids) { $ids+=$value }
        }
        $titleNode=$doc.SelectSingleNode("//*[local-name()='gameTitle']")
        if ($titleNode -and $titleNode.InnerText.Trim().Length -in 1..300) { $result.title=$titleNode.InnerText.Trim() }
        $executables=@()
        foreach ($node in $doc.SelectNodes("//*[local-name()='filePath' or local-name()='executePath']")) {
            $path=EA-ResolveFile $Install $node.InnerText
            if ($path -and [IO.Path]::GetExtension($path) -ieq '.exe' -and $path -notin $executables) { $executables+=$path }
        }
        $declaredMain=@($executables | Where-Object { -not (EA-HelperName ([IO.Path]::GetFileNameWithoutExtension($_))) })
        $main=@($declaredMain)
        # Presence/icon checks only; never guess an executable to launch or use
        # an undeclared basename to identify a process whose path is hidden.
        if ($main.Count -eq 0) {
            $main=@(Get-ChildItem -LiteralPath $Install -Filter '*.exe' -File -ErrorAction Stop |
                Where-Object { -not (EA-HelperName $_.BaseName) } | Select-Object -First 30 -ExpandProperty FullName)
            $executables=@(@($executables)+$main | Sort-Object -Unique)
        }
        $cover=''
        $icons=@()
        foreach ($node in $doc.SelectNodes("//*[local-name()='gameIcon' or local-name()='iconPath' or local-name()='imagePath' or local-name()='packArt' or local-name()='iconFile']")) {
            $path=EA-ResolveFile $Install $node.InnerText
            if ($path -and [IO.Path]::GetExtension($path) -in @('.png','.jpg','.jpeg') -and -not $cover) { $cover=$path }
            $icon=EA-IconFile $Install $node.InnerText
            if ($icon -and $icon -notin $icons) { $icons+=$icon }
        }
        foreach ($value in @($KnownIcons)) {
            $icon=EA-IconFile $Install ([string]$value)
            if ($icon -and $icon -notin $icons) { $icons+=$icon }
        }
        $result.content_ids=@($ids)
        $result.ids=@(@($KnownIds)+$ids | Where-Object { EA-ValidId ([string]$_) } | Sort-Object -Unique)
        $result.executable_paths=@($executables)
        $result.monitor_names=@($declaredMain | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) } | Sort-Object -Unique)
        $result.cover=$cover
        if ($main.Count -eq 1) {
            $result.icon_executable=$main[0]
            if ($main[0] -notin $icons) { $icons+=$main[0] }
        }
        $result.icon_candidates=@($icons | Select-Object -First 4)
        $result.manifest_status='read'
        $result.reason=''
        if ($ids.Count -eq 0) { $result.reason='Aucun contentID EA confirme dans installerdata.xml.' }
        elseif ($executables.Count -eq 0) { $result.reason='Aucun executable present confirme dans cette installation EA.' }
    } catch {
        $result.manifest_status='unreadable'
        $result.reason='Manifeste EA illisible ou modifie pendant la lecture.'
    }
    return ,$result
}
function EA-Protocol {
    $result=[ordered]@{ready=$false;registered=$false;handler='';handler_exists=$false;reason='Protocole origin2 absent; ouvrir ou reparer EA app.'}
    $key=Get-Item -LiteralPath 'Registry::HKEY_CLASSES_ROOT\origin2\shell\open\command' -ErrorAction SilentlyContinue
    if (-not $key) { return ,$result }
    $result.registered=$true
    $command=[string]$key.GetValue('')
    $handler=''
    if ($command -match '^\s*"([^"]+\.exe)"(?:\s|$)') { $handler=$Matches[1] }
    elseif ($command -match '^\s*([A-Za-z]:\\.+?\.exe)(?:\s|$)') { $handler=$Matches[1] }
    if ($handler) {
        $result.handler=[IO.Path]::GetFileName($handler)
        $result.handler_exists=(Local-Path $handler) -and (Test-Path -LiteralPath $handler -PathType Leaf)
        $result.ready=$result.handler_exists
    }
    $result.reason=$(if ($result.ready) { '' } else { 'Protocole origin2 enregistre, mais son programme est introuvable.' })
    return ,$result
}
function EA-BuildGame($Reference,$Hints,$Protocol) {
    $ids=@(EA-ReferenceIds ([string]$Reference.key))
    $pending=[ordered]@{key=$Reference.key;title='';reason='Installation EA correspondant a cet identifiant non trouvee.'}
    if ($ids.Count -eq 0) {
        $pending.reason='Reference EA invalide; identifiants separes par des virgules attendus.'
        return @{ready=$null;pending=$pending}
    }
    $candidates=@($Hints | Where-Object { @($_.content_ids | Where-Object { $_ -in $ids }).Count -gt 0 })
    if ($candidates.Count -gt 1) { $pending.reason='Plusieurs installations EA correspondent aux identifiants Xbox; aucun ajout automatique.' }
    if ($candidates.Count -eq 0) {
        $registryOnly=@($Hints | Where-Object { @($_.ids | Where-Object { $_ -in $ids }).Count -gt 0 })
        if ($registryOnly.Count -eq 1) {
            $pending.title=$registryOnly[0].title
            $pending.reason=$(if ($registryOnly[0].reason) { $registryOnly[0].reason } else { 'Reference Xbox non confirmee parmi les contentID du manifeste EA.' })
        }
    }
    if ($candidates.Count -ne 1) { return @{ready=$null;pending=$pending} }
    $hint=$candidates[0];$pending.title=$hint.title
    if ($hint.reason) { $pending.reason=$hint.reason;return @{ready=$null;pending=$pending} }
    if (-not $Protocol.ready) { $pending.reason=$Protocol.reason;return @{ready=$null;pending=$pending} }
    # First manifest content ID is stable across Xbox aliases/edition entries.
    $canonical=[string]$hint.content_ids[0]
    $key='ea:'+$canonical.ToLowerInvariant()
    $game=[ordered]@{
        key=$key;uuid=(Stable-Id $key);kind='ea';title=$hint.title
        ea_content_id=$canonical;ea_content_ids=@($hint.content_ids);ea_xbox_keys=@($Reference.key)
        ea_matched_ids=@($ids | Where-Object { $_ -in @($hint.content_ids) })
        steam_id='';aumid='';install=$hint.install;monitor_names=@($hint.monitor_names)
        cover=$hint.cover;icon_executable=$hint.icon_executable;icon_candidates=@($hint.icon_candidates);source=$hint.manifest
        evidence='Reference Xbox + contentID EA + installation locale + protocole origin2'
    }
    return @{ready=$game;pending=$null}
}
function EA-MergeGame($ByKey,$Game) {
    if ($ByKey.ContainsKey($Game.key)) {
        $known=$ByKey[$Game.key]
        if ($known.install -ine $Game.install) { throw 'Deux installations EA contradictoires pour le meme jeu.' }
        $known.ea_xbox_keys=@(@($known.ea_xbox_keys)+@($Game.ea_xbox_keys) | Sort-Object -Unique)
        $known.ea_matched_ids=@(@($known.ea_matched_ids)+@($Game.ea_matched_ids) | Sort-Object -Unique)
        return $false
    }
    $ByKey[$Game.key]=$Game
    return $true
}
function EA-CommandMatches([string]$Command,$Ids) {
    foreach ($match in [regex]::Matches($Command,'(?i)origin2://game/launch/?\?[^"\s]+')) {
        foreach ($param in (($match.Value -split '\?',2)[1] -split '&')) {
            $pair=$param -split '=',2
            if ($pair.Count -ne 2 -or $pair[0] -ine 'offerIds') { continue }
            foreach ($id in @(EA-IdList ([Uri]::UnescapeDataString($pair[1])))) {
                if ($id -in @($Ids)) { return $true }
            }
        }
    }
    return $false
}
function EA-SelectGames($Games,[bool]$Pilot=$false) {
    $ea=@($Games | Where-Object { $null -ne $_ -and $_.kind -eq 'ea' })
    if (-not $Pilot) { return $ea }
    $preferred=@($ea | Where-Object { '16425629' -in @($_.ea_content_ids) } | Select-Object -First 1)
    if ($preferred.Count -gt 0) { return $preferred }
    return @($ea | Select-Object -First 1)
}
function EA-IsGameProcess([string]$Path,[string]$Name,[string]$Root,$DeclaredNames) {
    if (-not $Name -or (EA-HelperName $Name)) { return $false }
    if (-not $Path) { return $Name -in @($DeclaredNames) }
    try {
        $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
        $full=[IO.Path]::GetFullPath($Path)
        if (-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { return $false }
        $relative=$full.Substring($base.Length)
        return $relative -notmatch '(?i)(^|[\\/])(__Installer|__redist|redist|support|installer|easyanticheat)([\\/]|$)'
    } catch { return $false }
}

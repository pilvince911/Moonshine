#Requires -Version 5.1
function Init-Artwork {
    Init-Native
    # Compiler references alone do not load these types into PowerShell 5.1.
    # Load the framework assembly before constructing or resolving image types.
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    if (-not ('OPi5Artwork' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'Artwork.cs') -ReferencedAssemblies @('System.dll','System.Drawing.dll') -ErrorAction Stop
    }
}
function File-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}
function Artwork-Json([string]$Url) {
    [byte[]]$bytes=[OPi5Native]::FetchArtwork($Url,4194304)
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop)
}
function Store-ImageUrls($Catalog,[string]$StoreId) {
    $products=@($Catalog.Products | Where-Object { $_.ProductId -ieq $StoreId })
    if ($products.Count -ne 1) { throw 'Le catalogue Microsoft ne confirme pas cet identifiant de produit.' }
    $images=@()
    $rank=@{Poster=0;BrandedKeyArt=1;BoxArt=2;Tile=3;Logo=4}
    foreach ($locale in @($products[0].LocalizedProperties)) {
        foreach ($item in @($locale.Images)) {
            $purpose=[string]$item.ImagePurpose
            if (-not $rank.ContainsKey($purpose)) { continue }
            $url=[string]$item.Uri
            if ($url.StartsWith('//')) { $url='https:'+$url }
            if (-not [OPi5Native]::PublicArtworkUrl($url) -or $url -notmatch '^https://store-images\.s-microsoft\.com/image/') { continue }
            $images+=@{url=$url;rank=$rank[$purpose];area=([long]$item.Width*[long]$item.Height)}
        }
    }
    $seen=@{}
    foreach ($i in @($images | Sort-Object @{Expression={$_.rank}},@{Expression={$_.area};Descending=$true})) {
        if (-not $seen.ContainsKey($i.url)) { $seen[$i.url]=$true;$i.url }
    }
}
function Steam-HeaderUrl($Catalog,[string]$SteamId) {
    $record=Field $Catalog $SteamId
    if (-not $record -or $record.success -ne $true -or [string]$record.data.steam_appid -ne $SteamId) {
        throw 'Le catalogue Steam ne confirme pas cet identifiant de jeu.'
    }
    $url=[string]$record.data.header_image
    if (-not [OPi5Native]::PublicArtworkUrl($url) -or
        $url -notmatch ('^https://[^/]+\.steamstatic\.com/(?:store_item_assets/)?steam/apps/'+[regex]::Escape($SteamId)+'/')) {
        throw 'Image Steam non reconnue pour cet identifiant.'
    }
    return $url
}
function EA-ArtworkTitleKey([string]$Title) {
    # Remove branding only. Keep numbers, editions, trial/demo and every other
    # word: FC 27 must never match FC 26, FC 27 Lite or an add-on.
    $key=Title-Key $Title
    return ($key -replace '^ea sports\s+','' -replace '^ea\s+','')
}
function EA-SteamArtworkId($Search,[string]$Title) {
    $key=EA-ArtworkTitleKey $Title
    if (-not $key) { return '' }
    $ids=@($Search.items | Where-Object {
        $_.type -eq 'app' -and [string]$_.id -match '^\d+$' -and
        (Field (Field $_ 'platforms') 'windows' $false) -eq $true -and
        (EA-ArtworkTitleKey ([string]$_.name)) -eq $key
    } | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
    if ($ids.Count -ne 1) { return '' }
    return $ids[0]
}
function EA-SteamHeaderUrl($Catalog,[string]$SteamId,[string]$Title) {
    $record=Field $Catalog $SteamId
    if (-not $record -or $record.success -ne $true) { throw 'Fiche Steam du jeu EA indisponible.' }
    $data=$record.data
    if ([string]$data.steam_appid -ne $SteamId -or $data.type -ne 'game' -or
        (EA-ArtworkTitleKey ([string]$data.name)) -ne (EA-ArtworkTitleKey $Title) -or
        (Field (Field $data 'platforms') 'windows' $false) -ne $true -or
        @($data.publishers | Where-Object { $_ -in @('Electronic Arts','EA Sports','EA') }).Count -eq 0) {
        throw 'Fiche Steam non confirmee : titre exact, jeu PC et editeur EA requis.'
    }
    return Steam-HeaderUrl $Catalog $SteamId
}
function Steam-LibraryUrls($Catalog,[string]$SteamId,[string]$Title) {
    $items=@($Catalog.response.store_items | Where-Object {
        [string]$_.appid -eq $SteamId -and [string]$_.id -eq $SteamId -and
        $_.success -eq 1 -and $_.item_type -eq 0 -and
        (EA-ArtworkTitleKey ([string]$_.name)) -eq (EA-ArtworkTitleKey $Title)
    })
    if ($items.Count -ne 1) { throw 'Catalogue des affiches sans correspondance unique.' }
    $assets=$items[0].assets
    $format=[string]$assets.asset_url_format
    if ($format -cnotmatch ('\Asteam/apps/'+[regex]::Escape($SteamId)+'/\$\{FILENAME\}(?:\?t=\d+)?\z')) {
        throw 'Format de chemin des affiches Steam non reconnu.'
    }
    foreach ($field in @('library_capsule_2x','library_capsule')) {
        $filename=[string](Field $assets $field)
        if ($filename -cnotmatch '\A(?:[a-fA-F0-9]{40}/)?library_(?:capsule|600x900)(?:_2x)?\.(?:jpg|png)\z') { continue }
        $url='https://shared.akamai.steamstatic.com/store_item_assets/'+$format.Replace('${FILENAME}',$filename)
        if ([OPi5Native]::PublicArtworkUrl($url)) { $url }
    }
}
function Artwork-Attempt($Game,[string]$Source,[string]$Status,[string]$Detail='') {
    if ($Detail.Length -gt 300) { $Detail=$Detail.Substring(0,300) }
    $Game['artwork_attempts']=@($Game.artwork_attempts)+@(@{source=$Source;status=$Status;detail=$Detail})
}
function Save-Artwork([string]$Source,[byte[]]$Bytes,[string]$Destination) {
    if ($Source) {
        $file=Get-Item -LiteralPath $Source -ErrorAction Stop
        if ($file.Length -gt 8388608) { throw 'Image locale trop volumineuse.' }
        $Bytes=[IO.File]::ReadAllBytes($Source)
        if ([IO.Path]::GetExtension($Source) -ieq '.ico') { $Bytes=[OPi5Artwork]::IcoBytes($Bytes) }
    }
    [byte[]]$png=[OPi5Artwork]::Png($Bytes)
    Write-AtomicBytes $Destination $png
}
function Resolve-Artwork($Game,[string]$Data,[bool]$Force=$false) {
    Init-Artwork
    $folder=Join-Path $Data 'Artwork'
    $destination=Join-Path $folder ($Game.uuid+'.png')
    $metaPath=Join-Path $folder ($Game.uuid+'.artwork.json')
    $local=[string]$Game.cover
    $Game['cover']='';$Game['artwork_status']='missing';$Game['artwork_origin']='indisponible'
    $Game['artwork_attempts']=@();$Game['artwork_steam_id']=''
    $meta=$null
    try { $meta=Read-Json $metaPath }
    catch {
        Preserve-RecoveryFile $metaPath 'artwork'
        Repair-Event 'artwork' 'metadata_rebuild' $Game.title
    }
    $cached=$false
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        try {
            $hash=File-Hash $destination
            if ($meta -and $meta.key -eq $Game.key -and $meta.sha256 -eq $hash) {
                $cached=$true
                if ((Field $meta 'custom' $false) -eq $true) {
                    $Game['cover']=$destination;$Game['artwork_status']='custom';$Game['artwork_origin']='Image locale personnalisee conservee'
                    return
                }
            } else {
                # A manually replaced cache image is validated, then left untouched.
                if ((Get-Item -LiteralPath $destination).Length -gt 8388608) { throw 'Cache trop volumineux.' }
                [byte[]]$custom=[IO.File]::ReadAllBytes($destination)
                if ($custom.Length -lt 4 -or $custom[0] -ne 137 -or $custom[1] -ne 80 -or $custom[2] -ne 78 -or $custom[3] -ne 71) { throw 'Le cache doit etre un vrai PNG.' }
                $null=[OPi5Artwork]::Png($custom)
                $Game['cover']=$destination;$Game['artwork_status']='custom';$Game['artwork_origin']='Image locale personnalisee conservee'
                try {
                    Write-Json $metaPath @{schema='opi5-xbox-artwork/1';key=$Game.key;origin=$Game.artwork_origin;custom=$true;sha256=$hash}
                    Repair-Event 'artwork' 'custom_preserved' $Game.title
                } catch { Note 'pochette' ('Image personnalisee conservee; ses metadonnees restent a reparer : '+$Game.title) }
                return
            }
        } catch {
            Preserve-RecoveryFile $destination 'artwork'
            Repair-Event 'artwork' 'image_rebuild' $Game.title
            Note 'pochette' ('Image en cache invalide pour '+$Game.title+'; recuperation en cours.')
        }
    }
    if ($cached) {
        $Game['cover']=$destination;$Game['artwork_status']='cached';$Game['artwork_origin']=[string]$meta.origin
        if ($meta.origin -in @('Steam','Steam (banniere)','Microsoft Store')) { return }
        if ($Game.kind -eq 'ea' -and $meta.origin -in @('Steam (jeu EA)','Steam (jeu EA, banniere)') -and
            (Field $meta 'ea_title_key') -eq (EA-ArtworkTitleKey $Game.title)) {
            $Game['artwork_steam_id']=[string](Field $meta 'steam_id')
            Artwork-Attempt $Game 'Cache du jeu EA' 'ready'
            return
        }
    }
    $next=[datetime]::MinValue
    if (-not $Force -and $meta -and [datetime]::TryParse([string](Field $meta 'retry_after_utc'),[ref]$next) -and $next.ToUniversalTime() -gt [datetime]::UtcNow) { return }
    $origin='';$saved=$false
    try {
        if ($Game.kind -eq 'steam' -and $Game.steam_id -match '^\d+$') {
            $url='https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/'+$Game.steam_id+'/library_600x900.jpg'
            try {
                [byte[]]$bytes=[OPi5Native]::FetchArtwork($url,8388608)
                Save-Artwork '' $bytes $destination
                $origin='Steam';$saved=$true
            } catch {
                $catalog=Artwork-Json ('https://store.steampowered.com/api/appdetails?appids='+$Game.steam_id+'&filters=basic&l=english')
                $header=Steam-HeaderUrl $catalog ([string]$Game.steam_id)
                [byte[]]$bytes=[OPi5Native]::FetchArtwork($header,8388608)
                Save-Artwork '' $bytes $destination
                $origin='Steam (banniere)';$saved=$true
            }
        } elseif ($Game.kind -eq 'xbox' -and (Field $Game 'store_id') -match '^[A-Za-z0-9]{12}$') {
            $catalog=Artwork-Json ('https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds='+$Game.store_id+'&market=CA&languages=fr-ca,en-ca,en-us')
            $urls=@(Store-ImageUrls $catalog $Game.store_id | Select-Object -First 2)
            foreach ($url in $urls) {
                try {
                    [byte[]]$bytes=[OPi5Native]::FetchArtwork($url,8388608)
                    Save-Artwork '' $bytes $destination
                    $origin='Microsoft Store';$saved=$true;break
                } catch { }
            }
        } elseif ($Game.kind -eq 'ea') {
            # Public artwork lookup only. The EA launch identity is unchanged.
            $query=[Uri]::EscapeDataString((EA-ArtworkTitleKey $Game.title))
            $search=Artwork-Json ('https://store.steampowered.com/api/storesearch/?term='+$query+'&l=english&cc=ca')
            $steamId=EA-SteamArtworkId $search $Game.title
            if (-not $steamId) { throw 'Aucun titre PC unique et exact dans la recherche Steam.' }
            $catalog=Artwork-Json ('https://store.steampowered.com/api/appdetails?appids='+$steamId+'&l=english&cc=ca')
            $header=EA-SteamHeaderUrl $catalog $steamId $Game.title
            $Game['artwork_steam_id']=$steamId
            $urls=@()
            try {
                $request=@{ids=@(@{appid=[int]$steamId});context=@{language='english';country_code='CA'};data_request=@{include_assets=$true}}
                $encoded=[Uri]::EscapeDataString((ConvertTo-Json -InputObject $request -Depth 6 -Compress))
                $assets=Artwork-Json ('https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json='+$encoded)
                $urls=@(Steam-LibraryUrls $assets $steamId $Game.title)
            } catch { Artwork-Attempt $Game 'Catalogue des affiches Steam' 'unavailable' $_.Exception.Message }
            $urls+=@('https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/'+$steamId+'/library_600x900.jpg')
            foreach ($url in @($urls | Select-Object -Unique -First 3)) {
                try {
                    [byte[]]$bytes=[OPi5Native]::FetchArtwork($url,8388608)
                    Save-Artwork '' $bytes $destination
                    $origin='Steam (jeu EA)';$saved=$true;break
                } catch { }
            }
            if (-not $saved) {
                [byte[]]$bytes=[OPi5Native]::FetchArtwork($header,8388608)
                Save-Artwork '' $bytes $destination
                $origin='Steam (jeu EA, banniere)';$saved=$true
            }
            Artwork-Attempt $Game 'Catalogue Steam : meme jeu EA' 'ready' ('Identifiant image : '+$steamId)
        }
    } catch {
        if ($Game.kind -eq 'ea') { Artwork-Attempt $Game 'Catalogue Steam : meme jeu EA' 'unavailable' $_.Exception.Message }
    }
    if (-not $saved -and -not $cached -and $local -and (Test-Path -LiteralPath $local -PathType Leaf)) {
        try { Save-Artwork $local $null $destination;$origin='Fichiers du jeu';$saved=$true }
        catch { if ($Game.kind -eq 'ea') { Artwork-Attempt $Game 'Image locale EA' 'unavailable' $_.Exception.Message } }
    }
    if (-not $saved -and -not $cached -and $Game.kind -eq 'ea') {
        $icons=@(@($Game.icon_candidates)+@($Game.icon_executable) | Where-Object { $_ } | Select-Object -Unique -First 4)
        foreach ($candidate in $icons) {
            try {
                $iconPath=EA-IconFile $Game.install ([string]$candidate)
                if (-not $iconPath) { throw 'Fichier d icone non confirme dans le dossier du jeu.' }
                if ([IO.Path]::GetExtension($iconPath) -ieq '.ico') { Save-Artwork $iconPath $null $destination }
                else {
                    [byte[]]$iconBytes=[OPi5Artwork]::IconBytes($iconPath)
                    Save-Artwork '' $iconBytes $destination
                }
                $origin='Icone du jeu EA';$saved=$true
                Artwork-Attempt $Game 'Icone locale EA' 'ready'
                break
            } catch { Artwork-Attempt $Game 'Icone locale EA' 'unavailable' $_.Exception.Message }
        }
        if ($icons.Count -eq 0) { Artwork-Attempt $Game 'Icone locale EA' 'unavailable' 'Aucune icone declaree ni executable de jeu unique.' }
    }
    if ($saved) {
        $Game['cover']=$destination;$Game['artwork_status']='ready';$Game['artwork_origin']=$origin
        Write-Json $metaPath @{schema='opi5-xbox-artwork/1';key=$Game.key;origin=$origin;sha256=(File-Hash $destination);retry_after_utc=([datetime]::UtcNow.AddHours(6).ToString('o'));steam_id=$Game.artwork_steam_id;ea_title_key=$(if ($Game.kind -eq 'ea') { EA-ArtworkTitleKey $Game.title } else { '' })}
    } else {
        $origin=$(if ($cached) { [string]$meta.origin } else { 'indisponible' })
        Write-Json $metaPath @{schema='opi5-xbox-artwork/1';key=$Game.key;origin=$origin;sha256=$(if ($cached) {File-Hash $destination} else {''});retry_after_utc=([datetime]::UtcNow.AddMinutes(15).ToString('o'))}
        if (-not $cached) { Note 'pochette' ('Aucune image verifiee disponible pour '+$Game.title+'; l import reste possible et une nouvelle tentative sera faite plus tard.') }
    }
}

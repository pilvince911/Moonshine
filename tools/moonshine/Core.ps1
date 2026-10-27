#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Atomic.ps1')
. (Join-Path $PSScriptRoot 'Brand.ps1')
$script:Version = '0.8.0'
$script:Owner = 'opi5-xbox-sync/1'
$script:TransientFields = @('id','index','image-version','playnite-icon-version','remote-session')
function Operation-Checkpoint {
    if ($script:EmbeddedCancel -and $script:EmbeddedCancel.WaitOne(0)) { throw [OperationCanceledException]::new('Annulation demandée.') }
    if ($null -ne $script:GuiBridge) { $script:GuiBridge.Checkpoint() }
}

function Field($Object, [string]$Name, $Default=$null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } else {
        $p=$Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    }
    if ($script:LegacyFields.ContainsKey($Name)) { return Field $Object $script:LegacyFields[$Name] $Default }
    return $Default
}
function Keys($Object) {
    if ($Object -is [Collections.IDictionary]) { return @($Object.Keys) }
    # Empty JSON objects have no properties. Member-access enumeration on an
    # empty collection can produce one null item in Windows PowerShell 5.1.
    if ($null -ne $Object) {
        foreach ($property in $Object.PSObject.Properties) { $property.Name }
    }
    return @()
}
function To-Map($Object) {
    $map=[ordered]@{}
    # Direct assignment preserves empty and one-element arrays in API payloads.
    foreach ($k in @(Keys $Object)) {
        if ($Object -is [Collections.IDictionary]) { $map[$k]=$Object[$k] }
        else { $map[$k]=$Object.PSObject.Properties[$k].Value }
    }
    return ,$map
}
function Parse-Port([string]$Text) {
    $value=$Text.Trim()
    if (-not $value) { return 47990 }
    if ($value -match '^\[(\d{1,5})\]$') { $value=$Matches[1] }
    $port=0
    if ($value -notmatch '^\d{1,5}$' -or -not [int]::TryParse($value,[ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw 'Port invalide : saisir un nombre de 1 a 65535, ou appuyer sur Entree pour 47990.'
    }
    return $port
}
function Title-Key([string]$Title) {
    $plain=$Title.Normalize([Text.NormalizationForm]::FormD) -replace '\p{M}',''
    return ([regex]::Replace($plain.ToLowerInvariant(),'[^\p{L}\p{Nd}]+',' ')).Trim()
}
function Clone-Object($Object) {
    # A property wrapper preserves root arrays, false, zero and empty strings in
    # Windows PowerShell 5.1, whose pipeline enumerates root JSON arrays.
    $wrapper=ConvertFrom-Json -InputObject ('{"value":'+(Json $Object)+'}') -ErrorAction Stop
    return ,$wrapper.value
}
function Json($Object) {
    # Windows PowerShell 5.1 emits no text for a root $null. Persist the JSON
    # literal explicitly; false, zero, empty strings and arrays keep their type.
    if ($null -eq $Object) { return 'null' }
    return ConvertTo-Json -InputObject $Object -Depth 60 -ErrorAction Stop
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Read-Text $Path | ConvertFrom-Json -ErrorAction Stop)
}
function Write-Json([string]$Path, $Object) {
    [byte[]]$bytes=[Text.Encoding]::UTF8.GetBytes((Json $Object))
    Write-AtomicBytes $Path $bytes
}
function Read-Text([string]$Path, [long]$Limit=8388608) {
    $before=Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($before.Length -gt $Limit) { throw 'Fichier local trop volumineux.' }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=$null
    try {
        if ($stream.Length -gt $Limit) { throw 'Limite de lecture depassee.' }
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        $text=$reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { $reader.Dispose() } else { $stream.Dispose() }
    }
    $after=Get-Item -LiteralPath $Path
    if ($before.Length -ne $after.Length -or $before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc) {
        throw 'Source modifiee pendant la lecture; relancer apres le chargement de Xbox app.'
    }
    return $text
}
function Read-Xml([string]$Path) {
    $settings=New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $inputReader=New-Object IO.StringReader (Read-Text $Path)
    $reader=[Xml.XmlReader]::Create($inputReader,$settings)
    try {
        $doc=New-Object Xml.XmlDocument
        $doc.XmlResolver=$null
        $doc.Load($reader)
        return ,$doc
    } finally { $reader.Dispose(); $inputReader.Dispose() }
}
function Redact([string]$Text) {
    $value=$Text
    foreach ($pair in @(@($env:LOCALAPPDATA,'%LOCALAPPDATA%'),@($env:APPDATA,'%APPDATA%'),@($env:USERPROFILE,'%USERPROFILE%'))) {
        if ($pair[0]) {
            foreach ($s in @([string]$pair[0],([string]$pair[0]).Replace('\','\\'))) {
                $value=[regex]::Replace($value,[regex]::Escape($s),[string]$pair[1],'IgnoreCase')
            }
        }
    }
    $value=[regex]::Replace($value,'(?i)[A-Z]:\\{1,2}Users\\{1,2}[^\\/"\r\n]+','%USERPROFILE%')
    $value=[regex]::Replace($value,'(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b','<courriel>')
    $value=[regex]::Replace($value,'(?i)\bS-1-(?:\d+-){1,14}\d+\b','<SID>')
    return $value
}
function Note([string]$Area,[string]$Message) {
    [void]$script:Notes.Add([ordered]@{area=$Area;message=(Redact $Message)})
}
function Reset-Notes { $script:Notes=New-Object 'Collections.Generic.List[object]' }
Reset-Notes
function Local-Path([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { return $false }
    try {
        $drive=New-Object IO.DriveInfo ($Path.Substring(0,3))
        return $drive.DriveType -in @([IO.DriveType]::Fixed,[IO.DriveType]::Removable)
    } catch { return $false }
}
function Unique-Paths($Paths) {
    # Explicit case-insensitive set: fixes duplicate Steam manifests in audit 1.0.0.
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($Paths)) {
        if (-not $p) { continue }
        try { $n=[IO.Path]::GetFullPath(([string]$p).Trim('"')).TrimEnd('\','/') } catch { continue }
        if ($seen.Add($n)) { $n }
    }
}
function Vdf-Value([string]$Text,[string]$Name) {
    $m=[regex]::Match($Text,'(?im)"'+[regex]::Escape($Name)+'"\s*"((?:\\.|[^"\\])*)"')
    if ($m.Success) { return $m.Groups[1].Value.Replace('\\','\').Replace('\"','"') }
    return $null
}
function Stable-Id([string]$Key) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $h=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key.ToLowerInvariant()))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    # Private UUIDv8 layout; scoped DELETE can only affect this namespace.
    return '706c6f73-7862-8'+$h.Substring(0,3)+'-8'+$h.Substring(3,3)+'-'+$h.Substring(6,12)
}
function Same($A,$B) {
    return (Canonical $A) -ceq (Canonical $B)
}
function Canonical($Object) {
    if ($null -eq $Object) { return 'null' }
    if ($Object -is [Collections.IDictionary] -or $Object.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $parts=@()
        foreach ($k in @(Keys $Object | Sort-Object)) {
            if ($Object -is [Collections.IDictionary]) { $v=$Object[$k] }
            else { $v=$Object.PSObject.Properties[$k].Value }
            $parts+=((ConvertTo-Json -InputObject ([string]$k) -Compress)+':'+(Canonical $v))
        }
        return '{'+($parts -join ',')+'}'
    }
    if ($Object -is [Collections.IEnumerable] -and $Object -isnot [string]) {
        $parts=@(); foreach ($x in $Object) { $parts+=Canonical $x }; return '['+($parts -join ',')+']'
    }
    return ConvertTo-Json -InputObject $Object -Compress
}
function Clean-App($App) {
    $r=To-Map (Clone-Object $App)
    foreach ($name in @($script:LegacyFields.Keys)) {
        $old=$script:LegacyFields[$name]
        if ($r.Contains($old)) {
            if (-not $r.Contains($name)) { $r[$name]=$r[$old] }
            $r.Remove($old)
        }
    }
    foreach ($k in $script:TransientFields) { $r.Remove($k) }
    # VibeShine POST omits empty detached/prep-cmd arrays; compare the same form.
    foreach ($k in @('detached','prep-cmd')) {
        if ($r.Contains($k)) {
            $v=$r[$k]
            if ($null -eq $v -or ($v -is [string] -and $v.Length -eq 0) -or ($v -is [Collections.ICollection] -and $v.Count -eq 0)) { $r.Remove($k) }
        }
    }
    return ,$r
}
function Matches-Fields($Object,$Expected) {
    foreach ($k in @(Keys $Expected)) {
        if (-not (Same (Field $Object $k) (Field $Expected $k))) { return $false }
    }
    return $true
}
function Owned($App,[string]$Key) {
    return (Field $App 'opi5-xbox-owner') -in @($script:Owner,$script:LegacyOwner) -and
        (Field $App 'opi5-xbox-key') -eq $Key -and
        (Field $App 'uuid') -eq (Stable-Id $Key)
}
function Init-Native {
    if (-not ('OPi5Native' -as [type])) { Add-Type -Path @((Join-Path $PSScriptRoot 'Native.cs'),(Join-Path $PSScriptRoot 'TransportTests.cs')) -ErrorAction Stop }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
}

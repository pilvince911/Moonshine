#Requires -Version 5.1
function Parse-GuiHostPreferences([string]$Text) {
    $allowed=@('capture','encoder','virtual_display_mode','frame_limiter_enable','frame_limiter_provider','rtss_frame_limit_type',
        'rtss_install_path','rtss_allow_virtual_display_override','frame_limiter_auto_virtual_framegen','frame_limiter_disable_vsync','nvenc_preset')
    $values=@{}
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$' -and $Matches[1] -in $allowed) {
            $name=$Matches[1];$value=$Matches[2]
            if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) { $value=$value.Substring(1,$value.Length-2) }
            $values[$name]=$value
        }
    }
    return $values
}
function Read-GuiHostPreferences {
    $paths=@((Join-Path $env:ProgramFiles 'VibeShine\config\sunshine.conf'),(Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.conf'))
    $values=@{};$found=$false
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $values=Parse-GuiHostPreferences (Read-Text $path 262144)
            $found=$true;break
        } catch { }
    }
    return @{found=$found;values=$values}
}
function Get-GuiDiagnostics($Apps,[string]$SelectedId) {
    $hostSettings=Read-GuiHostPreferences
    $app=@($Apps | Where-Object { (Field $_ 'uuid') -eq $SelectedId } | Select-Object -First 1)
    $overrides=$(if ($app.Count -eq 1) { Field $app[0] 'config-overrides' } else { $null })
    $rows=New-Object 'Collections.Generic.List[OPi5GuiDiagnostic]'
    function Row([string]$Name,[string]$Value,[string]$Source) {
        $r=New-Object OPi5GuiDiagnostic;$r.Name=$Name;$r.Value=$Value;$r.Source=$Source;[void]$rows.Add($r)
    }
    function Preference([string]$Name,[string]$Key,[string]$Default) {
        if ($Key -in @(Keys $overrides)) { Row $Name ([string](Field $overrides $Key)) 'Exception de ce jeu' }
        elseif ($hostSettings.values.ContainsKey($Key)) { Row $Name ([string]$hostSettings.values[$Key]) 'Fichier local trouvé' }
        elseif ($hostSettings.found) { Row $Name $Default 'Valeur non imposée' }
        else { Row $Name 'Configuration non lue' 'À vérifier dans VibeShine' }
    }
    try {
        $names=@(Get-CimInstance -ClassName Win32_VideoController -OperationTimeoutSec 3 -ErrorAction Stop | Select-Object -ExpandProperty Name -First 4)
        Row 'Carte graphique' ($names -join ', ') 'Windows'
    } catch { Row 'Carte graphique' 'Détection indisponible' 'Windows' }
    Preference 'Capture' 'capture' 'Automatique'
    Preference 'Écran virtuel' 'virtual_display_mode' 'Selon VibeShine / le client'
    Preference 'Limiteur' 'frame_limiter_enable' 'Selon VibeShine'
    Preference 'Mode RTSS' 'rtss_frame_limit_type' 'Reflex automatique possible sur écran virtuel'
    Preference 'Cadence virtuelle' 'frame_limiter_auto_virtual_framegen' 'Politique automatique du logiciel'
    Preference 'V-Sync du pilote' 'frame_limiter_disable_vsync' 'Aucune exception imposée ici'
    Preference 'Encodeur' 'encoder' 'Automatique'
    Preference 'Préréglage NVENC' 'nvenc_preset' 'Selon VibeShine'
    $candidates=@()
    $configured=[string](Field $hostSettings.values 'rtss_install_path')
    if ($configured -and (Local-Path $configured)) { $candidates+=Join-Path $configured 'RTSS.exe' }
    foreach ($base in @(${env:ProgramFiles(x86)},$env:ProgramFiles)) {
        if ($base) { $candidates+=Join-Path $base 'RivaTuner Statistics Server\RTSS.exe' }
    }
    $rtss=@($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    Row 'RTSS' $(if ($rtss.Count) {'Détecté sur disque; intégration à vérifier'} else {'Non détecté aux emplacements connus'}) 'Fichiers locaux'
    if ($app.Count -eq 1) {
        Row 'Frame Generation' ([string](Field $app[0] 'frame-generation-mode' 'Non défini par cette entrée')) 'Entrée VibeShine'
        $sdr=Field $app[0] 'prefer-10bit-sdr'
        Row 'SDR 10 bits' $(if ($null -eq $sdr) {'Préférence du client'} elseif ($sdr) {'Préféré par cette entrée'} else {'Non forcé'}) 'Entrée VibeShine'
    }
    Row 'HDR et fréquence du flux' 'À valider avec le client et l''écran; aucun plafond universel imposé' 'Négociation de la session'
    return $rows.ToArray()
}

#Requires -Version 5.1
# Source packages keep the historical production root. Trial bundles carry
# per-user markers and can never fall back to that root without their context.
function Get-MoonshineTrialId([string]$Folder=$PSScriptRoot) {
    $id=[string]$env:MOONSHINE_TRIAL_ID
    $marker=Join-Path $Folder 'moonshine-trial-id.txt'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $info=Get-Item -LiteralPath $marker -ErrorAction Stop
        if ($info.Length -gt 128) { throw 'Identifiant de l essai invalide.' }
        $saved=[IO.File]::ReadAllText($marker).Trim()
        if ($id -and $id -cne $saved) { throw 'Le contexte ne correspond pas a cet essai Moonshine.' }
        $id=$saved
    }
    if ($id -and $id -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Identifiant de l essai Moonshine invalide.' }
    if (-not $id -and (Test-Path -LiteralPath (Join-Path $Folder 'moonshine-trial-only.txt'))) { throw 'Ouvrir cet essai avec Demarrer-Moonshine.cmd; aucun acces aux donnees de production.' }
    return $id
}
function Get-MoonshineDataRoot([string]$TrialId=(Get-MoonshineTrialId),[string]$LocalData=[Environment]::GetFolderPath('LocalApplicationData')) {
    if (-not $TrialId) { return Join-Path $LocalData 'OPi5\VibeShine-Xbox' }
    if ($TrialId -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Identifiant de l essai Moonshine invalide.' }
    return Join-Path $LocalData ('OPi5\Moonshine-Trial\'+$TrialId+'\Sync')
}
function Set-MoonshineTrialMarkers([string]$Folder,[string]$TrialId=(Get-MoonshineTrialId)) {
    if (-not $TrialId) { return }
    if ($TrialId -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Identifiant de l essai Moonshine invalide.' }
    $existing=Join-Path $Folder 'moonshine-trial-id.txt'
    if ((Test-Path -LiteralPath $existing) -and [IO.File]::ReadAllText($existing).Trim() -cne $TrialId) { throw 'Copie de secours appartenant a un autre essai; conservation des fichiers.' }
    Write-AtomicBytes (Join-Path $Folder 'moonshine-trial-only.txt') ([Text.Encoding]::ASCII.GetBytes("Moonshine trial only`r`n"))
    Write-AtomicBytes $existing ([Text.Encoding]::ASCII.GetBytes($TrialId+"`r`n"))
}
function Assert-MoonshineTrialEndpoint([string]$Url) {
    if ((Get-MoonshineTrialId) -and $Url -cne 'https://127.0.0.1:48990') { throw 'Cet essai utilise uniquement son interface locale sur le port 48990.' }
}

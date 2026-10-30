#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
function Get-MoonshineManagerModel($Evidence) {
    $model=@{action='';primary='';title='';detail='';enabled=$false;installed=[bool]$Evidence.installed;running=[bool]$Evidence.running;install_step='A faire';driver_step='A verifier';run_step='Arrete'}
    if ($Evidence.installed) {$model.install_step='Installe'}
    if ($Evidence.drivers) {$model.driver_step='Presents'}
    if ($Evidence.running) {$model.run_step='En marche'}
    if ($Evidence.blocked) { $model.title='Verification requise';$model.primary='Action suspendue';$model.detail=[string]$Evidence.message;return $model }
    if ($Evidence.busy) { $model.title='Operation en cours';$model.primary='Patientez';$model.detail='La progression apparait ci-dessous.';return $model }
    if (-not $Evidence.installed) {
        $model.title='Bienvenue dans Moonshine';$model.primary='Installer Moonshine';$model.action='Install';$model.enabled=(-not $Evidence.running)
        $model.detail=if ($Evidence.running) {'Arretez l ancien hote avant de continuer.'} else {'Programme, service Windows et icone de session. Les jeux restent dans leurs lanceurs.'};return $model
    }
    if ($Evidence.running) { $model.title='Moonshine est en marche';$model.primary='Ouvrir la bibliotheque';$model.action='Open';$model.enabled=$true;$model.detail=if($Evidence.update){'Une mise a jour est prete. Arretez le service pour l appliquer.'}else{'La gestion quotidienne se fait par l icone pres de l horloge.'};return $model }
    if ($Evidence.update -or -not $Evidence.service_present) { $model.title='Moonshine est pret a etre mis a jour';$model.primary=if($Evidence.update){'Mettre a jour Moonshine'}else{'Reenregistrer le service'};$model.action='Install';$model.enabled=$true;$model.detail='Catalogue, reglages et appairage sont conserves.';return $model }
    if ($Evidence.reboot) { $model.title='Redemarrage Windows requis';$model.primary='Redemarrez Windows';$model.detail='Les pilotes sont prepares. Reprenez depuis l icone apres le redemarrage.';$model.driver_step='Redemarrage requis';return $model }
    if (-not $Evidence.drivers) { $model.title='Preparons les pilotes';$model.primary='Preparer les pilotes signes';$model.action='Drivers';$model.enabled=$true;$model.detail='Cette etape verifie et prepare l ecran virtuel et les manettes.';return $model }
    $model.title='Moonshine est pret';$model.primary='Demarrer Moonshine';$model.action='Start';$model.enabled=$true;$model.detail='Ouvrez ensuite la bibliotheque depuis l icone pour gerer vos jeux.';return $model
}
function Read-MoonshineManagerEvidence([string]$OwnerSid,[string]$SourceCommit,[switch]$RefreshDevices) {
    $e=@{installed=$false;running=$false;drivers=$false;reboot=$false;service_present=$false;update=$false;blocked=$false;automatic=$true;message=''}
    try {
        $selected=Get-MoonshineSetupService $OwnerSid
        if ($selected) { $e.running=$selected.Service.State -eq 'Running';$e.service_present=-not $selected.Preview;$e.automatic=$selected.Service.StartMode -eq 'Auto' }
        if ([IO.File]::Exists((Join-Path $script:MoonshineServiceRoot 'service-receipt.json'))) {
            $receipt=Read-MoonshineServiceReceipt
            if ($receipt.mode -cne 'installed' -or $receipt.owner_sid -cne $OwnerSid) { throw 'Cette installation est rattachee a un autre compte ou a un profil inconnu.' }
            $e.installed=$true;$e.update=$receipt.commit -cne $SourceCommit;$e.version=[string]$receipt.version
            if ($receipt.phase -eq 'repairing') { $e.update=$true }
            if ($RefreshDevices -or $null -eq $script:MoonshineDeviceStatus) {
                $display=@(Get-MoonshineDriverNodes 'Root\SunshineVirtualDisplay');$gamepad=@(Get-MoonshineDriverNodes 'ROOT\VIBESHINEVIRTUALGAMEPAD')
                $script:MoonshineDeviceStatus=$display.Count -gt 0 -and $gamepad.Count -gt 0 -and @(@($display)+@($gamepad) | Where-Object {[int]$_.ConfigManagerErrorCode -ne 0}).Count -eq 0
            }
            $e.drivers=[bool]$script:MoonshineDeviceStatus
            $file=Join-Path $script:MoonshineServiceRoot 'driver-result.json'
            if ([IO.File]::Exists($file) -and (Get-Item -LiteralPath $file).Length -lt 8192) {
                $driver=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file))
                if ($driver.schema -ceq 'moonshine-driver-result/1' -and $driver.restart_required) {
                    if (-not $script:MoonshineBootTime) { $script:MoonshineBootTime=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() }
                    $e.reboot=([datetime]::Parse($driver.time).ToUniversalTime() -gt $script:MoonshineBootTime)
                }
            }
        }
    } catch { $e.blocked=$true;$e.message=$_.Exception.Message }
    return $e
}
function New-MoonshineManagerSignal([string]$OwnerSid,[string]$Purpose) {
    if ($Purpose -cnotin @('Show','Uninstall','Release') -or $OwnerSid -cnotmatch '\AS-1-(?:5-21|12-1)-[0-9-]+\z') { throw 'Signal de fenetre inconnu.' }
    $security=New-Object Security.AccessControl.EventWaitHandleSecurity
    foreach ($sid in @($OwnerSid,'S-1-5-18')) { $security.AddAccessRule((New-Object Security.AccessControl.EventWaitHandleAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),[Security.AccessControl.EventWaitHandleRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))) }
    $created=$false
    return [Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,('Local\Moonshine.Manager.'+$Purpose+'.'+$OwnerSid),[ref]$created,$security)
}
function Read-MoonshineOperation([string]$OwnerSid,[string]$OperationId,[string]$Action) {
    $file=Join-Path (Get-MoonshineOperationFolder $OwnerSid $OperationId) 'operation.json'
    if (-not [IO.File]::Exists($file)) { return $null }
    Assert-MoonshinePlainPath $file
    if ((Get-Item -LiteralPath $file).Length -gt 16384) { throw 'Compte rendu d operation trop volumineux.' }
    $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file))
    if ($value.schema -cne 'moonshine-operation/1' -or $value.id -cne $OperationId -or $value.owner_sid -cne $OwnerSid -or $value.action -cne $Action -or $value.phase -cnotin @('running','completed','failed') -or [int]$value.percent -lt 0 -or [int]$value.percent -gt 100) { throw 'Compte rendu d operation non reconnu.' }
    return $value
}

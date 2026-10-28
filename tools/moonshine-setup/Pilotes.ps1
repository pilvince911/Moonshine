#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
function Get-MoonshineDriverNodes([string]$HardwareId) {
    return @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { @($_.HardwareID) -icontains $HardwareId })
}
function Get-MoonshineInfVersion([string]$Path) {
    $matches=[regex]::Matches([IO.File]::ReadAllText($Path),'(?im)^\s*DriverVer\s*=\s*[^,]+,\s*(\d+\.\d+\.\d+\.\d+)\s*$')
    if ($matches.Count -ne 1) { throw 'Version du pilote inconnue; aucun remplacement.' }
    return [version]$matches[0].Groups[1].Value
}
function Assert-MoonshineNodeRepairVersion([string]$Inf) {
    $target=Get-MoonshineInfVersion $Inf
    $name=[IO.Path]::GetFileName($Inf)
    foreach ($package in @(Get-WindowsDriver -Online -All -ErrorAction Stop | Where-Object { [IO.Path]::GetFileName([string]$_.OriginalFileName) -ieq $name })) {
        $path=[string]$package.OriginalFileName
        if (-not [IO.Path]::IsPathRooted($path)) {
            $published=[string]$package.Driver
            if ($published -notmatch '^oem\d+\.inf$') { throw 'Identite du magasin de pilotes inconnue.' }
            $path=Join-Path $env:WINDIR ('INF\'+$published)
        }
        if ((Get-MoonshineInfVersion $path) -gt $target) { throw 'Un pilote plus recent est conserve. Sa version correspondante est requise pour reparer le peripherique absent.' }
    }
}
function Invoke-MoonshineDriverTool([string]$File,[string[]]$Arguments) {
    & $File @Arguments | Out-Host
    if ($LASTEXITCODE -notin @(0,3010)) { throw ('Preparation du pilote refusee : '+[IO.Path]::GetFileName($File)+' (code '+$LASTEXITCODE+'). Les parametres de securite Windows restent inchanges.') }
    return [int]$LASTEXITCODE
}
function Install-MoonshineDrivers([string]$OwnerSid) {
    Assert-MoonshineAdmin;Assert-MoonshineSetupIdle
    $receipt=Read-MoonshineServiceReceipt
    if ($receipt.owner_sid -cne $OwnerSid) { throw 'Cette installation appartient a un autre compte Windows.' }
    $null=Read-MoonshineServiceManifest (Join-Path $script:MoonshineServiceRoot 'Kit')
    Assert-MoonshineInstalledPackage $receipt
    $drivers=Join-Path $script:MoonshineServiceRoot 'Package\drivers'
    $proof=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $drivers 'provenance.json')))
    if ($proof.schema -cne 'moonshine-prerequisites/1' -or $proof.source_sha256 -cne 'b46abb8a778de59b33fa5fa853819c1144f548be0d3db487a704e505c5b64838' -or $proof.display_validation -cne 'passed' -or $proof.gamepad_validation -cne 'passed' -or $proof.gamepad_protocol -ne 2) { throw 'Provenance des pilotes non reconnue.' }
    $display=Join-Path $drivers 'sunshine';$gamepad=Join-Path $drivers 'vhf-gamepad'
    # These are the unmodified scripts and signed binaries extracted from the pinned public package.
    foreach ($file in @((Join-Path $display 'SunshineVirtualDisplayDriver.cat'),(Join-Path $gamepad 'driver\VibeshineVhfGamepad.cat'),(Join-Path $gamepad 'tools\VibeshineVhfGamepadDeviceSetup.exe'))) {
        $signature=Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ine 'CN=SignPath Foundation, O=SignPath Foundation, L=Lewes, S=Delaware, C=US') { throw 'La signature du pilote n est pas acceptee par Windows. Aucun contournement de securite.' }
    }
    $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe';$reboot=$false
    $reboot=(Invoke-MoonshineDriverTool $ps @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $display 'install.ps1'))) -eq 3010 -or $reboot
    $reboot=(Invoke-MoonshineDriverTool $ps @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $gamepad 'install.ps1'))) -eq 3010 -or $reboot
    # Older uninstallers can remove a root device while retaining an equal INF in Driver Store.
    # The vendor's no-downgrade guard then skips staging. Recreate only the missing owned node.
    if (@(Get-MoonshineDriverNodes 'Root\SunshineVirtualDisplay').Count -eq 0) {
        $inf=Join-Path $display 'SunshineVirtualDisplayDriver.inf';Assert-MoonshineNodeRepairVersion $inf
        $null=Invoke-MoonshineDriverTool (Join-Path $display 'nefconc.exe') @('--create-device-node','--class-name','Display','--class-guid','{4D36E968-E325-11CE-BFC1-08002BE10318}','--hardware-id','Root\SunshineVirtualDisplay')
        $null=Invoke-MoonshineDriverTool (Join-Path $env:WINDIR 'System32\pnputil.exe') @('/add-driver',$inf,'/install')
    }
    if (@(Get-MoonshineDriverNodes 'ROOT\VIBESHINEVIRTUALGAMEPAD').Count -eq 0) {
        $inf=Join-Path $gamepad 'driver\VibeshineVhfGamepad.inf';Assert-MoonshineNodeRepairVersion $inf
        $reboot=(Invoke-MoonshineDriverTool (Join-Path $gamepad 'tools\VibeshineVhfGamepadDeviceSetup.exe') @('install','--inf',$inf)) -eq 3010 -or $reboot
    }
    $null=Invoke-MoonshineDriverTool $ps @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $display 'install.ps1'),'-RegisterVulkanLayerOnly')
    $displayNodes=@(Get-MoonshineDriverNodes 'Root\SunshineVirtualDisplay');$gamepadNodes=@(Get-MoonshineDriverNodes 'ROOT\VIBESHINEVIRTUALGAMEPAD')
    $result=@{schema='moonshine-driver-result/1';time=(Get-Date).ToString('o');source_sha256=$proof.source_sha256;display_present=($displayNodes.Count -gt 0);gamepad_present=($gamepadNodes.Count -gt 0);restart_required=$reboot}
    Write-MoonshineServiceJson (Join-Path $script:MoonshineServiceRoot 'driver-result.json') $result
    if (-not $result.display_present -or -not $result.gamepad_present) { throw 'Preparation executee mais peripherique non confirme. Redemarrer Windows puis reprendre la verification avant le streaming.' }
    if ($reboot) { Write-Host 'Un redemarrage Windows est requis pour terminer les pilotes.' -ForegroundColor Yellow }
    return $result
}

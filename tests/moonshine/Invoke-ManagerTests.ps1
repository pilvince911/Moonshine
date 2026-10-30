#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'tools\moonshine-setup\Installation.ps1')
. (Join-Path $root 'tools\moonshine-setup\Manager-State.ps1')
$checks=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Refuses([scriptblock]$Action,[string]$Message){$bad=$false;try{& $Action|Out-Null}catch{$bad=$true};Check $bad $Message}
function Evidence {return @{installed=$false;running=$false;drivers=$false;reboot=$false;service_present=$false;update=$false;blocked=$false;busy=$false;message='guard'}}
$e=Evidence;Check ((Get-MoonshineManagerModel $e).action -ceq 'Install') 'Fresh setup must lead with installation.'
$e.installed=$true;$e.service_present=$true;Check ((Get-MoonshineManagerModel $e).action -ceq 'Drivers') 'Missing drivers must lead with their explicit preparation.'
$e.drivers=$true;Check ((Get-MoonshineManagerModel $e).action -ceq 'Start') 'A healthy stopped installation must lead with Start.'
$e.reboot=$true;Check (-not (Get-MoonshineManagerModel $e).enabled) 'A pending required reboot must not offer Start.'
$e.reboot=$false;$e.running=$true;Check ((Get-MoonshineManagerModel $e).action -ceq 'Open') 'A running installation must lead with its library.'
$e.running=$false;$e.update=$true;Check ((Get-MoonshineManagerModel $e).action -ceq 'Install') 'A stopped earlier version must offer in-place update.'
$e.blocked=$true;Check (-not (Get-MoonshineManagerModel $e).enabled) 'Unknown ownership must disable the primary action.'
$e.blocked=$false;$e.busy=$true;Check (-not (Get-MoonshineManagerModel $e).enabled) 'A running operation must prevent duplicate commands.'
$e=Evidence;$e.installed=$true;Check ((Get-MoonshineManagerModel $e).action -ceq 'Install') 'An installed profile with an absent service must offer re-registration.'
$temporary=Join-Path $env:TEMP ('moonshine-manager-tests-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$script:MoonshineServiceRoot;$oldKey=$script:MoonshineUninstallKey
try {
 [IO.Directory]::CreateDirectory($temporary)|Out-Null
 & (Join-Path $root 'tools\moonshine-setup\Gestion-Moonshine.ps1') -ValidateWindowOnly -PreviewPath (Join-Path $root 'build-evidence\moonshine-rc2-window.png')
 Check ([IO.File]::Exists((Join-Path $root 'build-evidence\moonshine-rc2-window.png'))) 'The actual WPF view must render to a PNG.'
 $script:MoonshineServiceRoot=$temporary
 $command=Get-MoonshineManagerCommand
 Check ($command.EndsWith(' -TrayOnly') -and $command.Contains('Gestion-Moonshine.ps1')) 'Session startup must launch only the normal tray companion.'
 Check ((Get-MoonshineManagerCommand -Uninstall).Contains('Desinstaller-Moonshine.ps1')) 'Windows Apps must call the owned uninstaller entry.'
 # Test a real isolated registry entry. Production registration is covered by SCM smoke.
 $script:MoonshineUninstallKey='SOFTWARE\Moonshine-CI-Tests\'+[guid]::NewGuid().ToString('N')
 $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
 $key=$base.CreateSubKey($script:MoonshineUninstallKey)
 try{$key.SetValue('DisplayName','foreign entry')}finally{$key.Dispose()}
 $receipt=@{id=('a'*32);owner_sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;version='1.0.0-rc.2'}
 Refuses {Assert-MoonshineDesktopRegistration $receipt} 'A foreign registration must never be overwritten.'
 $key=$base.OpenSubKey($script:MoonshineUninstallKey,$true)
 try{foreach($entry in @{MoonshineSchema='moonshine-desktop/1';MoonshineId=$receipt.id;MoonshineOwner=$receipt.owner_sid;InstallLocation=$temporary;UninstallString=(Get-MoonshineManagerCommand -Uninstall)}.GetEnumerator()){$key.SetValue($entry.Key,$entry.Value)}}finally{$key.Dispose()}
 Assert-MoonshineDesktopRegistration $receipt;Check $true 'The exact owned registration must be recognized.'
 $receipt.owner_sid='S-1-5-21-1-2-3-1001';Refuses {Assert-MoonshineDesktopRegistration $receipt} 'A different Windows account must not claim the registration.'
 $base.DeleteSubKeyTree($script:MoonshineUninstallKey);$base.Dispose();$base=$null
 # A stopped profile may legitimately contain an empty log. Export still has
 # to succeed, while excluding token lines and anonymizing paths/addresses.
 $receipt.owner_sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $files=@();foreach($name in @('one','two','three','four')){$files+=@(@{path=('Package/'+$name);sha256=('c'*64)})}
 Write-MoonshineServiceJson (Join-Path $temporary 'service-receipt.json') @{schema='moonshine-service-receipt/1';mode='installed';name='MoonshineService';id=$receipt.id;owner_sid=$receipt.owner_sid;commit=('d'*40);version='1.0.0-rc.2';phase='installed';files=$files;firewall_created=$false}
 $logs=Join-Path $temporary 'Package\config';[IO.Directory]::CreateDirectory($logs)|Out-Null
 [IO.File]::WriteAllText((Join-Path $logs 'empty.log'),'')
 [IO.File]::WriteAllLines((Join-Path $logs 'privacy.log'),[string[]]@('token=do-not-export',($env:USERPROFILE+'\private 192.168.1.4')))
 $output=Join-Path $temporary 'diagnostic-output';[IO.Directory]::CreateDirectory($output)|Out-Null
 $diag=Export-MoonshineSetupDiagnostic $receipt.owner_sid $output
 $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $output $diag.file))
 try {
  $empty=$zip.GetEntry('empty.log');Check ($null -ne $empty -and $empty.Length -eq 0) 'An empty log must export as an empty entry.'
  $reader=New-Object IO.StreamReader($zip.GetEntry('privacy.log').Open());try{$safe=$reader.ReadToEnd()}finally{$reader.Dispose()}
  Check (-not $safe.Contains('do-not-export') -and -not $safe.Contains($env:USERPROFILE) -and -not $safe.Contains('192.168.1.4') -and $safe.Contains('[adresse IP]')) 'Diagnostic export leaked a token, profile path or IP address.'
 }finally{$zip.Dispose()}
 Refuses {Get-MoonshineOperationFolder 'S-1-5-18' ('a'*32)} 'SYSTEM may not substitute for the selected interactive owner.'
 Refuses {Get-MoonshineOperationFolder ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) '..\outside'} 'An operation id must never carry an output path.'
 Write-Output ('Moonshine RC2 manager: '+$checks+' state/WPF/registry/operation checks passed.')
}finally{
 if($base){$base.DeleteSubKeyTree($script:MoonshineUninstallKey,$false);$base.Dispose()}
 $script:MoonshineServiceRoot=$oldRoot;$script:MoonshineUninstallKey=$oldKey
 if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
exit 0

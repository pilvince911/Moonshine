#Requires -Version 5.1
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:CI -ne 'true'){throw 'Disposable runner required.'}
. (Join-Path $PSScriptRoot 'Test-User.ps1')
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'tools\moonshine-setup\Installation.ps1')
. (Join-Path $repo 'tools\moonshine-setup\Manager-State.ps1')
if(Get-Service -Name MoonshineService,SunshineService -ErrorAction SilentlyContinue){throw 'An existing host service must never be changed.'}
if(Test-Path -LiteralPath $script:MoonshineServiceRoot){throw 'An existing Moonshine root must never be changed.'}
Add-Type -Path (Join-Path $PSScriptRoot 'test_user_process.cs')
$folder=Join-Path $env:PUBLIC ('MoonshineTrayProbe-'+[guid]::NewGuid().ToString('N'))
$testUser=$null;$child=$null;$release=$null;$created=$false
try{
 [IO.Directory]::CreateDirectory($folder)|Out-Null
 $testUser=New-MoonshineCITestUser;Grant-MoonshineCITestFolder $folder $testUser
 $sid=(New-Object Security.Principal.NTAccount($env:COMPUTERNAME,$testUser.Name)).Translate([Security.Principal.SecurityIdentifier]).Value
 $kit=Join-Path $folder 'kit';Copy-Item -LiteralPath (Join-Path $repo 'tools\moonshine-setup') -Destination $kit -Recurse
 $commit='c'*40;[IO.File]::WriteAllText((Join-Path $kit 'build-info.json'),(ConvertTo-Json @{commit=$commit;version='1.0.0-rc.2'}))
 Set-MoonshineProtectedFolder $script:MoonshineServiceRoot;$created=$true
 $files=@();foreach($name in @('one','two','three','four')){$files+=@(@{path=('Package/'+$name);sha256=('d'*64)})}
 Write-MoonshineServiceJson (Join-Path $script:MoonshineServiceRoot 'service-receipt.json') @{schema='moonshine-service-receipt/1';mode='installed';name='MoonshineService';id=('b'*32);owner_sid=$sid;commit=$commit;version='1.0.0-rc.2';phase='installed';firewall_created=$false;files=$files}
 $release=New-MoonshineManagerSignal $sid 'Release'
 $trace=Join-Path $folder 'ready.json';$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 # The logon API creates the new user's environment instead of inheriting CI
 # flags. Set only these non-secret fixture flags in a reviewed local bootstrap.
 $bootstrap=Join-Path $folder 'start-tray.ps1'
 $code='[IO.File]::WriteAllText('''+($trace+'.phase').Replace("'","''")+''',''bootstrap-entered''+[Environment]::NewLine);$env:GITHUB_ACTIONS=''true'';$env:CI=''true'';& '''+(Join-Path $kit 'Gestion-Moonshine.ps1').Replace("'","''")+''' -TrayOnly -CITrace '''+$trace.Replace("'","''")+''''
 [IO.File]::WriteAllText($bootstrap,$code,(New-Object Text.UTF8Encoding($true)))
 $command='"'+$ps+'" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "'+$bootstrap+'"'
 $child=[MoonshineTestUserProcess]::Start($command,$env:WINDIR,$testUser.Name,$testUser.Password)
 for($n=0;$n -lt 480 -and -not [IO.File]::Exists($trace) -and -not $child.HasExited;$n++){Start-Sleep -Milliseconds 250}
 if(-not [IO.File]::Exists($trace)){$phase=if([IO.File]::Exists($trace+'.phase')){[IO.File]::ReadAllText($trace+'.phase')}else{'script not reached'};throw ('Normal-account tray startup did not report ready; exited='+$child.HasExited+'; phases='+$phase)}
 $data=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($trace))
 if($data.error){throw ('Normal tray error: '+$data.error+'; '+$data.stack)}
 if($data.admin -or $data.system -or $data.sid -cne $sid -or -not $data.icon_visible -or $data.window_visible -or $data.service_running){throw 'The tray did not start hidden with its normal selected identity.'}
 foreach($name in @('Open','Start','Stop','Manage','Maintenance','Exit')){if($data.menu_items -cnotcontains $name){throw ('Tray action missing: '+$name)}}
 $null=$release.Set();if(-not $child.WaitForExit(20000)){throw 'The tray did not honor its owner-scoped exit signal.'}
 if($child.ExitCode -ne 0 -or (Get-Service -Name MoonshineService -ErrorAction SilentlyContinue)){throw 'Exiting the tray changed a service or returned an error.'}
 Write-Output 'Moonshine RC2 tray: actual normal-account process, NotifyIcon, context menu, hidden startup and cooperative exit passed; no host service or driver started.'
}finally{
 if($release){$null=$release.Set()}
 if($child -and -not $child.HasExited){$null=$child.WaitForExit(5000)}
 if(-not $child -or $child.HasExited){Remove-MoonshineCITestUser $testUser}
 if($child){$child.Dispose()};if($release){$release.Dispose()}
 if($created){Remove-Item -LiteralPath $script:MoonshineServiceRoot -Recurse -Force}
 if(Test-Path -LiteralPath $folder){Remove-Item -LiteralPath $folder -Recurse -Force}
}

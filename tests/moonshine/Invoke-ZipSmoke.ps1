#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$KitRoot,[string]$Evidence='build-evidence\service-smoke.json')
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:CI -ne 'true') { throw 'SCM qualification is restricted to a disposable GitHub Actions runner.' }
. (Join-Path ([IO.Path]::GetFullPath($KitRoot)) 'Installation.ps1')
Assert-MoonshineAdmin
if (Get-Service -Name 'MoonshineService','SunshineService' -ErrorAction SilentlyContinue) { throw 'An existing host service must never be changed by CI.' }
if (Test-Path -LiteralPath $script:MoonshineServiceRoot) { throw 'CI service destination already exists.' }
if (Get-MoonshineDesktopRegistration) { throw 'An existing Windows Apps registration must never be changed by CI.' }
$id=[guid]::NewGuid().ToString('N');$serviceOwnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$fixture=Join-Path $env:TEMP ('moonshine-zip-smoke-'+$id);[IO.Directory]::CreateDirectory($fixture) | Out-Null
$previewRoot=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine-Preview'
if (Test-Path -LiteralPath $previewRoot) { throw 'A pre-existing preview must never be modified by CI.' }
$dataRoots=@();$previewCreated=$false;$ownedRecovery=@();$ownedPrevious=@()
$record=@{status='starting';service='MoonshineService';id=$id;checks=0};$created=$false;$serviceHostPid=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$record.checks++ }
try {
    $null=Read-MoonshineServiceManifest $KitRoot
    $receipt=Install-MoonshineZip ([IO.Path]::GetFullPath($KitRoot)) $serviceOwnerSid -Automatic;$created=$true
    $desktop=Get-MoonshineDesktopRegistration
    Check ($desktop.DisplayVersion -ceq '1.0.0-rc.2' -and $desktop.MoonshineId -ceq $receipt.id -and $desktop.UninstallString -ceq (Get-MoonshineManagerCommand -Uninstall)) 'Windows Installed Apps registration is absent or bound to another command.'
    Check ((Get-MoonshineStartupCommand $serviceOwnerSid) -ceq (Get-MoonshineManagerCommand)) 'The selected account tray startup command was not registered.'
    $id=$receipt.id;$record.id=$id;$dataRoots+=@($receipt.data_root);$before=@{}
    Check ($receipt.data_root -notmatch 'OPi5|Moonshine-Trial' -and [IO.Directory]::Exists($receipt.data_root)) 'Fresh install depends on an old trial directory.'
    $personal=@{uuid='e9ece5ce-44e4-4de4-9cae-68f4992f20d4';name='CI personal entry';cmd='';detached=@();'prep-cmd'=@();'ci-preference'='keep'}
    Write-MoonshineServiceJson (Join-Path $script:MoonshineServiceRoot 'Package\config\apps.json') @{env=@{};apps=@($personal)}
    $receiptFile=Join-Path $script:MoonshineServiceRoot 'service-receipt.json'
    $receiptBytes=(Get-Item -LiteralPath $receiptFile).Length
    Check ($receiptBytes -lt 4194304 -and (Read-MoonshineServiceReceipt).id -ceq $id) 'The genuine package receipt could not be read after installation.'
    Check ($receipt.id -ceq $id -and $receipt.phase -eq 'installed') 'Verified service installation receipt missing.'
    $service=Get-MoonshineOwnedService;Check ($service.StartMode -eq 'Auto' -and $service.StartName -eq 'LocalSystem') 'Service account or manual startup changed.'
    foreach ($path in $before.Keys) { Check ((Get-FileHash -LiteralPath $path).Hash -ceq $before[$path]) 'Setup changed its stopped source profile.' }
    $target=Join-Path $script:MoonshineServiceRoot 'Package'
    $originalConfigHash=(Get-FileHash -LiteralPath (Join-Path $target 'config\moonshine.conf')).Hash
    $repairTarget=Join-Path $target 'tools\audio-info.exe';$expectedHash=(Get-FileHash -LiteralPath $repairTarget).Hash
    [IO.File]::WriteAllBytes($repairTarget,[byte[]](1,2,3))
    $receipt=Install-MoonshineZip (Join-Path $script:MoonshineServiceRoot 'Kit') $serviceOwnerSid -Automatic
    Check ((Get-FileHash -LiteralPath $repairTarget).Hash -ceq $expectedHash) 'The verified local kit could not repair its corrupted installed helper.'
    Check ((Get-FileHash -LiteralPath (Join-Path $target 'config\moonshine.conf')).Hash -ceq $originalConfigHash) 'Repair replaced personal host settings.'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $script:MoonshineServiceRoot 'Recovery') -Recurse -File | Where-Object { $_.Name -eq 'audio-info.exe' -and $_.Length -eq 3 }).Count -eq 1) 'Repair did not preserve its replaced bytes.'
    Check ((Get-MoonshineOwnedService).StartMode -eq 'Auto') 'Repair changed the selected service startup mode.'
    # An earlier installed-layout receipt is synthetic. The real compiled host
    # and personal profile are then upgraded through the different-commit path.
    $beforeId=$receipt.id;$beforeData=$receipt.data_root
    $appsBefore=(Get-FileHash -LiteralPath (Join-Path $target 'config\apps.json')).Hash
    $customFile=Join-Path $target 'config\personal-upgrade.txt';[IO.File]::WriteAllText($customFile,'keep this private personal file')
    Unregister-MoonshineDesktop $receipt
    $receipt=Read-MoonshineServiceReceipt;$receipt.commit='d'*40;$receipt.version='1.0.0-rc.1';Save-MoonshineServiceReceipt $receipt
    $previousBefore=@(Get-ChildItem -LiteralPath (Split-Path -Parent $script:MoonshineServiceRoot) -Directory -Filter 'Moonshine.Previous.*' | ForEach-Object {$_.FullName})
    $receipt=Install-MoonshineZip $KitRoot $serviceOwnerSid -Automatic
    $ownedPrevious+=@(Get-ChildItem -LiteralPath (Split-Path -Parent $script:MoonshineServiceRoot) -Directory -Filter 'Moonshine.Previous.*' | Where-Object {$_.FullName -notin $previousBefore} | ForEach-Object {$_.FullName})
    Check ($receipt.id -ceq $beforeId -and $receipt.data_root -ceq $beforeData -and $receipt.version -ceq '1.0.0-rc.2') 'In-place upgrade changed installation/library identity.'
    Check ((Get-FileHash -LiteralPath (Join-Path $target 'config\apps.json')).Hash -ceq $appsBefore -and [IO.File]::ReadAllText($customFile) -ceq 'keep this private personal file') 'In-place upgrade changed the personal catalogue or custom file.'
    Check ($ownedPrevious.Count -eq 1 -and (Get-MoonshineDesktopRegistration).DisplayVersion -ceq '1.0.0-rc.2') 'The previous program was not retained or Windows registration was not refreshed.'
    $cfg=Join-Path $target 'config\moonshine.conf';$text=[IO.File]::ReadAllText($cfg)
    $text=[regex]::Replace($text,'(?m)^virtual_display_mode\s*=.*$','virtual_display_mode = disabled')
    [IO.File]::WriteAllText($cfg,$text+"`r`nencoder = software`r`n")
    $privateAcl=Get-Acl -LiteralPath (Join-Path $target 'config')
    Check ($privateAcl.AreAccessRulesProtected -and @($privateAcl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544') }).Count -eq 0) 'Private host configuration is readable by ordinary users.'
    $rootAcl=Get-Acl -LiteralPath $script:MoonshineServiceRoot
    Check ($rootAcl.AreAccessRulesProtected) 'Service code inherits an uncontrolled ACL.'
    # The actual WPF view is constructed, not just parsed as XML.
    & (Join-Path ([IO.Path]::GetFullPath($KitRoot)) 'Gestion-Moonshine.ps1') -ValidateWindowOnly
    Start-MoonshineService
    # Compile the HTTP helper without dot-sourcing engine globals into the test.
    # Core.ps1 intentionally has a script-scoped Owner marker of its own.
    if (-not ('OPi5Native' -as [type])) { Add-Type -Path @((Join-Path $target 'tools\moonshine\Native.cs'),(Join-Path $target 'tools\moonshine\TransportTests.cs')) -ErrorAction Stop }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Check ($receipt.owner_sid -ceq $serviceOwnerSid -and $serviceOwnerSid -match '^S-1-') 'The selected account identity changed during test setup.'
    $base='https://127.0.0.1:48990';$pin='';$ready=$false
    for ($n=0;$n -lt 120;$n++) {
        try { $probe=[OPi5Native]::Send($base+'/api/csrf-token','GET','',[Management.Automation.Language.NullString]::Value,'');if ($probe.Status -eq 200) { $pin=$probe.Fingerprint;$ready=$true;break } } catch { }
        Start-Sleep -Milliseconds 500
    }
    Check $ready 'The genuine SCM-launched host did not open HTTPS.'
    $service=Get-MoonshineOwnedService
    $processes=@(Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" | Where-Object { $_.ExecutablePath -ieq (Join-Path $target 'sunshine.exe') })
    Check ($processes.Count -eq 1 -and $processes[0].ParentProcessId -eq $service.ProcessId -and $processes[0].SessionId -gt 0) 'SCM wrapper did not launch the host in a console session.'
    $serviceHostPid=[int]$processes[0].ProcessId
    $identity=Invoke-CimMethod -InputObject $processes[0] -MethodName GetOwnerSid
    Check ($identity.Sid -ceq 'S-1-5-18') 'The display host did not run as SYSTEM.'
    function Request([string]$Method,[string]$Path,[string]$Auth='', $Body=$null) {
        $data=[Management.Automation.Language.NullString]::Value
        if ($null -ne $Body) { $data=ConvertTo-Json -InputObject $Body -Depth 30 -Compress }
        return [OPi5Native]::Send($base+$Path,$Method,$Auth,$data,$pin)
    }
    $password=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
    $reply=Request 'POST' '/api/password' '' @{currentUsername='';currentPassword='';newUsername='moonshine-service-ci';newPassword=$password;confirmNewPassword=$password}
    Check ($reply.Status -eq 200) 'Service first-run credentials failed.'
    $reply=Request 'POST' '/api/auth/login' '' @{username='moonshine-service-ci';password=$password;remember_me=$false}
    Check ($reply.Status -eq 200) 'Service authentication failed.'
    $auth='Session '+(ConvertFrom-Json -InputObject $reply.Body).token
    $reply=Request 'GET' '/api/moonshine/status' $auth;$status=ConvertFrom-Json -InputObject $reply.Body
    Check ($reply.Status -eq 200 -and $status.execution_mode -eq 'service' -and $status.data_mode -eq 'installed' -and $status.isolated -eq $true) 'Service execution context is not exposed accurately.'
    Check ($status.available -eq $true) 'No matching logged-on Windows user was available to the service worker.'
    $reply=Request 'GET' '/api/apps' $auth;$apps=ConvertFrom-Json -InputObject $reply.Body
    Check (@($apps.apps | Where-Object { $_.uuid -eq 'e9ece5ce-44e4-4de4-9cae-68f4992f20d4' -and $_.'ci-preference' -eq 'keep' }).Count -eq 1) 'The copied catalogue lost a personal UUID or setting.'
    $reply=Request 'POST' '/api/moonshine/jobs' $auth @{action='preview';scope='all'}
    Check ($reply.Status -eq 200) 'SCM host could not create a real worker job.'
    $job=ConvertFrom-Json -InputObject $reply.Body;$observedUser=$false
    for ($n=0;$n -lt 240;$n++) {
        if (-not $observedUser) {
            foreach ($worker in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*Moonshine-Worker.ps1*' -and $_.ParentProcessId -eq $serviceHostPid })) {
                $workerOwner=Invoke-CimMethod -InputObject $worker -MethodName GetOwnerSid
                # A short-lived rejected worker may exit between the process
                # snapshot and GetOwnerSid. Do not mistake an absent SID for a
                # different owner; completion and a real SID remain required.
                $record.worker_owner_query=[int]$workerOwner.ReturnValue
                $record.worker_sid=[string]$workerOwner.Sid;$record.expected_sid=$serviceOwnerSid
                if ($workerOwner.ReturnValue -eq 0 -and $workerOwner.Sid) {
                    Check ($workerOwner.Sid -ceq $serviceOwnerSid -and $workerOwner.Sid -cne 'S-1-5-18') 'Worker escaped the selected normal account.';$observedUser=$true
                }
            }
        }
        $reply=Request 'GET' ('/api/moonshine/jobs/'+$job.job_id) $auth;$job=ConvertFrom-Json -InputObject $reply.Body
        if ($job.state -in @('completed','failed','cancelled')) { break };Start-Sleep -Milliseconds 500
    }
    $record.worker_state=$job.state;$record.worker_message=$job.message
    Check ($observedUser -and $job.state -eq 'completed') ('Service worker did not complete in its normal user token: '+$job.message)
    Check ($job.snapshot.tests -ge 459) 'The embedded engine suite did not complete through the service.'
    for ($n=0;$n -lt 30;$n++) {
        $reply=Request 'GET' '/api/tokens' $auth;$tokens=ConvertFrom-Json -InputObject $reply.Body
        if ($tokens -is [array]) { $items=@($tokens) } else { $items=@($tokens.tokens) }
        if (@($items | Where-Object { $_.username -like 'moonshine-job:*' }).Count -eq 0) { break };Start-Sleep -Milliseconds 100
    }
    Check (@($items | Where-Object { $_.username -like 'moonshine-job:*' }).Count -eq 0) 'A service job token remained after completion.'
    Stop-MoonshineService
    Check (-not (Get-Process -Id $serviceHostPid -ErrorAction SilentlyContinue)) 'SCM stop left its host process running.'
    Start-MoonshineService
    $restarted=$false
    for ($n=0;$n -lt 120;$n++) {
        try { $probe=Request 'GET' '/api/csrf-token';if ($probe.Status -eq 200) {$restarted=$true;break} } catch { }
        Start-Sleep -Milliseconds 500
    }
    Check ($restarted -and (Get-MoonshineOwnedService).State -eq 'Running') 'The service did not restore its actual HTTPS host after restart.'
    Stop-MoonshineService
    Remove-MoonshineService
    # Re-register the same copied installation without losing its credentials/catalogue.
    $configHash=(Get-FileHash -LiteralPath (Join-Path $target 'config\apps.json')).Hash
    $again=Install-MoonshineZip $KitRoot $serviceOwnerSid -Automatic
    Check ($again.id -ceq $id -and (Get-FileHash -LiteralPath (Join-Path $target 'config\apps.json')).Hash -ceq $configHash) 'Reinstallation changed the catalogue or installation identity.'
    Remove-MoonshineService
    $savedConfig=Join-Path $fixture 'saved-config';Copy-MoonshinePrivateTree (Join-Path $target 'config') $savedConfig
    Unregister-MoonshineDesktop (Read-MoonshineServiceReceipt)
    Remove-Item -LiteralPath $script:MoonshineServiceRoot -Recurse -Force
    # Prepare an inert 0.9-shaped profile. Its scripts are never executed.
    $previewCreated=$true;$oldId=[guid]::NewGuid().ToString('N')
    $oldData=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('OPi5\Moonshine-Trial\'+$oldId+'\Sync')
    $dataRoots+=@((Split-Path -Parent $oldData))
    $oldConfig=Join-Path $previewRoot 'Package\config';Copy-MoonshinePrivateTree $savedConfig $oldConfig
    foreach ($folder in @((Join-Path $previewRoot 'Package'),(Join-Path $previewRoot 'Package\tools\moonshine'))) {
        [IO.Directory]::CreateDirectory($folder) | Out-Null;[IO.File]::WriteAllText((Join-Path $folder 'moonshine-trial-id.txt'),$oldId)
    }
    Write-MoonshineServiceJson (Join-Path $previewRoot 'Package\moonshine-service-profile.json') @{schema='moonshine-service-preview/1';id=$oldId;owner_sid=$serviceOwnerSid}
    Write-MoonshineServiceJson (Join-Path $previewRoot 'service-receipt.json') @{schema='moonshine-service-receipt/1';name='MoonshineService';owner_sid=$serviceOwnerSid;id=$oldId;commit=('d'*40);phase='stopped';firewall_created=$false;files=@();legacy=$null}
    [IO.Directory]::CreateDirectory((Join-Path $previewRoot 'Package\tools')) | Out-Null
    [IO.File]::Copy((Join-Path ([IO.Path]::GetFullPath($KitRoot)) 'Package\tools\sunshinesvc.exe'),(Join-Path $previewRoot 'Package\tools\sunshinesvc.exe'))
    New-Service -Name 'MoonshineService' -BinaryPathName ('"'+(Join-Path $previewRoot 'Package\tools\sunshinesvc.exe')+'"') -StartupType Manual | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $oldData 'Games')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $oldData 'versions\0.8.1')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $oldData 'versions\0.8.1\old.ps1'),'throw "Previous code must never execute"')
    $hash=[Security.Cryptography.SHA256]::Create();try { $h=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes('steam:480'))).Replace('-','').ToLowerInvariant() } finally {$hash.Dispose()}
    $gameId='706c6f73-7862-8'+$h.Substring(0,3)+'-8'+$h.Substring(3,3)+'-'+$h.Substring(6,12)
    $oldRuntime=Join-Path $oldData 'versions\0.8.1';$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command='"'+$ps+'" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "'+(Join-Path $oldRuntime 'Launch-Game.ps1')+'" -GameId "'+$gameId+'" -DataRoot "'+$oldData+'"'
    $managed=@{uuid=$gameId;name='CI managed game';cmd=$command;'working-dir'=$oldRuntime;'opi5-xbox-owner'='opi5-xbox-sync/1';'opi5-xbox-key'='steam:480';'custom-preference'=$false;detached=@();'prep-cmd'=@()}
    Write-MoonshineServiceJson (Join-Path $oldConfig 'apps.json') @{env=@{};apps=@($personal,$managed)}
    Write-MoonshineServiceJson (Join-Path $oldData 'state.json') @{schema='opi5-xbox-state/1';managed=@{};pending=@{}}
    Write-MoonshineServiceJson (Join-Path $oldData ('Games\'+$gameId+'.json')) @{schema='opi5-xbox-game/1';uuid=$gameId;key='steam:480';user_sid=$serviceOwnerSid;kind='steam';title='CI managed game'}
    $oldCatalogueHash=(Get-FileHash -LiteralPath (Join-Path $oldConfig 'apps.json')).Hash
    $oldCertHash=(Get-FileHash -LiteralPath (Join-Path $oldConfig 'credentials\cacert.pem')).Hash
    $migrated=Install-MoonshineZip $KitRoot $serviceOwnerSid -Migrate -Automatic
    $dataRoots+=@($migrated.data_root);$target=Join-Path $script:MoonshineServiceRoot 'Package'
    Check ($migrated.id -ceq $oldId -and $migrated.data_root -notmatch 'Moonshine-Trial') 'Migration did not preserve identity in an independent root.'
    Check ((Get-FileHash -LiteralPath (Join-Path $oldConfig 'apps.json')).Hash -ceq $oldCatalogueHash) 'Migration changed the old catalogue.'
    Check ((Get-FileHash -LiteralPath (Join-Path $target 'config\credentials\cacert.pem')).Hash -ceq $oldCertHash) 'Pairing certificate was not preserved.'
    $catalogue=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $target 'config\apps.json')))
    $app=@($catalogue.apps | Where-Object {$_.uuid -ceq $gameId})[0]
    Check ($app.cmd.Contains($migrated.data_root) -and -not $app.cmd.Contains($oldData) -and $app.'custom-preference' -is [bool] -and -not $app.'custom-preference') 'Owned command or personal setting was not migrated correctly.'
    Check ([IO.File]::Exists((Join-Path $migrated.data_root 'versions\1.0.0\Launch-Game.ps1')) -and -not [IO.Directory]::Exists((Join-Path $migrated.data_root 'versions\0.8.1'))) 'A previous engine is still required after migration.'
    # Remove every prior profile before starting the actual migrated SCM host.
    Remove-Item -LiteralPath $previewRoot -Recurse -Force;$previewCreated=$false
    Remove-Item -LiteralPath (Split-Path -Parent $oldData) -Recurse -Force
    $cfg=Join-Path $target 'config\moonshine.conf';$text=[IO.File]::ReadAllText($cfg)
    [IO.File]::WriteAllText($cfg,([regex]::Replace($text,'(?m)^virtual_display_mode\s*=.*$','virtual_display_mode = disabled')+"`r`nencoder = software`r`n"))
    Start-MoonshineService
    $ready=$false
    for ($n=0;$n -lt 120;$n++) {try {$reply=Request 'GET' '/api/csrf-token';if($reply.Status -eq 200){$ready=$true;break}}catch{};Start-Sleep -Milliseconds 500}
    Check $ready 'Migrated host failed after removal of every prior profile.'
    $reply=Request 'POST' '/api/auth/login' '' @{username='moonshine-service-ci';password=$password;remember_me=$false}
    Check ($reply.Status -eq 200) 'Migrated credentials were not preserved.'
    $auth='Session '+(ConvertFrom-Json -InputObject $reply.Body).token
    $reply=Request 'GET' '/api/moonshine/status' $auth;$status=ConvertFrom-Json -InputObject $reply.Body
    Check ($status.available -eq $true -and $status.data_mode -eq 'installed') 'Migrated worker context still requires a trial.'
    $reply=Request 'POST' '/api/moonshine/jobs' $auth @{action='preview';scope='all'};$migratedJob=ConvertFrom-Json -InputObject $reply.Body
    Check ($reply.Status -eq 200) 'Migrated worker job could not start.'
    for ($n=0;$n -lt 240;$n++) { $reply=Request 'GET' ('/api/moonshine/jobs/'+$migratedJob.job_id) $auth;$migratedJob=ConvertFrom-Json -InputObject $reply.Body;if($migratedJob.state -in @('completed','failed','cancelled')){break};Start-Sleep -Milliseconds 500 }
    Check ($migratedJob.state -eq 'completed' -and $migratedJob.snapshot.tests -ge 459) ('Migrated worker failed without the prior installation: '+$migratedJob.message)
    Stop-MoonshineService
    $backup=Backup-MoonshineInstalled $serviceOwnerSid;$ownedRecovery+=@($backup.path)
    Check ($backup.verified -and [IO.File]::Exists((Join-Path $backup.path 'config\apps.json'))) 'The private maintenance backup was not verified.'
    $diagFolder=Initialize-MoonshineOperation $serviceOwnerSid ([guid]::NewGuid().ToString('N'))
    $diag=Export-MoonshineSetupDiagnostic $serviceOwnerSid $diagFolder
    Check ([IO.File]::Exists((Join-Path $diagFolder $diag.file)) -and -not $diag.contains_credentials) 'The bounded diagnostic archive was not created.'
    $removed=Uninstall-MoonshineInstalled $serviceOwnerSid;$ownedRecovery+=@($removed.path);$created=$false
    Check (-not (Get-Service -Name MoonshineService -ErrorAction SilentlyContinue) -and -not (Get-MoonshineDesktopRegistration) -and -not (Get-MoonshineStartupCommand $serviceOwnerSid)) 'Uninstall left its SCM, Apps or tray startup registration.'
    Check (-not [IO.Directory]::Exists($script:MoonshineServiceRoot) -and [IO.Directory]::Exists($migrated.data_root) -and [IO.File]::Exists((Join-Path $removed.path 'program\Package\config\apps.json'))) 'Uninstall lost the library or archived program/configuration.'
    $record=@{status='passed';service='MoonshineService';id=$oldId;checks=$record.checks;system_host=$true;normal_user_worker=$true;catalogue_preserved=$true;fresh_install_without_trial=$true;prior_roots_removed_before_worker=$true;migration_pairing_and_preferences_preserved=$true;local_verified_repair=$true;engine_tests=$job.snapshot.tests;migrated_engine_tests=$migratedJob.snapshot.tests;scm_start_stop_restart_remove=$true;reinstall_preserved_profile=$true;synthetic_rc1_in_place_upgrade=$true;windows_apps_registration=$true;owner_tray_startup=$true;private_backup=$true;diagnostic_export=$true;uninstall_archives_program_and_keeps_library=$true;driver_install_executed=$false;real_display_qualified=$false}

} catch { $record.status='failed';$record.error=$_.Exception.Message;$record.stack=$_.ScriptStackTrace }
finally {
    if ($created) { try { Remove-MoonshineService;Unregister-MoonshineDesktop (Read-MoonshineServiceReceipt) } catch { $record.cleanup_error=$_.Exception.Message } }
    $folder=Split-Path -Parent ([IO.Path]::GetFullPath($Evidence));[IO.Directory]::CreateDirectory($folder) | Out-Null
    $config=Join-Path $script:MoonshineServiceRoot 'Package\config'
    if (Test-Path -LiteralPath $config) {
        foreach ($file in @(Get-ChildItem -LiteralPath $config -File | Where-Object { $_.Extension -eq '.log' })) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $folder ('service-'+$file.Name)) -Force }
    }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Evidence),(ConvertTo-Json -InputObject $record -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $password=$null;$auth=$null
    if ($created -and -not (Get-Service -Name 'MoonshineService' -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $script:MoonshineServiceRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $link=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Moonshine.lnk'
    if ($created -and (Test-Path -LiteralPath $link)) { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    if ($previewCreated -and (Test-Path -LiteralPath $previewRoot)) { Remove-Item -LiteralPath $previewRoot -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($dataRoot in $dataRoots) { if (Test-Path -LiteralPath $dataRoot) { Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue } }
    foreach ($owned in @($ownedRecovery)+@($ownedPrevious)) {if(Test-Path -LiteralPath $owned){Remove-Item -LiteralPath $owned -Recurse -Force -ErrorAction SilentlyContinue}}
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($record.status -ne 'passed') { throw ('Service qualification failed: '+$record.error+'; '+$record.stack) }
Write-Output ('Self-contained ZIP/service qualification passed; '+$record.engine_tests+' embedded engine tests; real display remains unqualified.')

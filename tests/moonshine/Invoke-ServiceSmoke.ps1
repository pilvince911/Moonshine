#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$KitRoot,[string]$Evidence='build-evidence\service-smoke.json')
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:CI -ne 'true') { throw 'SCM qualification is restricted to a disposable GitHub Actions runner.' }
. (Join-Path ([IO.Path]::GetFullPath($KitRoot)) 'Service-Setup.ps1')
Assert-MoonshineAdmin
if (Get-Service -Name 'MoonshineService','SunshineService' -ErrorAction SilentlyContinue) { throw 'An existing host service must never be changed by CI.' }
if (Test-Path -LiteralPath $script:MoonshineServiceRoot) { throw 'CI service destination already exists.' }
$id=[guid]::NewGuid().ToString('N');$owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$fixture=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('OPi5\Moonshine-Trial\'+$id)
$record=@{status='starting';service='MoonshineService';id=$id;checks=0};$created=$false;$serviceHostPid=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$record.checks++ }
try {
    $null=Read-MoonshineServiceManifest $KitRoot
    $package=Join-Path $fixture 'Package';$config=Join-Path $package 'config';[IO.Directory]::CreateDirectory($config) | Out-Null
    foreach ($folder in @($package,(Join-Path $package 'tools\moonshine'))) { [IO.Directory]::CreateDirectory($folder) | Out-Null;[IO.File]::WriteAllText((Join-Path $folder 'moonshine-trial-id.txt'),$id) }
    [IO.File]::WriteAllText((Join-Path $config 'moonshine.conf'),"port = 48989`r`nsunshine_name = CI service fixture`r`nencoder = software`r`n")
    [IO.File]::WriteAllText((Join-Path $config 'apps.json'),'{"env":{},"apps":[{"uuid":"e9ece5ce-44e4-4de4-9cae-68f4992f20d4","name":"CI preserved personal entry","cmd":"","detached":[],"prep-cmd":[],"ci-preference":"keep"}]}')
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'Sync')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'Sync\service-sentinel.txt'),'unchanged')
    $before=@{};foreach ($file in @(Get-ChildItem -LiteralPath $fixture -Recurse -File)) { $before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash }
    $receipt=Install-MoonshineService ([IO.Path]::GetFullPath($KitRoot)) $owner $id;$created=$true
    Check ($receipt.id -ceq $id -and $receipt.phase -eq 'installed') 'Verified service installation receipt missing.'
    $service=Get-MoonshineOwnedService;Check ($service.StartMode -eq 'Manual' -and $service.StartName -eq 'LocalSystem') 'Service account or manual startup changed.'
    foreach ($path in $before.Keys) { Check ((Get-FileHash -LiteralPath $path).Hash -ceq $before[$path]) 'Setup changed its stopped source profile.' }
    $target=Join-Path $script:MoonshineServiceRoot 'Package'
    $cfg=Join-Path $target 'config\moonshine.conf';$text=[IO.File]::ReadAllText($cfg)
    $text=[regex]::Replace($text,'(?m)^virtual_display_mode\s*=.*$','virtual_display_mode = disabled')
    [IO.File]::WriteAllText($cfg,$text)
    $privateAcl=Get-Acl -LiteralPath (Join-Path $target 'config')
    Check ($privateAcl.AreAccessRulesProtected -and @($privateAcl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544') }).Count -eq 0) 'Private host configuration is readable by ordinary users.'
    $rootAcl=Get-Acl -LiteralPath $script:MoonshineServiceRoot
    Check ($rootAcl.AreAccessRulesProtected) 'Service code inherits an uncontrolled ACL.'
    # The actual WPF view is constructed, not just parsed as XML.
    & (Join-Path ([IO.Path]::GetFullPath($KitRoot)) 'Gestion-Moonshine.ps1') -ValidateWindowOnly
    Start-MoonshineService
    . (Join-Path $target 'tools\moonshine\Core.ps1');Init-Native
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
    Check ($reply.Status -eq 200 -and $status.execution_mode -eq 'service' -and $status.isolated -eq $true) 'Service execution context is not exposed accurately.'
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
                Check ($workerOwner.Sid -ceq $owner -and $workerOwner.Sid -cne 'S-1-5-18') 'Worker escaped the selected normal account.';$observedUser=$true
            }
        }
        $reply=Request 'GET' ('/api/moonshine/jobs/'+$job.job_id) $auth;$job=ConvertFrom-Json -InputObject $reply.Body
        if ($job.state -in @('completed','failed','cancelled')) { break };Start-Sleep -Milliseconds 500
    }
    Check ($observedUser -and $job.state -eq 'completed') ('Service worker did not complete in its normal user token: '+$job.message)
    Check ($job.snapshot.tests -ge 454) 'The embedded engine suite did not complete through the service.'
    $reply=Request 'GET' '/api/tokens' $auth;$tokens=ConvertFrom-Json -InputObject $reply.Body
    if ($tokens -is [array]) { $items=@($tokens) } else { $items=@($tokens.tokens) }
    Check (@($items | Where-Object { $_.username -like 'moonshine-job:*' }).Count -eq 0) 'A service job token remained after completion.'
    Stop-MoonshineService
    Check (-not (Get-Process -Id $serviceHostPid -ErrorAction SilentlyContinue)) 'SCM stop left its host process running.'
    Start-MoonshineService
    Check ((Get-MoonshineOwnedService).State -eq 'Running') 'The service could not restart.'
    Stop-MoonshineService
    Remove-MoonshineService
    $record=@{status='passed';service='MoonshineService';id=$id;checks=$record.checks;system_host=$true;normal_user_worker=$true;catalogue_preserved=$true;source_profile_unchanged_at_install=$true;engine_tests=$job.snapshot.tests;scm_start_stop_restart_remove=$true;real_display_qualified=$false}
} catch { $record.status='failed';$record.error=$_.Exception.Message;$record.stack=$_.ScriptStackTrace }
finally {
    if ($created) { try { Remove-MoonshineService } catch { $record.cleanup_error=$_.Exception.Message } }
    $folder=Split-Path -Parent ([IO.Path]::GetFullPath($Evidence));[IO.Directory]::CreateDirectory($folder) | Out-Null
    $config=Join-Path $script:MoonshineServiceRoot 'Package\config'
    if (Test-Path -LiteralPath $config) {
        foreach ($file in @(Get-ChildItem -LiteralPath $config -File | Where-Object { $_.Extension -eq '.log' })) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $folder ('service-'+$file.Name)) -Force }
    }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Evidence),(ConvertTo-Json -InputObject $record -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $password=$null;$auth=$null
    if ($created -and -not (Get-Service -Name 'MoonshineService' -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $script:MoonshineServiceRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($record.status -ne 'passed') { throw ('Service qualification failed: '+$record.error+'; '+$record.stack) }
Write-Output ('SCM service qualification passed; '+$record.engine_tests+' embedded engine tests; real display remains unqualified.')

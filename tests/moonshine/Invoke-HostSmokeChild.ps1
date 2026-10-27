#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Package,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop';$hostProcess=$null;$id=[guid]::NewGuid().ToString('N');$checks=0;$record=@{status='starting';id=$id}
function Save-SmokeResult { [IO.File]::WriteAllText($Output,(ConvertTo-Json -InputObject $record -Depth 12),(New-Object Text.UTF8Encoding($false))) }
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:checks++ }
try {
    Save-SmokeResult
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
    Check (-not $identity.IsSystem -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Smoke test did not reach a non-administrator token.'
    $env:LOCALAPPDATA=[Environment]::GetFolderPath('LocalApplicationData')
    $env:MOONSHINE_TRIAL_ID=$id
    foreach ($folder in @($Package,(Join-Path $Package 'tools\moonshine'))) {
        [IO.File]::WriteAllText((Join-Path $folder 'moonshine-trial-id.txt'),$id)
        [IO.File]::WriteAllText((Join-Path $folder 'moonshine-trial-only.txt'),'trial')
    }
    $config=Join-Path $Package 'config\smoke.conf';[IO.Directory]::CreateDirectory((Split-Path -Parent $config)) | Out-Null
    [IO.File]::WriteAllText($config,"port = 48989`r`nsunshine_name = Moonshine CI`r`nupnp = disabled`r`nsystem_tray = disabled`r`ninstall_steam_audio_drivers = disabled`r`nvirtual_display_mode = disabled`r`nencoder = software`r`norigin_web_ui_allowed = pc`r`nupdate_check_interval = 0`r`n")
    $production=Join-Path $env:LOCALAPPDATA 'OPi5\VibeShine-Xbox';$wasPresent=Test-Path -LiteralPath $production
    [IO.Directory]::CreateDirectory($production) | Out-Null
    $sentinel=Join-Path $production ('moonshine-smoke-sentinel-'+$id+'.json')
    [IO.File]::WriteAllText($sentinel,'{"production":"must stay unchanged"}')
    $before=@{};foreach ($file in @(Get-ChildItem -LiteralPath $production -Recurse -File)) { $before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash }
    $user='moonshine-smoke';$password=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
    $initialize=New-Object Diagnostics.ProcessStartInfo
    $initialize.FileName=Join-Path $Package 'sunshine.exe';$initialize.Arguments='"'+$config+'" --creds '+$user+' '+$password;$initialize.WorkingDirectory=$Package;$initialize.UseShellExecute=$false;$initialize.CreateNoWindow=$true
    $created=[Diagnostics.Process]::Start($initialize)
    Check ($created.WaitForExit(30000) -and $created.ExitCode -eq 0) 'Synthetic host credential initialization failed.'
    $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$initialize.FileName;$start.Arguments='"'+$config+'"';$start.WorkingDirectory=$Package;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $hostProcess=[Diagnostics.Process]::Start($start)
    . (Join-Path $Package 'tools\moonshine\Core.ps1');Init-Native
    $base='https://127.0.0.1:48990';$pin='';$ready=$false
    for ($n=0;$n -lt 120;$n++) {
        if ($hostProcess.HasExited) { throw ('Host exited during startup: '+$hostProcess.ExitCode) }
        try { $probe=[OPi5Native]::Send($base+'/api/csrf-token','GET','',[Management.Automation.Language.NullString]::Value,'');if ($probe.Status -eq 200) { $pin=$probe.Fingerprint;$ready=$true;break } } catch { }
        Start-Sleep -Milliseconds 500
    }
    Check $ready 'Native HTTPS interface did not start.'
    function Request([string]$Method,[string]$Path,[string]$Auth='', $Body=$null) {
        $text=[Management.Automation.Language.NullString]::Value
        if ($null -ne $Body) { $text=ConvertTo-Json -InputObject $Body -Depth 30 -Compress }
        return [OPi5Native]::Send($base+$Path,$Method,$Auth,$text,$pin)
    }
    $reply=Request 'GET' '/api/moonshine/status';Check ($reply.Status -in @(401,403)) 'Unauthenticated library access was allowed.'
    $reply=Request 'POST' '/api/auth/login' '' @{username=$user;password=$password;remember_me=$false};Check ($reply.Status -eq 200) 'Synthetic login failed.'
    $login=ConvertFrom-Json -InputObject $reply.Body;$authorization='Session '+$login.token;Check (-not [string]::IsNullOrWhiteSpace($login.token)) 'Login did not issue a session.'
    $reply=Request 'GET' '/api/moonshine/status' $authorization;Check ($reply.Status -eq 200) 'Native Moonshine status route failed.'
    $status=ConvertFrom-Json -InputObject $reply.Body;Check ($status.available -eq $true -and $status.isolated -eq $true) 'Native status did not report the isolated user context.'
    $reply=Request 'POST' '/api/token' $authorization @{scopes=@(@{path='/api/apps';methods=@('GET')})};Check ($reply.Status -eq 200) 'Scoped-token setup failed.'
    $restricted=ConvertFrom-Json -InputObject $reply.Body
    $reply=Request 'POST' '/api/moonshine/jobs' ('Bearer '+$restricted.token) @{action='preview';scope='all'};Check ($reply.Status -eq 403) 'A read-only apps token could start a native job.'
    $reply=Request 'POST' '/api/moonshine/jobs' $authorization @{action='preview';scope='all'};Check ($reply.Status -eq 200) 'Native preview job was not created.'
    $job=ConvertFrom-Json -InputObject $reply.Body;Check ($job.job_id -cmatch '\A[a-f0-9]{32}\z') 'Job identity is invalid.'
    for ($n=0;$n -lt 240;$n++) {
        $reply=Request 'GET' ('/api/moonshine/jobs/'+$job.job_id) $authorization;Check ($reply.Status -eq 200) 'Native job polling failed.'
        $job=ConvertFrom-Json -InputObject $reply.Body
        if ($job.state -in @('completed','failed','cancelled')) { break }
        Start-Sleep -Milliseconds 500
    }
    Check ($job.state -eq 'completed') ('Real embedded worker failed: '+$job.message)
    Check ($job.snapshot.schema -eq 'moonshine-snapshot/1' -and $job.snapshot.tests -ge 427) 'Real worker did not publish its tested snapshot.'
    function Complete-NativeJob([string]$Action,[string]$Expected='') {
        $reply=Request 'POST' '/api/moonshine/jobs' $authorization @{action=$Action;scope='all'}
        Check ($reply.Status -eq 200) ('Native '+$Action+' job was not created.')
        $current=ConvertFrom-Json -InputObject $reply.Body;$answered=$false
        for ($n=0;$n -lt 240;$n++) {
            $reply=Request 'GET' ('/api/moonshine/jobs/'+$current.job_id) $authorization
            Check ($reply.Status -eq 200) ('Polling '+$Action+' failed.')
            $current=ConvertFrom-Json -InputObject $reply.Body
            if ($current.state -eq 'awaiting_confirmation') {
                Check (-not $answered -and $Expected -and $current.prompt.expected -ceq $Expected) ('Unexpected confirmation for '+$Action)
                Check (@($current.prompt.rows | Where-Object { $_.title -eq 'CI personal entry' }).Count -eq 0) 'The plan included a personal entry.'
                $reply=Request 'POST' ('/api/moonshine/jobs/'+$current.job_id+'/confirm') $authorization @{nonce=$current.prompt.nonce;accept=$true;text=$Expected}
                Check ($reply.Status -eq 200) ('Confirmation '+$Action+' failed.');$answered=$true
            }
            if ($current.state -in @('completed','failed','cancelled')) { break }
            Start-Sleep -Milliseconds 500
        }
        Check ($current.state -eq 'completed') ('Native '+$Action+' failed: '+$current.message)
        if ($Expected) { Check $answered ('No confirmation was shown for '+$Action) }
        return $current
    }
    function Read-NativeApps {
        $reply=Request 'GET' '/api/apps' $authorization;Check ($reply.Status -eq 200) 'Native app catalogue readback failed.'
        return @((ConvertFrom-Json -InputObject $reply.Body).apps)
    }
    Check ($status.creation_profile -eq 'game-provided') 'Native creation preset did not default to game-provided FG.'
    $personalId=[guid]::NewGuid().ToString();$key='steam:777777';$managedId=Stable-Id $key
    $personal=@{uuid=$personalId;name='CI personal entry';cmd='';detached=@();'prep-cmd'=@();'ci-preference'='keep personal'}
    $managedFixture=@{uuid=$managedId;name='CI historical managed entry';cmd='';detached=@();'prep-cmd'=@();'ci-preference'='keep historical';'plos-xbox-owner'='plos-xbox-sync/1';'plos-xbox-key'=$key}
    foreach ($fixture in @($personal,$managedFixture,$managedFixture)) {
        $reply=Request 'POST' '/api/apps' $authorization $fixture
        Check ($reply.Status -eq 200 -and (ConvertFrom-Json -InputObject $reply.Body).status -eq $true) 'Native app fixture persistence failed.'
    }
    $beforeApps=@(Read-NativeApps)
    Check (@($beforeApps | Where-Object { $_.uuid -eq $managedId }).Count -eq 1) 'Repeated UUID persistence created a duplicate.'
    Check (@($beforeApps | Where-Object { $_.uuid -eq $managedId -and $_.'plos-xbox-key' -eq $key }).Count -eq 1) 'The host discarded historical ownership fields.'
    $job=Complete-NativeJob 'reset' 'REINITIALISER'
    $afterReset=@(Read-NativeApps)
    Check (@($afterReset | Where-Object { $_.uuid -eq $managedId }).Count -eq 0) 'The confirmed reset did not remove its managed fixture.'
    Check ((($afterReset.uuid | Sort-Object) -join ',') -ceq ((($beforeApps | Where-Object { $_.uuid -ne $managedId }).uuid | Sort-Object) -join ',')) 'The reset changed other app identities.'
    Check (@($afterReset | Where-Object { $_.uuid -eq $personalId -and $_.'ci-preference' -eq 'keep personal' }).Count -eq 1) 'The reset changed a personal preference.'
    $job=Complete-NativeJob 'reset'
    Check (@(Read-NativeApps).Count -eq $afterReset.Count) 'Repeating reset changed the remaining catalogue.'
    $job=Complete-NativeJob 'restore' 'RESTAURER'
    $restored=@(Read-NativeApps)
    Check ((($restored.uuid | Sort-Object) -join ',') -ceq (($beforeApps.uuid | Sort-Object) -join ',')) 'Restoration did not recover the original identities.'
    Check (@($restored | Where-Object { $_.uuid -eq $managedId -and $_.'ci-preference' -eq 'keep historical' }).Count -eq 1) 'Restoration lost a historical customization.'
    Check (@($restored | Where-Object { $_.uuid -eq $personalId -and $_.'ci-preference' -eq 'keep personal' }).Count -eq 1) 'Restoration changed a personal entry.'
    Check ($job.snapshot.reset.status -eq 'restored') 'The restored recovery journal was not published.'
    $reply=Request 'GET' '/api/tokens' $authorization;Check ($reply.Status -eq 200) 'Token lifecycle readback failed.'
    $tokens=ConvertFrom-Json -InputObject $reply.Body
    if ($tokens -is [array]) { $items=@($tokens) } elseif ($tokens.tokens -is [array]) { $items=@($tokens.tokens) } else { throw 'Token list shape is unknown.' }
    Check (@($items | Where-Object { $_.username -like 'moonshine-job:*' }).Count -eq 0) 'A temporary native-job token survived completion.'
    $after=@(Get-ChildItem -LiteralPath $production -Recurse -File);Check ($after.Count -eq $before.Count) 'Native trial wrote to the production data tree.'
    foreach ($file in $after) { Check ($before[$file.FullName] -ceq (Get-FileHash -LiteralPath $file.FullName).Hash) 'Production bytes changed during the trial.' }
    $event=[Threading.EventWaitHandle]::OpenExisting(('Global\Moonshine.Trial.Stop.'+$id),[Security.AccessControl.EventWaitHandleRights]::Modify)
    try { $null=$event.Set() } finally { $event.Dispose() }
    Check ($hostProcess.WaitForExit(30000) -and $hostProcess.ExitCode -eq 0) 'The complete native host did not shut down cleanly.'
    $record=@{status='passed';id=$id;non_administrator=$true;checks=$checks;engine_tests=$job.snapshot.tests;job_state=$job.state;isolated=$status.isolated;production_unchanged=$true;native_reset_restore=$true;personal_entries_preserved=$true;shutdown_exit_code=$hostProcess.ExitCode}
    Remove-Item -LiteralPath $sentinel -Force
    if (-not $wasPresent -and @(Get-ChildItem -LiteralPath $production -Force).Count -eq 0) { Remove-Item -LiteralPath $production }
} catch { $record=@{status='failed';id=$id;checks=$checks;error=$_.Exception.Message;stack=$_.ScriptStackTrace} }
finally {
    if ($hostProcess -and -not $hostProcess.HasExited) {
        try { $event=[Threading.EventWaitHandle]::OpenExisting(('Global\Moonshine.Trial.Stop.'+$id),[Security.AccessControl.EventWaitHandleRights]::Modify);$null=$event.Set();$event.Dispose();$null=$hostProcess.WaitForExit(20000) } catch { }
    }
    $password=$null;$authorization=$null;Save-SmokeResult
}
if ($record.status -ne 'passed') { exit 1 }

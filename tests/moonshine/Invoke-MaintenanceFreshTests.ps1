#Requires -Version 5.1
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:CI -ne 'true') { throw 'Disposable GitHub Actions runner required.' }
if (@(Get-CimInstance Win32_Service | Where-Object { $_.Name -in @('MoonshineService','SunshineService') }).Count) { throw 'An existing host service must never be changed.' }
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'tools\moonshine-maintenance\Maintenance-Core.ps1')
. (Join-Path $root 'tools\moonshine-maintenance\Fresh-Core.ps1')
$temporary=Join-Path $env:TEMP ('moonshine-fresh-tests-'+[guid]::NewGuid().ToString('N'))
$checks=0;$ownedPath='';$ruleName='';$locks=$null
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message };$script:checks++ }
function Refuses([scriptblock]$Action,[string]$Message) { $rejected=$false;try { & $Action } catch { $rejected=$true };Check $rejected $Message }
function MakeDirectory([string]$Path) { [IO.Directory]::CreateDirectory($Path) | Out-Null;return $Path }
function RemoveOwnedFixtureService {
    $service=Get-CimInstance Win32_Service -Filter "Name='MoonshineService'"
    if ($service) {
        if ($service.PathName.Trim() -cne $script:ownedPath -or $service.State -ne 'Stopped') { throw 'Fixture cleanup ownership mismatch.' }
        & "$env:WINDIR\System32\sc.exe" delete MoonshineService | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Fixture service removal failed.' }
    }
}
try {
    MakeDirectory $temporary | Out-Null
    foreach ($file in @(Get-ChildItem (Join-Path $root 'tools\moonshine-maintenance') -Filter *.ps1)) {
        $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Check ($errors.Count -eq 0) ('PowerShell 5.1 parse failed: '+$file.Name)
    }
    $catalogue=@(Get-MMOldDistributions)
    Check ($catalogue.Count -eq 14) 'The old-distribution catalogue must cover 0.1 through the delivered 0.9.'
    Check (@($catalogue | Where-Object { $_.name -match '1\.0' -and $_.name -notmatch '0\.1\.0' }).Count -eq 0) 'RC1 or a final distribution may not be cleanup targets.'
    Check (Test-MMDistributionName 'OPi5-VibeShine-Sync-v0.7.0 (2).zip' 'OPi5-VibeShine-Sync-v0.7.0' -Zip) 'Browser download-copy names must be recognized.'
    Check (-not (Test-MMDistributionName 'OPi5-VibeShine-Sync-v0.7.0-personal' 'OPi5-VibeShine-Sync-v0.7.0')) 'An arbitrary name suffix must not authorize removal.'
    $distributionRoot=MakeDirectory (Join-Path $temporary 'distribution')
    $sample=Join-Path $distributionRoot 'script.ps1';[IO.File]::WriteAllText($sample,'fixture only; never executed')
    $distribution=@{files=@(@{path='script.ps1';size=(Get-Item $sample).Length;sha256=(Get-FileHash $sample).Hash.ToLowerInvariant()});archive_size=0;archive_sha256=''}
    Check (Test-MMDistribution $distributionRoot $distribution) 'An exact extracted distribution should be recognized.'
    $personal=Join-Path $distributionRoot 'personal.txt';[IO.File]::WriteAllText($personal,'keep me')
    Check (-not (Test-MMDistribution $distributionRoot $distribution)) 'Extra personal files must preserve an extracted kit.'
    [IO.File]::Delete($personal);[IO.File]::WriteAllText($sample,'changed')
    Check (-not (Test-MMDistribution $distributionRoot $distribution)) 'Modified kit files must preserve the directory.'
    $zip=Join-Path $temporary 'old.zip';[IO.File]::WriteAllText($zip,'fixture ZIP bytes')
    $distribution.archive_size=(Get-Item $zip).Length;$distribution.archive_sha256=(Get-FileHash $zip).Hash.ToLowerInvariant()
    Check (Test-MMDistribution $zip $distribution) 'An exact old archive must be recognized by size and hash.'
    $files=@(Copy-MMVerifiedTree $zip (Join-Path $temporary 'file-backup'))
    Check ($files.Count -eq 1) 'A single-file backup must contain exactly the original file.'
    $archive=Move-MMVerifiedRoot @{source=$zip;key='file-backup';files=$files} $temporary
    Check (-not [IO.File]::Exists($zip) -and [IO.File]::Exists((Join-Path $archive 'old.zip'))) 'An old ZIP must be archived intact, not recursively deleted.'
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $context=@{OwnerSid=$sid;Profile=(MakeDirectory (Join-Path $temporary 'user'));Local=(MakeDirectory (Join-Path $temporary 'user\AppData\Local'));ProgramFiles=(MakeDirectory (Join-Path $temporary 'Program Files'));BackupBase=(MakeDirectory (Join-Path $temporary 'backups'));ExtraFolders=@()}
    $id='a'*32;$commit='b'*40;$base=MakeDirectory (Join-Path $context.Local 'OPi5\Moonshine-Trial');$trial=MakeDirectory (Join-Path $base $id)
    $preview=MakeDirectory (Join-Path $context.ProgramFiles 'Moonshine-Preview')
    foreach ($instance in @($trial,$preview)) {
        foreach ($relative in @('Package','Package\tools\moonshine')) {
            $folder=MakeDirectory (Join-Path $instance $relative);[IO.File]::WriteAllText((Join-Path $folder 'moonshine-trial-id.txt'),$id)
        }
    }
    # A real PE is used only as a firewall target. It is NEVER started.
    Copy-Item -LiteralPath "$env:WINDIR\System32\whoami.exe" -Destination (Join-Path $preview 'Package\sunshine.exe')
    MakeDirectory (Join-Path $trial 'Sync') | Out-Null
    Write-MMJson (Join-Path $base 'instances.json') @{schema='moonshine-trial-instances/1';instances=@{$commit=$id}}
    Check (Test-MMTrialBase $context $base) 'A complete known trial base should include its stale index.'
    $unknown=Join-Path $base 'personal.txt';[IO.File]::WriteAllText($unknown,'unrelated')
    Check (-not (Test-MMTrialBase $context $base)) 'Unexpected files must preserve the whole trial parent.'
    [IO.File]::Delete($unknown)
    $current=MakeDirectory (Join-Path $context.ProgramFiles 'Moonshine\Package\config')
    $currentData=MakeDirectory (Join-Path $context.Local 'Moonshine\Library\cccccccccccccccccccccccccccccccc')
    [IO.File]::WriteAllText((Join-Path $currentData 'keep.txt'),'new library')
    Write-MMJson (Join-Path $current 'apps.json') @{apps=@(@{name='personal current app';cmd='do not alter'})}
    $protectedKit=MakeDirectory (Join-Path $context.ProgramFiles 'Moonshine\OPi5-VibeShine-Sync-v0.7.0')
    $protectedBackupKit=MakeDirectory (Join-Path $context.BackupBase 'OPi5-VibeShine-Sync-v0.7.0')
    $context.ExtraFolders=@((Join-Path $context.ProgramFiles 'Moonshine'),$context.BackupBase)
    Check (Test-MMProtectedPath $context $protectedKit) 'Even explicitly selected old-looking files under the new program must be protected.'
    Check (Test-MMProtectedPath $context $protectedBackupKit) 'Previously saved backups must never become new cleanup candidates.'
    $receipt=@{schema='moonshine-service-receipt/1';name='MoonshineService';id=$id;commit=$commit;owner_sid=$sid;phase='stopped';firewall_created=$true}
    Write-MMJson (Join-Path $preview 'service-receipt.json') $receipt
    Write-MMJson (Join-Path $preview 'Package\moonshine-service-profile.json') @{schema='moonshine-service-preview/1';id=$id;owner_sid=$sid}
    $ownedPath='"'+(Join-Path $preview 'Package\tools\sunshinesvc.exe')+'"'
    New-Service -Name MoonshineService -BinaryPathName $ownedPath -StartupType Manual | Out-Null
    Check ($null -ne (Get-MMPreview $context).service) 'The exact stopped old LocalSystem service must be recognized.'
    $candidates=@(Get-MMAllCandidates $context)
    Check (@($candidates | Where-Object { $_.path -ieq $base }).Count -eq 1) 'The entire recognized trial base must be a single candidate.'
    Check (@($candidates | Where-Object { $_.path -ieq $trial }).Count -eq 0) 'Nested candidates must not be archived twice.'
    Check (@($candidates | Where-Object { $_.path -like ($context.ProgramFiles+'\Moonshine\*') -or $_.path -like ($context.Local+'\Moonshine\*') }).Count -eq 0) 'The standalone program and library must never be candidates.'
    Check (@($candidates | Where-Object { $_.path -ieq $protectedBackupKit }).Count -eq 0) 'An extra search location must not expose saved archives to cleanup.'
    $tasks=@(Get-MMAllTasks $context $candidates)
    $normal=@(Get-MMPlan $candidates @(Get-MMEffectiveReferences $context) $tasks | Where-Object { $_.path -ieq $base })
    Check (-not $normal[0].removable) 'Ordinary cleanup must keep data still bound to the old service.'
    $plan=@(Get-MMPlan $candidates @(Get-MMEffectiveReferences $context -Fresh) $tasks)
    Check (@($plan | Where-Object { $_.path -ieq $preview -and -not $_.removable }).Count -eq 1) 'A missing old catalogue must preserve the preview even in fresh mode.'
    $oldConfig=MakeDirectory (Join-Path $preview 'Package\config')
    Write-MMJson (Join-Path $oldConfig 'apps.json') @{apps=@(@{name='old imported game';cmd=(Join-Path $trial 'Sync\versions\0.8.1\Launch-Game.ps1')})}
    $custom=Join-Path $oldConfig 'moonshine.conf';[IO.File]::WriteAllText($custom,'file_apps = C:\custom\apps.json')
    $blocked=@(Get-MMPlan $candidates @(Get-MMEffectiveReferences $context -Fresh) $tasks)
    Check (@($blocked | Where-Object { $_.path -ieq $preview -and -not $_.removable }).Count -eq 1) 'An unresolved custom catalogue must preserve the preview even in fresh mode.'
    [IO.File]::Delete($custom)
    $plan=@(Get-MMPlan $candidates @(Get-MMEffectiveReferences $context -Fresh) $tasks)
    Check (@($plan | Where-Object { $_.path -ieq $preview -and $_.removable }).Count -eq 1) ('Explicit fresh cleanup must plan retirement of the known preview. Synthetic plan: '+(ConvertTo-Json -InputObject $plan -Depth 6 -Compress)+'; synthetic references: '+(ConvertTo-Json -InputObject @(Get-MMEffectiveReferences $context -Fresh) -Depth 6 -Compress))
    $locks=Get-MMAllLocks $context $candidates
    $backup=New-MMBackup $context $candidates $plan $tasks
    foreach ($held in $locks) { $held.Dispose() };$locks=$null
    Check ($backup.record.phase -ceq 'verified') 'Every service change must follow a verified full backup.'
    $ruleName='MoonshineServicePreview-'+$id
    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) { throw 'Existing fixture firewall rule must never be changed.' }
    $firewallProgram=[IO.Path]::GetFullPath((Join-Path $preview 'Package\sunshine.exe'))
    New-NetFirewallRule -Name $ruleName -DisplayName 'Moonshine disposable cleanup fixture' -Direction Inbound -Action Allow -Profile Private -Program $firewallProgram -RemoteAddress LocalSubnet | Out-Null
    Invoke-MMRetirePreview $context $backup
    Check (-not (Get-CimInstance Win32_Service -Filter "Name='MoonshineService'")) 'The exact old SCM binding was not removed.'
    Check (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) 'The exact old firewall rule was not removed.'
    Check ([IO.Directory]::Exists($preview) -and [IO.Directory]::Exists($trial)) 'Service retirement must not delete profile directories before archival.'
    Check ($backup.record.preview_service.path -ceq $ownedPath) 'The recovery journal must retain the previous SCM configuration.'
    # A new stopped standalone service using the SAME service name must survive cleanup.
    $ownedPath='"'+(Join-Path $context.ProgramFiles 'Moonshine\Package\tools\sunshinesvc.exe')+'"'
    New-Service -Name MoonshineService -BinaryPathName $ownedPath -StartupType Manual | Out-Null
    Check ($null -eq (Get-MMPreview $context).service) 'The new standalone service may not be classified as the old preview.'
    Invoke-MMRetirePreview $context $backup
    Invoke-MMCleanup $context $candidates $plan $tasks $backup -Fresh
    Check ((Get-CimInstance Win32_Service -Filter "Name='MoonshineService'").PathName -ceq $ownedPath) 'The new standalone service binding changed.'
    Check (-not [IO.Directory]::Exists($preview) -and -not [IO.Directory]::Exists($base)) 'Old service and complete trial base were not archived.'
    Check ([IO.File]::ReadAllText((Join-Path $currentData 'keep.txt')) -ceq 'new library') 'Standalone user data changed.'
    Check ((Read-MMJson (Join-Path $current 'apps.json')).apps[0].name -ceq 'personal current app') 'The standalone catalogue changed.'
    Check ($backup.record.phase -ceq 'completed') 'The cleanup journal did not complete.'
    Check ($null -eq (Get-MMPreview $context)) 'A repeated cleanup must not recreate an old preview.'
    Check (@(Get-MMAllTasks $context $candidates).Count -eq 0) 'Rechecking after the trial base move must tolerate its absence.'
    RemoveOwnedFixtureService;$ownedPath=''
    Write-Output ('Moonshine fresh cleanup: '+$checks+' checks passed, including actual disposable SCM retirement, new-service preservation and archival; no driver installed or removed.')
} finally {
    if ($locks) { foreach ($held in $locks) { $held.Dispose() } }
    if ($ownedPath) { RemoveOwnedFixtureService }
    if ($ruleName) {
        $rule=Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($rule) {
            $app=Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule
            if ([IO.Path]::GetFullPath($app.Program) -ieq [IO.Path]::GetFullPath((Join-Path $temporary 'Program Files\Moonshine-Preview\Package\sunshine.exe'))) { Remove-NetFirewallRule -Name $ruleName }
        }
    }
    if ([IO.Directory]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
exit 0

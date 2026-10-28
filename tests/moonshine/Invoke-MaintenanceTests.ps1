#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'tools\moonshine-maintenance\Maintenance-Core.ps1')
$temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('moonshine-maintenance-tests-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message };$script:checks++ }
function Refuses([scriptblock]$Action,[string]$Message) { $rejected=$false;try { & $Action } catch { $rejected=$true };Check $rejected $Message }
try {
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    $source=Join-Path $temporary 'source';[IO.Directory]::CreateDirectory((Join-Path $source 'nested')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'nested\state.json'),'catalogue et personnalisation')
    [IO.File]::WriteAllText((Join-Path $source '.hidden'),'conserver aussi')
    [IO.File]::WriteAllText((Join-Path $source 'sync.lock'),'un verrou ne se copie pas')
    $destination=Join-Path $temporary 'copy'
    $files=@(Copy-MMVerifiedTree $source $destination)
    Check ($files.Count -eq 2 -and -not [IO.File]::Exists((Join-Path $destination 'sync.lock'))) 'A verified backup must include hidden/nested files and omit a live lock.'
    Check (Test-MMTreeEqual $files @(Get-MMTree $destination)) 'Backup hash closure differs.'
    $held=Get-MMLocks @(@{known=$true;sync=$source})
    try {
        $lockedCopy=Join-Path $temporary 'locked-copy';$snapshot=@(Copy-MMVerifiedTree $source $lockedCopy)
        Check (Test-MMTreeEqual $files $snapshot) 'Cooperative bootstrap/sync locks must stay held while backing up normal files.'
    } finally { foreach ($handle in $held) { $handle.Dispose() } }
    Refuses { Copy-MMVerifiedTree $source $destination } 'Existing backups must never be overwritten.'
    $entry=@{source=$source;key='copy';files=$files}
    [IO.File]::WriteAllText((Join-Path $source 'nested\state.json'),'change apres apercu')
    Refuses { Move-MMVerifiedRoot $entry $temporary } 'A stale source must not be removed.'
    Check ([IO.Directory]::Exists($source)) 'Source was removed after a stale-source rejection.'
    [IO.File]::WriteAllText((Join-Path $source 'nested\state.json'),'catalogue et personnalisation')
    [IO.File]::WriteAllText((Join-Path $destination 'nested\state.json'),'sauvegarde endommagee')
    Refuses { Move-MMVerifiedRoot $entry $temporary } 'A corrupt backup must prevent removal.'
    Check ([IO.Directory]::Exists($source)) 'Source was removed after a corrupt-backup rejection.'
    $id='a'*32;$trial=Join-Path $temporary $id
    foreach ($relative in @('Package','Package\tools\moonshine')) {
        $folder=Join-Path $trial $relative;[IO.Directory]::CreateDirectory($folder) | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder 'moonshine-trial-id.txt'),$id)
    }
    Check (Test-MMTrial $trial $id) 'Matching trial identity should be recognized.'
    [IO.File]::WriteAllText((Join-Path $trial 'Package\tools\moonshine\moonshine-trial-id.txt'),('b'*32))
    Check (-not (Test-MMTrial $trial $id)) 'Different engine identity must preserve the whole directory.'
    Check (-not (Test-MMTrial $trial '..\outside')) 'A path may not be used as an instance id.'
    $candidate=@{path=$source;kind='test';known=$true;sync=$source}
    $plan=@(Get-MMPlan @($candidate) @(@{text=($source+'\versions\0.8.1\Launch-Game.ps1');source='fiche active';unknown=$false}) @())
    Check (-not $plan[0].removable -and $plan[0].reason -match 'fiche active') 'An app command dependency must preserve a stopped installation.'
    $plan=@(Get-MMPlan @($candidate) @(@{text='';source='catalogue inconnu';unknown=$true}) @())
    Check (-not $plan[0].removable) 'An unresolved custom catalogue must fail closed.'
    $plan=@(Get-MMPlan @($candidate) @() @(@{data=$source;known=$false;name='custom'}))
    Check (-not $plan[0].removable) 'A customized or running task must prevent directory removal.'
    $plan=@(Get-MMPlan @(@{path=$source;kind='test';known=$false;sync=$source}) @() @())
    Check (-not $plan[0].removable) 'An unrecognized directory must be preserved.'
    $plan=@(Get-MMPlan @($candidate) @() @())
    Check $plan[0].removable 'An unused positively identified instance may be archived.'
    Check ((Get-MMServiceExecutable '"C:\Program Files\Moonshine-Preview\Package\tools\sunshinesvc.exe"') -ceq 'C:\Program Files\Moonshine-Preview\Package\tools\sunshinesvc.exe') 'Quoted SCM paths must be read without invoking a shell.'
    Check ((Get-MMServiceExecutable 'C:\Program Files\unsafe.exe') -ceq '') 'Ambiguous unquoted service paths must fail closed.'
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $receipt=@{schema='moonshine-service-receipt/1';name='MoonshineService';owner_sid=$sid;id=$id;commit=('c'*40)}
    Check (Test-MMPreviewReceipt $receipt $sid) 'A matching private service receipt must be recognized.'
    Check (-not (Test-MMPreviewReceipt $receipt 'S-1-5-18')) 'A different owner must not authorize cleanup.'
    $task=[pscustomobject]@{TaskPath='\';State='Ready';Principal=[pscustomobject]@{UserId=$sid};Actions=@([pscustomobject]@{Execute=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $source 'Packages\0.8.1\Bootstrap.ps1')+'" -Action SyncAll -Unattended');WorkingDirectory=''})}
    Check (Test-MMTask $task $source $sid) 'A recognized exact task should be eligible for backup/removal.'
    $task.Actions[0].Arguments+='; whoami'
    Check (-not (Test-MMTask $task $source $sid)) 'Additional shell text must not be accepted as a managed task.'
    $task.Actions[0].Arguments=$task.Actions[0].Arguments.Replace('; whoami','');$task.State='Running'
    Check (-not (Test-MMTask $task $source $sid)) 'A running task must not be removed.'
    $junction=Join-Path $temporary 'junction';$outside=Join-Path $temporary 'outside';[IO.Directory]::CreateDirectory($outside) | Out-Null
    $null=New-Item -ItemType Junction -Path $junction -Target $outside
    Refuses { $null=Get-MMTree $junction } 'A root junction must not be traversed.'
    $nestedLink=Join-Path $source 'linked';$null=New-Item -ItemType Junction -Path $nestedLink -Target $outside
    Refuses { $null=Get-MMTree $source } 'An embedded junction must not be traversed.'
    [IO.Directory]::Delete($nestedLink);[IO.Directory]::Delete($junction)
    $external=Join-Path $outside 'shared.txt';[IO.File]::WriteAllText($external,'fichier partage externe')
    $externalAcl=(Get-Acl -LiteralPath $external).Sddl
    $hardlink=Join-Path $source 'shared-link.txt';$null=New-Item -ItemType HardLink -Path $hardlink -Target $external
    Refuses { $null=Get-MMTree $source } 'Hard-linked files must not authorize ACL changes to an external file.'
    [IO.File]::Delete($hardlink)
    Check ((Get-Acl -LiteralPath $external).Sddl -ceq $externalAcl -and [IO.File]::ReadAllText($external) -ceq 'fichier partage externe') 'External shared file contents or permissions changed.'
    # Real atomic archive under a temporary private tree, without touching services/tasks/drivers.
    [IO.File]::WriteAllText((Join-Path $destination 'nested\state.json'),'catalogue et personnalisation')
    $archive=Move-MMVerifiedRoot $entry $temporary
    Check (-not [IO.Directory]::Exists($source) -and [IO.Directory]::Exists($archive)) 'An eligible directory was not atomically archived.'
    Check (Test-MMTreeEqual $files @(Get-MMTree $archive)) 'Archived bytes differ from the verified copy.'
    $acl=Get-Acl -LiteralPath (Join-Path $archive 'nested\state.json')
    Check ($acl.AreAccessRulesProtected -and @($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544') }).Count -eq 0) 'An archive file retained its old public ACL.'
    $json=Join-Path $temporary 'report.json';Write-MMJson $json @{phase='verified'};Write-MMJson $json @{phase='completed'}
    Check ((Read-MMJson $json).phase -ceq 'completed' -and [IO.File]::Exists($json+'.previous')) 'Atomic reports must retain their preceding revision.'
    Write-Output ('Moonshine maintenance: '+$checks+' filesystem/dependency/task/backup checks passed; no production service or driver changed.')
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }

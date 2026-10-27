#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$trial=Join-Path $root 'tools\moonshine-trial'
$checks=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:checks++ }
function Refuses([scriptblock]$Action,[string]$Message) { $refused=$false;try { & $Action | Out-Null } catch { $refused=$true };Check $refused $Message }
$scripts=@(Get-ChildItem -LiteralPath $trial -Filter '*.ps1');$scripts+=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')
foreach ($file in $scripts) {
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) ('PowerShell parse failure: '+$file.Name+': '+($errors | Out-String))
}
Add-Type -Path (Join-Path $PSScriptRoot 'restricted_process.cs')
& (Join-Path $trial 'Demarrer-Moonshine.ps1') -ValidateWindowOnly
. (Join-Path $trial 'Sauvegarde-Moonshine.ps1')
. (Join-Path $trial 'Trial-Setup.ps1')
$temp=Join-Path $env:TEMP ('Moonshine-TrialKitTests-'+[guid]::NewGuid().ToString('N'))
try {
    $config=Join-Path $temp 'Production\config';[IO.Directory]::CreateDirectory($config) | Out-Null
    $apps=Join-Path $config 'apps.json';$original='{"apps":[{"name":"Personal existing app","uuid":"keep-me"}]}';[IO.File]::WriteAllText($apps,$original)
    $backup=Backup-MoonshineSource $config @{} (Join-Path $temp 'Backups')
    Check ([IO.File]::ReadAllText($apps) -ceq $original) 'Backup modified production bytes.'
    $restored=Restore-MoonshineBackup $backup (Join-Path $temp 'Restored')
    Check ([IO.File]::ReadAllText((Join-Path $restored 'host_config\apps.json')) -ceq $original) 'Restored bytes differ.'
    Refuses { Restore-MoonshineBackup $backup $config } 'Restore accepted an existing folder.'
    Refuses { Backup-MoonshineSource $config @{} (Join-Path $config 'Backups') } 'Backup accepted recursion into its own source.'
    [IO.File]::AppendAllText((Join-Path $backup 'Files\host_config\apps.json'),'tamper')
    $failed=Join-Path $temp 'MustNotExist';Refuses { Restore-MoonshineBackup $backup $failed } 'Tampered backup was accepted.'
    Check (-not (Test-Path -LiteralPath $failed)) 'Tampered restore wrote files before verification.'
    $kit=Join-Path $temp 'Kit';$fake=@{
        'Package/sunshine.exe'='not executable - fixture only'
        'Package/tools/moonshine/SHA256.txt'='synthetic manifest'
        'Package/moonshine-trial-only.txt'='trial'
        'Package/tools/moonshine/moonshine-trial-only.txt'='trial'
    }
    $rows=@()
    foreach ($path in $fake.Keys) {
        $full=Join-Path $kit $path;[IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null;[IO.File]::WriteAllText($full,$fake[$path])
        $rows+=@{path=$path;size=(Get-Item -LiteralPath $full).Length;sha256=(Get-FileHash -LiteralPath $full).Hash.ToLowerInvariant()}
    }
    [IO.File]::WriteAllText((Join-Path $kit 'manifest.json'),(ConvertTo-Json -InputObject @{schema='moonshine-trial-kit/1';commit=('a'*40);files=@($rows)} -Depth 8))
    $script:MoonshineTrialBase=Join-Path $temp 'PrivateTrials'
    $instance=Get-MoonshineTrialInstance $kit;$same=Get-MoonshineTrialInstance $kit
    Check ($instance.Id -ceq $same.Id) 'Reopening the same kit created a new identity.'
    $null=Prepare-MoonshineTrialInstance $instance
    Check ([IO.File]::ReadAllText((Join-Path $instance.Package 'tools\moonshine\moonshine-trial-id.txt')) -ceq $instance.Id) 'Engine isolation marker missing.'
    Check ((Get-Content -LiteralPath (Join-Path $instance.Package 'config\moonshine.conf') -Raw) -match 'port = 48989') 'Trial port missing.'
    $privateExe=Join-Path $instance.Package 'sunshine.exe';[IO.File]::WriteAllText($privateExe,'broken private copy')
    $null=Prepare-MoonshineTrialInstance $instance
    Check ([IO.File]::ReadAllText($privateExe) -ceq $fake['Package/sunshine.exe']) 'Private repair failed.'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $instance.Root 'Recovery') -Recurse -Filter sunshine.exe).Count -eq 1) 'Repair did not preserve changed bytes.'
    Check ([IO.File]::ReadAllText($apps) -ceq $original) 'Trial preparation touched production.'
    [IO.File]::AppendAllText((Join-Path $kit 'Package\sunshine.exe'),'tamper')
    Refuses { Prepare-MoonshineTrialInstance $instance } 'An altered source kit could repair or start a trial.'
    Check ([IO.File]::ReadAllText($privateExe) -ceq $fake['Package/sunshine.exe']) 'Altered kit changed the private executable.'
    Write-Output ('Moonshine portable trial: '+$checks+' checks passed (WPF construction, backup, restoration, source verification, private repair and isolation).')
} finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force } }

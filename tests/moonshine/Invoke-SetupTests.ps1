#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$setup=Join-Path $root 'tools\moonshine-setup'
$checks=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:checks++ }
function Refuses([scriptblock]$Action,[string]$Message) { $bad=$false;try { & $Action | Out-Null } catch { $bad=$true };Check $bad $Message }
foreach ($file in @(Get-ChildItem -LiteralPath $setup -Filter '*.ps1')) {
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) ('Setup parse failed: '+$file.Name+': '+($errors | Out-String))
}
& (Join-Path $setup 'Gestion-Moonshine.ps1') -ValidateWindowOnly
. (Join-Path $setup 'Installation.ps1')
. (Join-Path $setup 'Pilotes.ps1')
$temporary=Join-Path $env:TEMP ('moonshine-setup-tests-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    $old=Join-Path $temporary 'Old';$new=Join-Path $temporary 'New'
    $value=ConvertFrom-Json -InputObject ('{"apps":[{"uuid":"keep","cmd":"'+($old+'\versions\0.8.1\Launch-Game.ps1').Replace('\','\\')+'","pref":false}],"empty":[],"count":0,"none":null}')
    $converted=Convert-MoonshinePaths $value $old $new
    Check ($converted.apps[0].cmd -ceq (Join-Path $new 'versions\1.0.0\Launch-Game.ps1')) 'A known runtime reference was not moved to the installed engine.'
    Check ($converted.apps[0].uuid -ceq 'keep' -and $converted.apps[0].pref -is [bool] -and -not $converted.apps[0].pref) 'Migration changed identity or a false personal setting.'
    Check ($converted.empty -is [array] -and $converted.empty.Count -eq 0 -and $converted.count -eq 0 -and $null -eq $converted.none) 'JSON array/scalar/null shapes changed.'
    Check ((Convert-MoonshinePaths ($old+'-other\game.exe') $old $new) -ceq ($old+'-other\game.exe')) 'A neighboring path prefix was rewritten.'
    Check ((Convert-MoonshinePaths 'D:\SteamLibrary\Game' $old $new) -ceq 'D:\SteamLibrary\Game') 'The installed game path was rewritten.'
    Check ((Convert-MoonshinePaths ('-DataRoot "'+$old+'"') $old $new) -ceq ('-DataRoot "'+$new+'"')) 'Quoted data root did not migrate.'
    [IO.Directory]::CreateDirectory((Join-Path $old 'Games')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $old 'versions\0.8.1')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $old 'Packages\0.8.1')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $old 'Games\game.json'),'{"uuid":"keep"}')
    [IO.File]::WriteAllText((Join-Path $old 'versions\0.8.1\old.ps1'),'throw "Old code must never run"')
    [IO.File]::WriteAllText((Join-Path $old 'Packages\0.8.1\old.ps1'),'throw "Old code must never run"')
    Copy-MoonshineLibraryData $old $new
    Check ([IO.File]::Exists((Join-Path $new 'Games\game.json'))) 'User game descriptor was not copied.'
    Check (-not [IO.Directory]::Exists((Join-Path $new 'versions')) -and -not [IO.Directory]::Exists((Join-Path $new 'Packages'))) 'Migration copied a previous executable engine.'
    $config=Join-Path $temporary 'config';[IO.Directory]::CreateDirectory($config) | Out-Null
    [IO.File]::WriteAllText((Join-Path $config 'moonshine.conf'),'port = 48989')
    [IO.File]::WriteAllText((Join-Path $old 'state.json'),'{"schema":"opi5-xbox-state/1","managed":{},"pending":{}}')
    Assert-MoonshineMigrationReady $old $config;Check $true 'A complete idle source was rejected.'
    [IO.File]::WriteAllText((Join-Path $old 'state.json'),'{"schema":"opi5-xbox-state/1","managed":{},"pending":{"x":{}}}')
    Refuses { Assert-MoonshineMigrationReady $old $config } 'Pending writes must block migration.'
    [IO.File]::WriteAllText((Join-Path $old 'state.json'),'{"schema":"opi5-xbox-state/1","managed":{},"pending":{}}')
    [IO.File]::WriteAllText((Join-Path $old 'undo-control.json'),'{"status":"undoing"}')
    Refuses { Assert-MoonshineMigrationReady $old $config } 'An unfinished undo must block migration.'
    [IO.File]::Delete((Join-Path $old 'undo-control.json'))
    [IO.File]::WriteAllText((Join-Path $config 'moonshine.conf'),'file_apps = D:\custom.json')
    Refuses { Assert-MoonshineMigrationReady $old $config } 'A custom live catalogue path must block implicit migration.'
    $outside=Join-Path $temporary 'outside';[IO.Directory]::CreateDirectory($outside) | Out-Null
    $junction=Join-Path $old 'linked';$null=New-Item -ItemType Junction -Path $junction -Target $outside
    Refuses { Copy-MoonshineLibraryData $old (Join-Path $temporary 'must-not-traverse') } 'Source junctions must be preserved without traversal.'
    [IO.Directory]::Delete($junction)
    $inf=Join-Path $temporary 'test.inf';[IO.File]::WriteAllText($inf,"[Version]`r`nDriverVer=01/01/2026,1.6.4.0`r`n")
    Check ((Get-MoonshineInfVersion $inf) -eq [version]'1.6.4.0') 'Component version was not read numerically.'
    $store=Join-Path $temporary 'store.inf';[IO.File]::WriteAllText($store,"[Version]`r`nDriverVer=01/01/2020,1.6.5.0`r`n")
    $script:StoreVersionFixture=$store
    function Get-WindowsDriver { param([switch]$Online,[switch]$All,$ErrorAction) [pscustomobject]@{OriginalFileName=$script:StoreVersionFixture;Driver='oem1.inf'} }
    # Bind the fixture filename to the candidate; the dates deliberately disagree.
    $candidate=Join-Path $temporary 'candidate\store.inf';[IO.Directory]::CreateDirectory((Split-Path -Parent $candidate)) | Out-Null;[IO.File]::Copy($inf,$candidate)
    Refuses { Assert-MoonshineNodeRepairVersion $candidate } 'A newer staged driver must never be downgraded because of its older date.'
    [IO.File]::WriteAllText($store,"[Version]`r`nDriverVer=01/01/2020,1.6.4.0`r`n")
    Assert-MoonshineNodeRepairVersion $candidate;Check $true 'An equal staged component may recreate its missing node.'
    [IO.File]::WriteAllText($store,'invalid')
    Refuses { Assert-MoonshineNodeRepairVersion $candidate } 'Unknown staged versions must prevent node replacement.'
    $script:MoonshineServiceRoot=Join-Path $temporary 'ToolFixture';[IO.Directory]::CreateDirectory((Join-Path $script:MoonshineServiceRoot 'Package\config')) | Out-Null
    $child=Join-Path $temporary 'diagnostic.ps1';[IO.File]::WriteAllText($child,"[Console]::Error.WriteLine('precise synthetic failure');exit 5")
    $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $message='';try { $null=Invoke-MoonshineDriverTool $ps @('-NoProfile','-File',$child) } catch { $message=$_.Exception.Message }
    Check ($message -match 'precise synthetic failure' -and $message -match 'code 5') 'The actual native exit code or stderr was lost.'
    Check ([IO.File]::ReadAllText((Join-Path $script:MoonshineServiceRoot 'Package\config\driver-setup.log')).Contains('precise synthetic failure')) 'The native diagnostic was not retained locally.'
    [IO.File]::WriteAllText($child,'exit 3010')
    Check ((Invoke-MoonshineDriverTool $ps @('-NoProfile','-File',$child)) -eq 3010) 'A native restart-required result was lost.'
    Write-Output ('Moonshine ZIP setup: '+$checks+' WPF/migration/shape/path/driver-policy checks passed; no service, driver or trust modified.')
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }

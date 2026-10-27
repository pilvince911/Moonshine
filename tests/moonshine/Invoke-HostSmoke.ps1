#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$KitRoot,[string]$Evidence='build-evidence\native-smoke.json')
$ErrorActionPreference='Stop'
$KitRoot=[IO.Path]::GetFullPath($KitRoot)
. (Join-Path $KitRoot 'Trial-Setup.ps1')
$null=Read-MoonshineTrialManifest $KitRoot
Add-Type -Path (Join-Path $PSScriptRoot 'restricted_process.cs')
$temporary=Join-Path $env:PUBLIC ('MoonshineCI-'+[guid]::NewGuid().ToString('N'));$child=$null
try {
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    $acl=Get-Acl -LiteralPath $temporary;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,[Security.AccessControl.FileSystemRights]::FullControl,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule);Set-Acl -LiteralPath $temporary -AclObject $acl
    $package=Join-Path $temporary 'Package';Copy-Item -LiteralPath (Join-Path $KitRoot 'Package') -Destination $package -Recurse
    $script=Join-Path $temporary 'Invoke-HostSmokeChild.ps1';Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-HostSmokeChild.ps1') -Destination $script
    $result=Join-Path $temporary 'result.json';$powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command='"'+$powershell+'" -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$script+'" -Package "'+$package+'" -Output "'+$result+'"'
    $trace=Join-Path $temporary 'startup.txt'
    $command='"'+$env:ComSpec+'" /d /s /c "'+$command+' > "'+$trace+'" 2>&1"'
    $child=[MoonshineRestrictedProcess]::Start($command,$temporary)
    if (-not $child.WaitForExit(420000)) { throw 'Non-administrator native smoke timed out.' }
    if (-not (Test-Path -LiteralPath $result)) {
        $startup=if (Test-Path -LiteralPath $trace) { [IO.File]::ReadAllText($trace) } else { 'No startup output.' }
        throw ('Non-administrator native smoke did not return a result; exit='+$child.ExitCode+'; startup='+$startup.Substring(0,[Math]::Min(1400,$startup.Length)))
    }
    $data=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($result))
    [IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($Evidence)))) | Out-Null
    Copy-Item -LiteralPath $result -Destination $Evidence -Force
    if ($child.ExitCode -ne 0 -or $data.status -ne 'passed') { throw ('Native smoke failed: '+$data.error+'; '+$data.stack) }
    Write-Output ('Complete Moonshine host: non-admin HTTPS/auth/scoped token/real PowerShell worker/confirmed reset/restore/personal-entry preservation/isolation/clean shutdown passed; '+$data.engine_tests+' embedded engine tests.')
} finally {
    if (-not $child -or $child.HasExited) { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue } }
    if ($child) { $child.Dispose() }
}

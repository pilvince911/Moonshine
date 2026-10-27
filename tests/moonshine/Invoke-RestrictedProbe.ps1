#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Test-User.ps1')
$testUser=$null;$child=$null
Add-Type -Path (Join-Path $PSScriptRoot 'test_user_process.cs')
$folder=Join-Path $env:PUBLIC ('MoonshineTokenProbe-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $testUser=New-MoonshineCITestUser
    Grant-MoonshineCITestFolder $folder $testUser
    $result=Join-Path $folder 'result.json';$trace=Join-Path $folder 'startup.txt'
    $code='$i=[Security.Principal.WindowsIdentity]::GetCurrent();$p=New-Object Security.Principal.WindowsPrincipal($i);[IO.File]::WriteAllText('''+$result.Replace("'","''")+''',(ConvertTo-Json @{system=$i.IsSystem;admin=$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}))'
    $script=Join-Path $folder 'probe.ps1'
    [IO.File]::WriteAllText($script,$code,(New-Object Text.UTF8Encoding($true)))
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command='"'+$env:ComSpec+'" /d /s /c ""'+$powershell+'" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$script+'" > "'+$trace+'" 2>&1"'
    Write-Output ('CI caller SYSTEM: '+[Security.Principal.WindowsIdentity]::GetCurrent().IsSystem+'; startup command length: '+$command.Length)
    $child=[MoonshineTestUserProcess]::Start($command,$folder,$testUser.Name,$testUser.Password)
    if (-not $child.WaitForExit(30000)) { throw 'Restricted-token fixture timed out.' }
    if (-not (Test-Path -LiteralPath $result)) {
        $startup=if (Test-Path -LiteralPath $trace) { [IO.File]::ReadAllText($trace) } else { 'No startup output.' }
        throw ('Restricted-token startup failed; exit='+$child.ExitCode+'; '+$startup)
    }
    $data=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($result))
    if ($child.ExitCode -ne 0 -or $data.system -or $data.admin) { throw 'The child did not use a normal Windows identity.' }
    Write-Output 'Standard Windows test account: PowerShell startup and non-administrator execution passed.'
} finally { if (-not $child -or $child.HasExited) { Remove-MoonshineCITestUser $testUser };if ($child) { $child.Dispose() };if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue } }

# Synthetic transport fixture. No game discovery, file changes or network calls.
param([Parameter(Mandatory=$true)][string]$PipeName)
$ErrorActionPreference='Stop'
$channel=New-Object IO.Pipes.NamedPipeClientStream('.', $PipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None, [Security.Principal.TokenImpersonationLevel]::Identification)
$channel.Connect(30000)
$encoding=New-Object Text.UTF8Encoding($false)
[Console]::SetIn((New-Object IO.StreamReader($channel,$encoding,$false,4096,$true)))
$writer=New-Object IO.StreamWriter($channel,$encoding,4096,$true);$writer.AutoFlush=$true
[Console]::SetOut($writer)
function Event([string]$Type,$Data) { [Console]::WriteLine((ConvertTo-Json -InputObject @{type=$Type;data=$Data} -Compress));[Console]::Out.Flush() }
$boot=ConvertFrom-Json -InputObject ([Console]::ReadLine())
if ($boot.protocol -ne 'moonshine-worker/1' -or -not $boot.token -or $boot.token.Length -lt 16) { exit 2 }
$event=[Threading.EventWaitHandle]::OpenExisting($boot.cancel_event)
try {
    Event 'progress' @{message='Fixture prête';percent=25}
    Event 'prompt' @{message='Confirmation synthétique';expected='APPLIQUER';typed=$false;rows=@()}
    $reply=ConvertFrom-Json -InputObject ([Console]::ReadLine())
    if ($event.WaitOne(0)) { Event 'cancelled' @{message='Annulation synthétique confirmée'} }
    elseif ($reply.answer -ceq 'APPLIQUER') { Event 'complete' @{message='Transport et confirmation vérifiés'} }
    else { Event 'complete' @{message='Plan synthétique refusé'} }
} finally { $event.Dispose();$boot.token=$null;$channel.Dispose() }

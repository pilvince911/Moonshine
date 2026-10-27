#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^706c6f73-7862-[a-f0-9-]{22}$')][string]$GameId,
    [Parameter(Mandatory=$true)][string]$DataRoot
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'EA.ps1')
$log=$null
function Launch-Log([string]$Event,$Details=$null) {
    if (-not $log) { return }
    $r=[ordered]@{time=(Get-Date).ToString('o');game=$GameId;event=$Event;details=$Details}
    [IO.File]::AppendAllText($log,((ConvertTo-Json -InputObject $r -Depth 8 -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
}
try {
    if ((Get-MoonshineTrialId) -and [IO.Path]::GetFullPath($DataRoot).TrimEnd('\') -ine [IO.Path]::GetFullPath((Get-MoonshineDataRoot)).TrimEnd('\')) { throw 'Ce lanceur est reserve aux donnees de cet essai Moonshine.' }
    if (-not (Local-Path $DataRoot)) { throw 'Dossier local invalide.' }
    $logDir=Join-Path $DataRoot 'Logs'
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $log=Join-Path $logDir ('launch-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.jsonl')
    $game=Read-Json (Join-Path (Join-Path $DataRoot 'Games') ($GameId+'.json'))
    if (-not $game -or $game.schema -ne 'opi5-xbox-game/1' -or (Stable-Id $game.key) -ne $GameId -or $game.uuid -ne $GameId) {
        throw 'Fiche de lancement absente ou incoherente. Relancer la synchronisation.'
    }
    $current=[Security.Principal.WindowsIdentity]::GetCurrent()
    if ($current.IsSystem -or $current.User.Value -ne $game.user_sid) {
        throw 'Le lancement doit utiliser la session Windows qui a synchronise les jeux.'
    }
    Launch-Log 'requested' @{kind=$game.kind;title=$game.title}
    if ($game.kind -eq 'steam') {
        if ($game.steam_id -notmatch '^\d+$' -or $game.key -ne ('steam:'+$game.steam_id)) { throw 'Identifiant Steam invalide.' }
        if (-not (Test-Path -LiteralPath $game.install -PathType Container)) { throw 'Installation Steam introuvable.' }
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName='steam://rungameid/'+$game.steam_id
        $start.UseShellExecute=$true
        [Diagnostics.Process]::Start($start) | Out-Null
        # VibeShine tracks Steam through steam-id and steam-install-dir.
        Launch-Log 'handed_to_steam' @{lifecycle='VibeShine native Steam tracker';game_start_confirmed=$false}
        exit 0
    }
    $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
    Init-Native
    $names=@()
    if ($game.kind -eq 'xbox') {
        if ($game.aumid -notmatch '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$' -or $game.key -ine ('xbox:'+$game.aumid)) { throw 'Identifiant Xbox incoherent.' }
        $names=@($game.monitor_names | Where-Object { $_ -match '^[A-Za-z0-9 _().-]{1,180}$' -and $_ -notmatch '^(GameLaunchHelper|GamingServices)$' })
        if ($names.Count -eq 0) { throw 'Executable du jeu non identifie.' }
        $activationPid=[OPi5Native]::Activate($game.aumid)
        Launch-Log 'windows_activation' @{activation_pid=$activationPid;monitor_names=$names}
    } elseif ($game.kind -eq 'ea') {
        if (-not (EA-ValidId $game.ea_content_id) -or $game.key -ine ('ea:'+$game.ea_content_id)) { throw 'Identifiant EA incoherent.' }
        if (-not (Local-Path $game.install) -or -not (Test-Path -LiteralPath $game.install -PathType Container)) { throw 'Installation EA introuvable.' }
        $metadata=EA-ReadMetadata $game.install $game.title
        if ($metadata.reason -or $game.ea_content_id -notin @($metadata.content_ids)) { throw 'Le manifeste EA ne confirme plus ce jeu; refaire la synchronisation.' }
        $protocol=EA-Protocol
        if (-not $protocol.ready) { throw $protocol.reason }
        $names=@($metadata.monitor_names)
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=EA-LaunchUri $game.ea_content_id
        $start.UseShellExecute=$true
        [Diagnostics.Process]::Start($start) | Out-Null
        Launch-Log 'handed_to_ea' @{content_id=$game.ea_content_id;monitor_names=$names;tracking='Installation directory, same Windows session';game_start_confirmed=$false}
    } else { throw 'Type de lancement non pris en charge.' }
    # GameLaunchHelper's PID is diagnostic only. Its early exit is not game exit.
    $started=$false;$focused=$false;$lastSeen=$null
    $deadline=(Get-Date).AddSeconds(180)
    while ($true) {
        $processes=@()
        if ($game.kind -eq 'ea') {
            foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
                try {
                    if ($p.SessionId -ne $session) { continue }
                    $processPath=''
                    try { $processPath=$p.Path } catch { }
                    if (EA-IsGameProcess $processPath $p.ProcessName $game.install $names) { $processes+=$p }
                } catch { }
            }
        } else {
            foreach ($name in $names) {
                foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                    try { if ($p.SessionId -eq $session) { $processes+=$p } } catch {}
                }
            }
        }
        if ($processes.Count -gt 0) {
            $lastSeen=Get-Date
            if (-not $started) {
                $started=$true
                Launch-Log 'game_process_observed' @{pids=@($processes.Id);names=@($processes.ProcessName);match=$(if ($game.kind -eq 'ea') {'EA directory or declared executable, same session'} else {'GDK executable name and same Windows session'})}
            }
            if (-not $focused) {
                foreach ($p in $processes) {
                    try {
                        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [OPi5Native]::Focus($p.MainWindowHandle);$focused=$true;break }
                    } catch {}
                }
            }
        } elseif ($started -and ((Get-Date)-$lastSeen).TotalSeconds -ge 15) {
            Launch-Log 'game_exit_observed' @{grace_seconds=15}
            exit 0
        } elseif (-not $started -and (Get-Date) -gt $deadline) {
            Launch-Log 'tracking_unknown_keep_stream' @{reason='Aucun vrai processus observe dans les 180 secondes.'}
            # Keep streaming until Moonlight ends the session; never close it
            # merely because the activation helper returned or a PID was hidden.
            $deadline=[datetime]::MaxValue
        }
        Start-Sleep -Seconds 2
    }
} catch {
    try { Launch-Log 'error' @{message=(Redact $_.Exception.Message)} } catch {}
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}

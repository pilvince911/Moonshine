#Requires -Version 5.1
# Compatibility names are intentionally confined here. Stable UUIDs stay unchanged.
$script:LegacyBrand='plOS'
$script:LegacyOwner='plos-xbox-sync/1'
$script:LegacyStateSchema='plos-xbox-state/1'
$script:LegacyTransactionSchema='plos-xbox-transaction/1'
$script:LegacyFields=@{'opi5-xbox-owner'='plos-xbox-owner';'opi5-xbox-key'='plos-xbox-key'}
function Legacy-DataRoot { return Join-Path $env:LOCALAPPDATA ($script:LegacyBrand+'\VibeShine-Xbox') }
function Legacy-TaskName { return $script:LegacyBrand+'-VibeShine-Xbox-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Import-LegacyData([string]$Destination,[string]$Source) {
    $marker=Join-Path $Destination 'brand-migration.json'
    if (-not (Test-Path -LiteralPath $Source -PathType Container) -or (Test-Path -LiteralPath $marker)) { return }
    $locks=@()
    try {
        foreach ($name in @('bootstrap.lock','sync.lock')) {
            try { $locks+=@([IO.File]::Open((Join-Path $Source $name),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)) }
            catch { throw 'Fermer les anciens menus du synchronisateur avant de migrer les donnees vers OPi5.' }
        }
        $copied=0;$kept=0
        $queue=New-Object 'Collections.Generic.Queue[object]'
        $queue.Enqueue(@{source=$Source;target=$Destination;root=$true})
        while ($queue.Count -gt 0) {
            $entry=$queue.Dequeue()
            foreach ($item in @(Get-ChildItem -LiteralPath $entry.source -Force -ErrorAction Stop)) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Name -like '*.lock') { continue }
                if ($entry.root -and $item.PSIsContainer -and $item.Name -in @('versions','Packages')) { continue }
                $target=Join-Path $entry.target $item.Name
                if ($item.PSIsContainer) { $queue.Enqueue(@{source=$item.FullName;target=$target;root=$false});continue }
                if (Test-Path -LiteralPath $target) { $kept++;continue }
                Write-AtomicBytes $target ([IO.File]::ReadAllBytes($item.FullName))
                if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash) { throw 'Copie de migration non verifiee; originaux conserves.' }
                $copied++
            }
        }
        $record=@{schema='opi5-brand-migration/1';complete=$true;time=(Get-Date).ToString('o');copied=$copied;existing_preserved=$kept}
        Write-AtomicBytes $marker ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $record -Depth 4)))
    } finally { foreach ($held in $locks) { $held.Dispose() } }
}
function Migrate-LegacyAutomation {
    $current=Get-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -ErrorAction SilentlyContinue
    $old=Get-ScheduledTask -TaskName (Legacy-TaskName) -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $old) { return }
    if (@($old.Actions).Count -ne 1 -or -not (Test-ManagedAutomationAction @($old.Actions)[0] (Legacy-DataRoot))) {
        $null=Disable-ScheduledTask -TaskName (Legacy-TaskName) -TaskPath '\' -ErrorAction Stop
        Repair-Event 'schedule' 'legacy_custom_paused' 'Ancienne action personnalisee conservee et mise en pause; verifier les choix 7 et 9.'
        return
    }
    $recovery=Join-Path $script:Data 'Recovery';[IO.Directory]::CreateDirectory($recovery) | Out-Null
    $xml=Export-ScheduledTask -TaskName (Legacy-TaskName) -TaskPath '\' -ErrorAction Stop
    Write-AtomicBytes (Join-Path $recovery ('ancienne-tache-'+[guid]::NewGuid().ToString('N')+'.xml')) ([Text.Encoding]::UTF8.GetBytes($xml))
    $enabled=[bool]$old.Settings.Enabled;$created=$false
    try {
        $null=Disable-ScheduledTask -TaskName (Legacy-TaskName) -TaskPath '\' -ErrorAction Stop
        if (-not $current) {
            $action=New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument (Automation-Arguments $script:Data $script:Version)
            $null=Register-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -Action $action -Trigger $old.Triggers -Settings $old.Settings -Principal $old.Principal -Description 'OPi5 : synchronisation VibeShine des jeux PC, sans suppression automatique.' -ErrorAction Stop
            $created=$true
            $check=Get-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -ErrorAction Stop
            if ([bool]$check.Settings.Enabled -ne $enabled -or @($check.Actions).Count -ne 1 -or
                [string]$check.Actions[0].Arguments -cne (Automation-Arguments $script:Data $script:Version)) { throw 'Migration de la tache non confirmee.' }
        }
        $null=Unregister-ScheduledTask -TaskName (Legacy-TaskName) -TaskPath '\' -Confirm:$false -ErrorAction Stop
        Repair-Event 'schedule' 'renamed' 'Tache migree vers OPi5; ancienne definition sauvegardee en prive.'
    } catch {
        if ($created) { try { $null=Unregister-ScheduledTask -TaskName (Task-Name) -TaskPath '\' -Confirm:$false -ErrorAction Stop } catch {} }
        if ($enabled -and -not $current) { try { $null=Enable-ScheduledTask -TaskName (Legacy-TaskName) -TaskPath '\' -ErrorAction Stop } catch {} }
        throw
    }
}

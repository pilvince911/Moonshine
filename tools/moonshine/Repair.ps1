#Requires -Version 5.1
$script:Repairs=New-Object 'Collections.Generic.List[object]'
function Repair-Event([string]$Area,[string]$Action,[string]$Detail) {
    $clean=Redact $Detail
    if ($script:Repairs.Count -gt 0) {
        $last=$script:Repairs[$script:Repairs.Count-1]
        if ($last.area -eq $Area -and $last.action -eq $Action -and $last.detail -ceq $clean) { return }
    }
    if ($script:Repairs.Count -ge 500) { $script:Repairs.RemoveAt(0) }
    [void]$script:Repairs.Add(@{time=(Get-Date).ToString('o');area=$Area;action=$Action;detail=$clean})
}
function Preserve-RecoveryFile([string]$Path,[string]$Area) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $folder=Join-Path $script:Data 'Recovery'
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $name=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'-'+[IO.Path]::GetFileName($Path)
    Copy-Item -LiteralPath $Path -Destination (Join-Path $folder $name) -ErrorAction Stop
    Repair-Event $Area 'preserved' ([IO.Path]::GetFileName($Path))
}
function Read-OptionalJson([string]$Path) {
    try { return Read-Json $Path }
    catch {
        Preserve-RecoveryFile $Path 'diagnostic-cache'
        Write-Json $Path $null
        Repair-Event 'diagnostic-cache' 'reset' ([IO.Path]::GetFileName($Path))
        return $null
    }
}
function Repair-History {
    $path=Join-Path $script:Data 'repair-history.json'
    $old=Read-OptionalJson $path
    $seen=@{};$events=@()
    $writes=@()
    if ($script:SelfTestStatus -eq 'passed') { $writes=@($script:AtomicWriteEvents.ToArray()) }
    foreach ($event in @(@(Field $old 'events' @())+@($script:Repairs.ToArray())+$writes | Where-Object { $null -ne $_ } | Sort-Object { $_.time })) {
        $key=Canonical $event
        if (-not $seen.ContainsKey($key)) { $seen[$key]=$true;$events+=@($event) }
    }
    $history=@{schema='opi5-xbox-repairs/1';events=@($events | Select-Object -Last 100)}
    if (-not (Same $old $history)) { Write-Json $path $history }
    return @($history.events)
}
function App-PathKey([string]$Path) {
    if ($Path -notmatch '\A[A-Za-z]:[\\/]' -or $Path -match '[\r\n\x00]') { return $Path }
    try { return [IO.Path]::GetFullPath($Path.Replace('/','\')).TrimEnd('\').ToLowerInvariant() }
    catch { return $Path }
}
function Automation-Arguments([string]$Data,[string]$Version) {
    $bootstrap=Join-Path (Join-Path (Join-Path $Data 'Packages') $Version) 'Bootstrap.ps1'
    return '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$bootstrap+'" -Action SyncAll -Unattended'
}
function Test-ManagedAutomationAction($Action,[string]$Data) {
    $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ((App-PathKey ([string]$Action.Execute)) -ne (App-PathKey $ps)) { return $false }
    $m=[regex]::Match([string]$Action.Arguments,'\A-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "(?<script>[^"\r\n]+)" -Action SyncAll -Unattended\z',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $false }
    $path=App-PathKey $m.Groups['script'].Value
    $prefix=(App-PathKey $Data)+'\'
    if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $relative=$path.Substring($prefix.Length)
    $known=[regex]::Match($relative,'\A(?<tree>versions|packages)\\(?<version>\d+\.\d+\.\d+)\\(?<file>vibeshine-xbox|bootstrap)\.ps1\z')
    if (-not $known.Success -or ($known.Groups['tree'].Value -eq 'packages' -and $known.Groups['file'].Value -ne 'bootstrap')) { return $false }
    $directory=[string](Field $Action 'WorkingDirectory')
    if ($directory -and (App-PathKey $directory) -ne (App-PathKey (Join-Path (Join-Path $Data 'versions') $known.Groups['version'].Value))) { return $false }
    return $true
}
function Managed-CommandParts([string]$Command) {
    $pattern='\A"(?<ps>[A-Za-z]:[^"\r\n]+[\\/]powershell\.exe)" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "(?<launcher>[A-Za-z]:[^"\r\n]+[\\/]Launch-Game\.ps1)" -GameId "(?<uuid>706c6f73-7862-[a-f0-9-]{22})" -DataRoot "(?<data>[A-Za-z]:[^"\r\n]+)"\z'
    $m=[regex]::Match($Command,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $null }
    return @{ps=(App-PathKey $m.Groups['ps'].Value);launcher=(App-PathKey $m.Groups['launcher'].Value);uuid=$m.Groups['uuid'].Value.ToLowerInvariant();data=(App-PathKey $m.Groups['data'].Value)}
}
function App-FieldSame([string]$Key,$A,$B) {
    if (Same $A $B) { return $true }
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($Key -in @('working-dir','steam-install-dir','image-path')) {
        if ($A -is [string] -and $B -is [string]) { return (App-PathKey $A) -ceq (App-PathKey $B) }
    } elseif ($Key -eq 'cmd') {
        $left=Managed-CommandParts ([string]$A);$right=Managed-CommandParts ([string]$B)
        if ($left -and $right) { return Same $left $right }
    } elseif ($Key -in @('auto-detach','wait-all','elevated','exclude-global-prep-cmd')) {
        $values=@()
        foreach ($v in @($A,$B)) {
            if ($v -is [bool]) { $values+=@([bool]$v) }
            elseif ($v -is [string] -and ($v -ceq 'true' -or $v -ceq 'false')) { $values+=@($v -ceq 'true') }
            else { return $false }
        }
        return $values[0] -eq $values[1]
    } elseif ($Key -eq 'exit-timeout') {
        $left=0L;$right=0L
        if ([long]::TryParse([string]$A,[ref]$left) -and [long]::TryParse([string]$B,[ref]$right)) { return $left -eq $right }
    }
    return $false
}
function Same-App($A,$B) {
    if ($null -eq $A -or $null -eq $B) { return $null -eq $A -and $null -eq $B }
    $left=Clean-App $A;$right=Clean-App $B
    $keys=@(@(Keys $left)+@(Keys $right) | Sort-Object -Unique)
    foreach ($key in $keys) {
        if ($left.Contains($key) -ne $right.Contains($key) -or -not (App-FieldSame $key (Field $left $key) (Field $right $key))) { return $false }
    }
    return $true
}
function Test-StateShape($State) {
    if (-not $State -or (Field $State 'schema') -notin @('opi5-xbox-state/1',$script:LegacyStateSchema)) { return $false }
    foreach ($name in @('managed','pending')) {
        $map=Field $State $name
        if ($null -eq $map -or -not ($map -is [Collections.IDictionary] -or $map.GetType().FullName -eq 'System.Management.Automation.PSCustomObject')) { return $false }
    }
    foreach ($uuid in @(Keys $State.managed)) {
        $r=Field $State.managed $uuid
        $fields=Field $r 'fields'
        if (-not (Field $r 'key') -or $uuid -ne (Stable-Id $r.key) -or $null -eq $fields -or
            -not ($fields -is [Collections.IDictionary] -or $fields.GetType().FullName -eq 'System.Management.Automation.PSCustomObject')) { return $false }
    }
    foreach ($uuid in @(Keys $State.pending)) {
        $r=Field $State.pending $uuid
        if (-not (Field $r 'after') -or [string]$r.after.uuid -ne $uuid -or -not (Field $r 'new_state')) { return $false }
        $newState=$r.new_state;$fields=Field $newState 'fields'
        if (-not (Field $newState 'key') -or $uuid -ne (Stable-Id $newState.key) -or $null -eq $fields -or
            -not ($fields -is [Collections.IDictionary] -or $fields.GetType().FullName -eq 'System.Management.Automation.PSCustomObject')) { return $false }
    }
    return $true
}
function State-Map($State) {
    return [ordered]@{schema='opi5-xbox-state/1';managed=(To-Map $State.managed);pending=(To-Map $State.pending)}
}
function Repair-ManagedState($State,$Apps,$Games,[string]$Runtime,[string]$Data) {
    $changed=$false
    foreach ($game in @($Games)) {
        if ((Field $State.managed $game.uuid) -or (Field $State.pending $game.uuid)) { continue }
        $found=@($Apps | Where-Object { (Field $_ 'uuid') -eq $game.uuid })
        if ($found.Count -ne 1 -or -not (Owned $found[0] $game.key)) { continue }
        $app=$found[0]
        $baseline=Desired-Fields $game $Runtime $Data
        # Baseline = expected fields, not current user preferences. A renamed
        # title, custom cover or setting remains different and is preserved.
        $parts=Managed-CommandParts ([string](Field $app 'cmd'))
        if ($parts -and $parts.uuid -eq $game.uuid -and $parts.data -in @((App-PathKey $Data),(App-PathKey (Legacy-DataRoot))) -and
            $parts.ps -eq (App-PathKey (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))) {
            $prefix=$parts.data+'\versions\'
            if ($parts.launcher.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and
                $parts.launcher.Substring($prefix.Length) -match '\A\d+\.\d+\.\d+\\launch-game\.ps1\z') {
                $baseline['cmd']=[string](Field $app 'cmd')
                $oldDirectory=Split-Path -Parent $parts.launcher
                if ((App-PathKey ([string](Field $app 'working-dir'))) -eq (App-PathKey $oldDirectory)) { $baseline['working-dir']=Field $app 'working-dir' }
            }
        }
        $State.managed[$game.uuid]=@{key=$game.key;fields=$baseline;recovered=$true}
        Repair-Event 'state' 'reconstructed' $game.title
        $changed=$true
    }
    if ($changed -or $script:StateNeedsRepair) { Save-State $State;$script:StateNeedsRepair=$false }
}

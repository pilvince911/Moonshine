#Requires -Version 5.1
$script:AtomicWriteEvents=New-Object 'Collections.Generic.List[object]'
$script:AtomicRetained=@{}
function Atomic-ExceptionInfo($ErrorObject) {
    $ex=$ErrorObject
    if ($ErrorObject -is [Management.Automation.ErrorRecord]) { $ex=$ErrorObject.Exception }
    for ($depth=0;$ex.InnerException -and $depth -lt 16;$depth++) { $ex=$ex.InnerException }
    $code=([int]$ex.HResult -band 65535)
    if ($ex -is [ComponentModel.Win32Exception]) { $code=$ex.NativeErrorCode }
    return @{win32=$code;hresult=('0x{0:X8}' -f [int]$ex.HResult);type=$ex.GetType().FullName;exception=$ex}
}
function Atomic-FailureSummary($ErrorObject) {
    $ex=$ErrorObject
    if ($ErrorObject -is [Management.Automation.ErrorRecord]) { $ex=$ErrorObject.Exception }
    for ($depth=0;$ex -and $depth -lt 16;$depth++) {
        if ($ex.Data.Contains('opi5_atomic_failure')) { return ,$ex.Data['opi5_atomic_failure'] }
        $ex=$ex.InnerException
    }
    return $null
}
function Invoke-AtomicFileOperation([string]$Source,[string]$Destination,[bool]$Replace,[string]$Backup) {
    if ($Replace) { [IO.File]::Replace($Source,$Destination,$Backup) }
    else { [IO.File]::Move($Source,$Destination) }
}
function Commit-AtomicFile([string]$Source,[string]$Destination) {
    $sourceParent=[IO.Path]::GetFullPath((Split-Path -Parent $Source)).TrimEnd('\','/')
    $targetParent=[IO.Path]::GetFullPath((Split-Path -Parent $Destination)).TrimEnd('\','/')
    if (-not $sourceParent.Equals($targetParent,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFullPath($Source).Equals([IO.Path]::GetFullPath($Destination),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Le candidat atomique doit etre distinct et dans le meme dossier que sa destination.'
    }
    $existed=[IO.File]::Exists($Destination)
    $backup=$Source+'.previous'
    $codes=@()
    $delays=@(50,100,200,350,500,750,1000)
    for ($attempt=1;$attempt -le ($delays.Count+1);$attempt++) {
        try {
            Invoke-AtomicFileOperation $Source $Destination $existed $backup
            if ($attempt -gt 1) {
                [void]$script:AtomicWriteEvents.Add(@{time=(Get-Date).ToString('o');area='file';action='retry_recovered';detail=([IO.Path]::GetFileName($Destination)+' : '+$attempt+' essais');attempts=$attempt;win32=$codes[0];retry_codes=@($codes)})
            }
            Remove-AtomicTemporary $backup
            return
        } catch {
            $last=Atomic-ExceptionInfo $_
            if ($last.win32 -notin $codes) { $codes+=$last.win32 }
            # These failures leave the original names in place. Never turn a
            # partial rename (1176/1177), access denial or malformed path into
            # a delete/copy fallback. No retry can bypass an existing lock.
            $retry=$last.win32 -in @(32,33,1175,1224)
            $sourceExists=[IO.File]::Exists($Source)
            $targetExists=[IO.File]::Exists($Destination)
            $namesIntact=$sourceExists -and ($targetExists -eq $existed)
            if ($retry -and $namesIntact -and $attempt -le $delays.Count) {
                Start-Sleep -Milliseconds $delays[$attempt-1]
                continue
            }
            $retain=$sourceExists -and ($last.win32 -in @(1176,1177) -or ($existed -and -not $targetExists))
            if ($retain) { $script:AtomicRetained[$Source]=$true }
            $backupExists=[IO.File]::Exists($backup)
            if ($backupExists) { $script:AtomicRetained[$backup]=$true }
            $info=@{stage='commit';file=[IO.Path]::GetFileName($Destination);attempts=$attempt;win32=$last.win32;retry_codes=@($codes);hresult=$last.hresult;exception_type=$last.type;destination_exists=$targetExists;candidate_retained=$retain;previous_retained=$backupExists}
            if ($retain) { $info['candidate']=[IO.Path]::GetFileName($Source) }
            if ($backupExists) { $info['previous']=[IO.Path]::GetFileName($backup) }
            $message='Ecriture atomique impossible pour '+$info.file+' apres '+$attempt+' essai(s) : Windows '+$last.win32+', HRESULT '+$last.hresult+'.'
            if ($retain) { $message+=' Candidat conserve : '+$info.candidate+'.' }
            if ($backupExists) { $message+=' Ancienne version conservee : '+$info.previous+'.' }
            $failure=New-Object IO.IOException($message,$last.exception)
            $failure.Data['opi5_atomic_failure']=$info
            throw $failure
        }
    }
}
function Remove-AtomicTemporary([string]$Path,$FailureInfo=$null) {
    if ($script:AtomicRetained.ContainsKey($Path) -or -not [IO.File]::Exists($Path)) { return }
    $delays=@(50,100,200,350)
    for ($attempt=1;$attempt -le ($delays.Count+1);$attempt++) {
        try { [IO.File]::Delete($Path);return }
        catch {
            $info=Atomic-ExceptionInfo $_
            if ($info.win32 -in @(32,33,1175,1224) -and $attempt -le $delays.Count) { Start-Sleep -Milliseconds $delays[$attempt-1];continue }
            $script:AtomicRetained[$Path]=$true
            if ($null -ne $FailureInfo) {
                $FailureInfo['candidate_retained']=$true
                $FailureInfo['candidate']=[IO.Path]::GetFileName($Path)
                $FailureInfo['cleanup_win32']=$info.win32
            }
            [void]$script:AtomicWriteEvents.Add(@{time=(Get-Date).ToString('o');area='file';action='temporary_retained';detail=[IO.Path]::GetFileName($Path);win32=$info.win32})
            return
        }
    }
}
function Write-AtomicBytes([string]$Destination,[byte[]]$Bytes) {
    if ($null -eq $Bytes) { throw 'Donnees absentes pour l ecriture atomique.' }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
    $temporary=$Destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $failureInfo=$null
    try {
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true) }
        finally { $stream.Dispose() }
        Commit-AtomicFile $temporary $Destination
    } catch {
        if (-not (Atomic-FailureSummary $_)) {
            $info=Atomic-ExceptionInfo $_
            $_.Exception.Data['opi5_atomic_failure']=@{stage='write_candidate';file=[IO.Path]::GetFileName($Destination);attempts=1;win32=$info.win32;hresult=$info.hresult;exception_type=$info.type;destination_exists=[IO.File]::Exists($Destination);candidate_retained=$false}
        }
        $failureInfo=Atomic-FailureSummary $_
        throw
    } finally { Remove-AtomicTemporary $temporary $failureInfo }
}

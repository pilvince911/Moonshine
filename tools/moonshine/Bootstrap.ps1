#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Desktop','Menu','Preview','SyncPilot','SyncAll','SyncEAPilot','SyncEA','Export','SelfTest')][string]$Action='Desktop',
    [switch]$Unattended,
    [switch]$FunctionsOnly
)
$script:BootstrapVersion='0.8.0'
$script:BootstrapFiles=@('Moonshine-Worker.ps1','Recovery.ps1','RecoveryTests.ps1','Desktop.ps1','Desktop.xaml','DesktopView.cs','GuiBridge.cs','GuiEngine.ps1','GuiDiagnostics.ps1','GuiTests.ps1','Mode-console.cmd','Brand.ps1','BrandTests.ps1','Profiles.ps1','ProfileTests.ps1','Atomic.ps1','Bootstrap.ps1','Repair.ps1','RepairTests.ps1','Reset.ps1','ResetTests.ps1','Core.ps1','EA.ps1','Inventory.ps1','Api.ps1','Artwork.ps1','Artwork.cs','Sync.ps1','SelfTests.ps1','TransportTests.cs','Transport-Test.pfx','Native.cs','Launch-Game.ps1','VibeShine-Xbox.ps1','Demarrer.cmd','Exporter-retour.cmd','LIRE-MOI.txt','VALIDATION.txt','SOURCES.txt')
function Package-Hashes([string]$Folder,$Expected=$script:BootstrapFiles) {
    $manifest=Join-Path $Folder 'SHA256.txt'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or (Get-Item -LiteralPath $manifest).Length -gt 65536) { throw 'Liste des empreintes absente ou invalide.' }
    $hashes=@{}
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if (-not $line) { continue }
        $m=[regex]::Match($line,'\A([A-Fa-f0-9]{64})  ([A-Za-z0-9][A-Za-z0-9.-]*)\z')
        if (-not $m.Success -or $m.Groups[2].Value -notin $Expected -or $hashes.ContainsKey($m.Groups[2].Value)) { throw 'Liste des empreintes non conforme.' }
        $hashes[$m.Groups[2].Value]=$m.Groups[1].Value.ToLowerInvariant()
    }
    if ($hashes.Count -ne @($Expected).Count) { throw 'Liste des empreintes incomplete.' }
    return ,$hashes
}
function Package-Valid([string]$Folder,$Expected=$script:BootstrapFiles) {
    try {
        $hashes=Package-Hashes $Folder $Expected
        foreach ($name in @($hashes.Keys)) {
            $path=Join-Path $Folder $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $hashes[$name]) { return $false }
        }
        return $true
    } catch { return $false }
}
function Repair-PackageTree([string]$Source,[string]$Destination,$Hashes,[string]$Recovery) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $all=@{};foreach ($name in @($Hashes.Keys)) { $all[$name]=$Hashes[$name] }
    $all['SHA256.txt']=(Get-FileHash -LiteralPath (Join-Path $Source 'SHA256.txt') -Algorithm SHA256).Hash
    # Manifest last: an interrupted copy cannot certify an unfinished package.
    foreach ($name in @(@($Hashes.Keys | Sort-Object)+@('SHA256.txt'))) {
        $target=Join-Path $Destination $name
        $exists=Test-Path -LiteralPath $target -PathType Leaf
        if ($exists -and (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash -ieq $all[$name]) { continue }
        if ($exists) {
            [IO.Directory]::CreateDirectory($Recovery) | Out-Null
            $copy=Join-Path $Recovery ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'-'+$name)
            Copy-Item -LiteralPath $target -Destination $copy -ErrorAction Stop
        }
        [byte[]]$bytes=[IO.File]::ReadAllBytes((Join-Path $Source $name))
        $sha=[Security.Cryptography.SHA256]::Create()
        try {
            $hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')
        } finally { $sha.Dispose() }
        if ($hash -ine $all[$name]) { throw 'La copie de reference a change pendant la reparation.' }
        Write-AtomicBytes $target $bytes
        @{file=$name;action=$(if ($exists) {'repaired'} else {'installed'})}
    }
}
if ($FunctionsOnly) { return }
$ErrorActionPreference='Stop'
$bootstrapLock=$null
try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Windows PowerShell 5.1 64 bits requis.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if ($identity.IsSystem -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Lancer normalement, sans administrateur.' }
    $data=Join-Path $env:LOCALAPPDATA 'OPi5\VibeShine-Xbox'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $bootstrapLock=[IO.File]::Open((Join-Path $data 'bootstrap.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $runtime=Join-Path (Join-Path $data 'versions') $script:BootstrapVersion
    $mirror=Join-Path (Join-Path $data 'Packages') $script:BootstrapVersion
    $source=''
    foreach ($candidate in @($PSScriptRoot,$mirror,$runtime)) {
        if (Package-Valid $candidate) { $source=$candidate;break }
    }
    if (-not $source) { throw 'Aucune copie complete et verifiable du programme. Reextraire le ZIP 0.8.0; donnees et jeux conserves.' }
    $hashes=Package-Hashes $source
    # Only load the writer after the complete source package has been verified.
    . (Join-Path $source 'Atomic.ps1')
    . (Join-Path $source 'Brand.ps1')
    Import-LegacyData $data (Legacy-DataRoot)
    $events=@(Repair-PackageTree $source $runtime $hashes (Join-Path $data 'Recovery'))
    if (-not (Package-Valid $runtime)) { throw 'Verification du programme apres reparation impossible.' }
    $mirrorEvents=@(Repair-PackageTree $runtime $mirror $hashes (Join-Path $data 'Recovery'))
    if (-not (Package-Valid $mirror)) { throw 'Verification de la copie de secours impossible.' }
    $health=@{version=$script:BootstrapVersion;time=(Get-Date).ToString('o');verified_files=$hashes.Count;runtime=$events;backup=$mirrorEvents;file_writes=@($script:AtomicWriteEvents.ToArray())}
    $path=Join-Path $data 'bootstrap-health.json'
    Write-AtomicBytes $path ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $health -Depth 8)))
    $repaired=@($events | Where-Object { $_.action -eq 'repaired' })
    if ($repaired.Count -gt 0 -and -not $Unattended) { Write-Host ('Programme repare depuis une copie verifiee : '+(($repaired | ForEach-Object { $_.file }) -join ', ')) -ForegroundColor Yellow }
    $bootstrapLock.Dispose();$bootstrapLock=$null
    if ($Action -eq 'Desktop') { & (Join-Path $runtime 'Desktop.ps1') }
    else { & (Join-Path $runtime 'VibeShine-Xbox.ps1') -Action $Action -Unattended:$Unattended }
} catch {
    if ($Action -eq 'Desktop') {
        try {
            Add-Type -AssemblyName PresentationFramework
            $null=[Windows.MessageBox]::Show(($_.Exception.Message+"`n`nMode-console.cmd permet de consulter le diagnostic."),'OPi5 · Démarrage interrompu','OK','Error')
        } catch { }
    }
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
} finally { if ($bootstrapLock) { $bootstrapLock.Dispose() } }

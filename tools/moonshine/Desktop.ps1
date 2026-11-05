#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Trial.ps1')
if (Get-MoonshineTrialId) { throw 'Utiliser la bibliotheque Web de Moonshine pour cet essai isole.' }
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or
    [Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) { throw 'Lancer Demarrer.cmd dans une session Windows normale.' }
. (Join-Path $PSScriptRoot 'GuiTests.ps1')
Init-DesktopTypes
$created=$false
$mutex=[Threading.Mutex]::new($true,('Local\OPi5Desktop-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value),[ref]$created)
if (-not $created) {
    try {
        if (-not [OPi5DesktopController]::ActivateExisting()) { $null=[Windows.MessageBox]::Show('La fenêtre OPi5 est déjà ouverte ou en cours de démarrage.','OPi5','OK','Information') }
    } finally { $mutex.Dispose() }
    return
}
$window=$null;$controller=$null
try {
    $stream=[IO.File]::OpenRead((Join-Path $PSScriptRoot 'Desktop.xaml'))
    try { $window=[Windows.Markup.XamlReader]::Load($stream) } finally { $stream.Dispose() }
    $bridge=New-Object OPi5GuiBridge
    $controller=New-Object OPi5DesktopController($window,$bridge,$PSScriptRoot)
    $window.Add_Loaded({ $controller.Start() })
    $null=$window.ShowDialog()
} finally { if ($controller) { $controller.Dispose() };$mutex.ReleaseMutex();$mutex.Dispose() }

#Requires -Version 5.1
param([switch]$ValidateWindowOnly)
$ErrorActionPreference='Stop';Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$timer=$null;$operation=$null;$mutex=$null;$ownsMutex=$false
try {
    [xml]$layout=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher.xaml'))
    $reader=New-Object Xml.XmlNodeReader($layout);$window=[Windows.Markup.XamlReader]::Load($reader)
    $controls=@{};foreach ($name in @('InstallButton','DriversButton','StartButton','StopButton','OpenButton','RemoveButton','HelpButton','MigrateChoice','AutomaticChoice','StatusText','DetailText')) { $controls[$name]=$window.FindName($name);if (-not $controls[$name]) { throw ('Controle absent : '+$name) } }
    if ($ValidateWindowOnly) { $window.Close();return }
    $ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex=New-Object Threading.Mutex($false,('Local\Moonshine.Setup.Window.'+$ownerSid));$ownsMutex=$mutex.WaitOne(0)
    if (-not $ownsMutex) { throw 'La fenetre Moonshine est deja ouverte.' }
    $preview=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine-Preview\service-receipt.json'
    $controls.MigrateChoice.IsChecked=[IO.File]::Exists($preview)
    function Invoke-MoonshineSetupAction([string]$Action) {
        if ($script:operation -and -not $script:operation.HasExited) { return }
        $message=switch ($Action) {
            'Install' { 'Installer ou mettre a jour Moonshine? Les autres hotes doivent etre arretes. Le catalogue existant est sauvegarde avant la copie. Les pilotes se preparent avec leur bouton separe.' }
            'Drivers' { 'Preparer les pilotes ecran et manettes du paquet officiel verifie? Les scripts peuvent ajouter le certificat editeur SignPath Foundation a TrustedPublisher. Les versions plus recentes sont conservees. Terminer les streams et arreter les hotes avant de continuer.' }
            'Remove' { 'Retirer MoonshineService et sa regle reseau? Arreter le service avant de continuer. Le programme, les donnees et les pilotes partages sont conserves pour une reinstallation ou une recuperation.' }
            'Stop' { 'Arreter Moonshine? Terminer les streams et les operations de bibliotheque avant de continuer.' }
            default { 'Demarrer le service Moonshine? VibeShine doit etre arrete.' }
        }
        if ([Windows.MessageBox]::Show($message,'Moonshine',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -ne [Windows.MessageBoxResult]::Yes) { return }
        $arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'Action.ps1')+'" -Action '+$Action+' -OwnerSid '+$ownerSid
        if ($Action -eq 'Install') { if ($controls.MigrateChoice.IsChecked) {$arguments+=' -Migrate'};if ($controls.AutomaticChoice.IsChecked) {$arguments+=' -Automatic'} }
        $controls.DetailText.Text='Confirmation Windows et operation en cours…'
        $script:operation=Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -PassThru
    }
    $controls.InstallButton.Add_Click({ try { Invoke-MoonshineSetupAction 'Install' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.DriversButton.Add_Click({ try { Invoke-MoonshineSetupAction 'Drivers' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.StartButton.Add_Click({ try { Invoke-MoonshineSetupAction 'Start' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.StopButton.Add_Click({ try { Invoke-MoonshineSetupAction 'Stop' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.RemoveButton.Add_Click({ try { Invoke-MoonshineSetupAction 'Remove' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.OpenButton.Add_Click({ Start-Process 'https://localhost:48990/v2/library' })
    $controls.HelpButton.Add_Click({ Start-Process (Join-Path $PSScriptRoot 'LIRE-MOI.txt') })
    $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        try {
            $service=Get-Service -Name 'MoonshineService' -ErrorAction SilentlyContinue
            $busy=$script:operation -and -not $script:operation.HasExited;$running=$service -and $service.Status -eq 'Running'
            $installed=[IO.File]::Exists((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine\service-receipt.json'))
            $controls.StatusText.Text=if ($running) {'Moonshine est demarre'} elseif ($installed) {'Moonshine est installe et arrete'} elseif ($service) {'Ancien service Moonshine detecte'} else {'Moonshine est pret a installer'}
            $controls.InstallButton.IsEnabled=(-not $busy -and -not $running)
            $controls.DriversButton.IsEnabled=(-not $busy -and $installed -and -not $running)
            $controls.StartButton.IsEnabled=(-not $busy -and $installed -and $service -and -not $running)
            $controls.StopButton.IsEnabled=(-not $busy -and $running)
            $controls.RemoveButton.IsEnabled=(-not $busy -and $installed -and $service -and -not $running)
            $controls.OpenButton.IsEnabled=($installed -and $running)
            $controls.MigrateChoice.IsEnabled=(-not $installed -and -not $busy -and [IO.File]::Exists($preview))
            if ($script:operation -and $script:operation.HasExited) {
                $controls.DetailText.Text=if ($script:operation.ExitCode -eq 0) {'Operation terminee. Utiliser Demarrer, puis Ouvrir la bibliotheque.'} else {'Operation suspendue. Consulter le message de la fenetre administrateur.'}
                $script:operation.Dispose();$script:operation=$null
            }
        } catch { $controls.DetailText.Text=$_.Exception.Message }
    })
    $timer.Start();$null=$window.ShowDialog()
} catch { if ($ValidateWindowOnly) {throw};$null=[Windows.MessageBox]::Show($_.Exception.Message,'Moonshine') }
finally { if ($timer) {$timer.Stop()};if ($operation) {$operation.Dispose()};if ($ownsMutex) {$mutex.ReleaseMutex()};if ($mutex) {$mutex.Dispose()} }

#Requires -Version 5.1
param([switch]$ValidateWindowOnly)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$timer=$null;$operation=$null;$mutex=$null;$ownsMutex=$false
try {
    [xml]$layout=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher.xaml'))
    $reader=New-Object Xml.XmlNodeReader($layout);$window=[Windows.Markup.XamlReader]::Load($reader)
    $controls=@{};foreach ($name in @('InstallButton','OpenButton','StartButton','StopButton','ReturnButton','ServicesButton','TrialChoice','StatusText','DetailText')) { $controls[$name]=$window.FindName($name);if (-not $controls[$name]) { throw ('Contrôle absent : '+$name) } }
    if ($ValidateWindowOnly) { $window.Close();return }
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex=New-Object Threading.Mutex($false,('Local\Moonshine.Service.Window.'+$owner));$ownsMutex=$mutex.WaitOne(0)
    if (-not $ownsMutex) { throw 'La fenêtre Moonshine Service est déjà ouverte.' }
    . (Join-Path $PSScriptRoot 'Service-Setup.ps1')
    $base=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OPi5\Moonshine-Trial'
    $indexPath=Join-Path $base 'instances.json';$choices=@()
    if (Test-Path -LiteralPath $indexPath) {
        if ((Get-Item -LiteralPath $indexPath).Length -gt 1048576) { throw 'Index des essais trop volumineux.' }
        $index=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($indexPath))
        if ($index.schema -cne 'moonshine-trial-instances/1') { throw 'Index des essais invalide.' }
        foreach ($item in $index.instances.PSObject.Properties) {
            if ($item.Name -cnotmatch '\A[a-f0-9]{40}\z' -or $item.Value -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Identité de l''essai invalide.' }
            $path=Join-Path $base ($item.Value+'\Package\config\moonshine.conf')
            if (Test-Path -LiteralPath $path) { $choices+=@([pscustomobject]@{Id=[string]$item.Value;Label=('Moonshine · '+$item.Name.Substring(0,8)+' · réglages du '+(Get-Item -LiteralPath $path).LastWriteTime.ToString('yyyy-MM-dd HH:mm'));Modified=(Get-Item -LiteralPath $path).LastWriteTime}) }
        }
    }
    $controls.TrialChoice.ItemsSource=@($choices | Sort-Object Modified -Descending)
    if ($choices.Count) { $controls.TrialChoice.SelectedIndex=0 }
    function Invoke-ServiceAction([string]$Action) {
        if ($script:operation -and -not $script:operation.HasExited) { return }
        $selected=$controls.TrialChoice.SelectedItem
        if ($Action -eq 'Install' -and -not $selected) { throw 'Aucun essai Moonshine à reprendre. Conserver le profil du kit 0.8.1 sur ce compte Windows.' }
        $message=switch ($Action) {
            'Install' { 'Installer MoonshineService en démarrage manuel, copier le catalogue et l''appairage de cet essai, puis démarrer le service? Terminer le stream et arrêter les autres hôtes avant de continuer. Le pilote existant est conservé.' }
            'Return' { 'Arrêter et retirer MoonshineService, puis redémarrer l''ancien service VibeShine reconnu? Les fichiers, sauvegardes et jeux installés sont conservés.' }
            'Stop' { 'Arrêter MoonshineService? Terminer le stream et les opérations de bibliothèque avant de continuer.' }
            default { 'Démarrer MoonshineService? Les autres hôtes doivent être arrêtés.' }
        }
        if ([Windows.MessageBox]::Show($message,'Moonshine Service',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -ne [Windows.MessageBoxResult]::Yes) { return }
        $command='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'Service-Action.ps1')+'" -Action '+$Action+' -OwnerSid '+$owner
        if ($Action -eq 'Install') { $command+=' -TrialId '+$selected.Id }
        $controls.DetailText.Text='Confirmation Windows et opération en cours…'
        $script:operation=Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $command -Verb RunAs -PassThru
    }
    $controls.InstallButton.Add_Click({ try { Invoke-ServiceAction 'Install' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.StartButton.Add_Click({ try { Invoke-ServiceAction 'Start' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.StopButton.Add_Click({ try { Invoke-ServiceAction 'Stop' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.ReturnButton.Add_Click({ try { Invoke-ServiceAction 'Return' } catch { $controls.DetailText.Text=$_.Exception.Message } })
    $controls.OpenButton.Add_Click({ Start-Process 'https://localhost:48990/v2/library' })
    $controls.ServicesButton.Add_Click({ Start-Process services.msc })
    $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        try {
            $service=Get-Service -Name 'MoonshineService' -ErrorAction SilentlyContinue
            $busy=$script:operation -and -not $script:operation.HasExited
            $running=$service -and $service.Status -eq 'Running'
            $controls.StatusText.Text=if ($running) {'Service Moonshine démarré'} elseif ($service) {'Service Moonshine arrêté'} else {'Service Moonshine non installé'}
            $controls.InstallButton.IsEnabled=(-not $busy -and -not $running -and $choices.Count -gt 0)
            $controls.InstallButton.Content=if ($service) {'Réparer et démarrer'} else {'Installer et démarrer'}
            $controls.StartButton.IsEnabled=(-not $busy -and $service -and -not $running)
            $controls.StopButton.IsEnabled=(-not $busy -and $running)
            $controls.ReturnButton.IsEnabled=(-not $busy -and $null -ne $service)
            $controls.OpenButton.IsEnabled=($running -and @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 48990 }).Count -gt 0)
            if ($script:operation -and $script:operation.HasExited) {
                $controls.DetailText.Text=if ($script:operation.ExitCode -eq 0) {'Opération terminée. Le catalogue et les paramètres sont accessibles dans la bibliothèque.'} else {'Action suspendue. Consulter le message de la fenêtre administrateur.'}
                $script:operation.Dispose();$script:operation=$null
            }
        } catch { $controls.DetailText.Text=$_.Exception.Message }
    })
    $timer.Start();$null=$window.ShowDialog()
} catch { if ($ValidateWindowOnly) { throw };$null=[Windows.MessageBox]::Show($_.Exception.Message,'Moonshine Service') }
finally { if ($timer) {$timer.Stop()};if ($operation) {$operation.Dispose()};if ($ownsMutex) {$mutex.ReleaseMutex()};if ($mutex) {$mutex.Dispose()} }

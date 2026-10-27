#Requires -Version 5.1
param([switch]$ValidateWindowOnly)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$mutex=$null;$ownsMutex=$false
try {
    if (-not $ValidateWindowOnly) {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
        if ($identity.IsSystem -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Ouvrir cet essai avec un double-clic normal, sans Exécuter en tant qu''administrateur.' }
        $mutex=New-Object Threading.Mutex($false,('Local\Moonshine.Trial.Launcher.'+$identity.User.Value))
        $ownsMutex=$mutex.WaitOne(0)
        if (-not $ownsMutex) { throw 'La fenêtre Moonshine est déjà ouverte dans cette session.' }
    }
    [xml]$layout=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher.xaml'))
    $reader=New-Object Xml.XmlNodeReader($layout);$script:window=[Windows.Markup.XamlReader]::Load($reader)
    $names=@('StartButton','OpenButton','StopButton','BackupButton','FilesButton','ServicesButton','StatusText','DetailText','FolderText')
    $script:controls=@{}
    foreach ($name in $names) { $control=$window.FindName($name);if (-not $control) { throw ('Contrôle manquant : '+$name) };$controls[$name]=$control }
    if ($ValidateWindowOnly) { $window.Close();Write-Output 'Moonshine WPF window parsed and constructed.';return }
    . (Join-Path $PSScriptRoot 'Trial-Setup.ps1')
    . (Join-Path $PSScriptRoot 'Sauvegarde-Moonshine.ps1')
    $script:instance=$null;$script:closing=$false;$script:timer=New-Object Windows.Threading.DispatcherTimer
    $controls.FolderText.Text=$script:MoonshineTrialBase
    function Show-TrialError($ErrorRecord) { $controls.StatusText.Text='Action suspendue';$controls.DetailText.Text=[string]$ErrorRecord.Exception.Message }
    function Ensure-TrialInstance {
        if (-not $script:instance) { $script:instance=Get-MoonshineTrialInstance $PSScriptRoot;$controls.FolderText.Text=$instance.Root }
    }
    $controls.StartButton.Add_Click({
        try {
            $controls.StatusText.Text='Vérification et préparation…';$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
            Ensure-TrialInstance;$null=Start-MoonshineTrialInstance $instance
            $controls.StatusText.Text='Démarrage de Moonshine…';$controls.DetailText.Text='La bibliothèque ouvrira sur ce PC à https://localhost:48990/v2/library.'
        } catch { Show-TrialError $_ }
    })
    $controls.OpenButton.Add_Click({ try { Start-Process 'https://localhost:48990/v2/library' } catch { Show-TrialError $_ } })
    $controls.StopButton.Add_Click({
        try { if ($instance -and (Request-MoonshineTrialStop $instance)) { $controls.StatusText.Text='Arrêt demandé…';$controls.DetailText.Text='Moonshine termine ses opérations et ferme le stream proprement.' } }
        catch { Show-TrialError $_ }
    })
    $controls.FilesButton.Add_Click({ try { Ensure-TrialInstance;[IO.Directory]::CreateDirectory($instance.Root) | Out-Null;Start-Process explorer.exe -ArgumentList ('"'+$instance.Root+'"') } catch { Show-TrialError $_ } })
    $controls.ServicesButton.Add_Click({ try { Start-Process services.msc } catch { Show-TrialError $_ } })
    $controls.BackupButton.Add_Click({
        $dialog=New-Object Windows.Forms.FolderBrowserDialog
        try {
            $dialog.Description='Choisir le dossier config de VibeShine (apps.json ou fichier .conf)'
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                $controls.StatusText.Text='Sauvegarde et vérification…';$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
                $backup=Backup-MoonshineSource $dialog.SelectedPath
                $controls.StatusText.Text='Sauvegarde privée vérifiée';$controls.DetailText.Text=$backup
                Start-Process explorer.exe -ArgumentList ('"'+$backup+'"')
            }
        } catch { Show-TrialError $_ } finally { $dialog.Dispose() }
    })
    $timer.Interval=[TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        try {
            $running=$false
            if ($instance) { $process=Get-MoonshineOwnedTrialProcess $instance;$running=($null -ne $process -and -not $process.HasExited) }
            $controls.StartButton.IsEnabled=(-not $running -and -not $closing);$controls.OpenButton.IsEnabled=$running;$controls.StopButton.IsEnabled=$running
            if ($running -and $controls.StatusText.Text -eq 'Démarrage de Moonshine…') { $controls.StatusText.Text='Moonshine est en cours d''exécution';$controls.DetailText.Text='Ouvrez la bibliothèque pour créer les identifiants de cet essai, puis analyser vos jeux.' }
            if ($closing -and -not $running) { $timer.Stop();$window.Close() }
        } catch { Show-TrialError $_ }
    })
    $window.Add_Closing({
        param($sender,$event)
        try {
            if ($instance) {
                $process=Get-MoonshineOwnedTrialProcess $instance
                if ($process -and -not $process.HasExited) {
                    $event.Cancel=$true;$script:closing=$true;$null=Request-MoonshineTrialStop $instance
                    $controls.StatusText.Text='Fermeture de l''essai…';$controls.DetailText.Text='En attente de l''arrêt propre de l''hôte.'
                }
            }
        } catch { $event.Cancel=$true;$script:closing=$false;Show-TrialError $_ }
    })
    $timer.Start();$null=$window.ShowDialog();$timer.Stop()
} catch {
    if ($ValidateWindowOnly) { throw }
    $null=[Windows.MessageBox]::Show($_.Exception.Message,'Moonshine',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information)
} finally { if ($ownsMutex) { $mutex.ReleaseMutex() };if ($mutex) { $mutex.Dispose() } }

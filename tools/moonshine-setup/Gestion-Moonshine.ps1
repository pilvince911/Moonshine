#Requires -Version 5.1
param([switch]$ValidateWindowOnly,[switch]$TrayOnly,[switch]$Uninstall,[string]$PreviewPath,[string]$CITrace)
$ErrorActionPreference='Stop'
function Write-MoonshineCIPhase([string]$Value){if($CITrace -and $env:GITHUB_ACTIONS -eq 'true' -and $env:CI -eq 'true'){[IO.File]::AppendAllText($CITrace+'.phase',((Get-Date).ToString('o')+' '+$Value+"`r`n"))}}
Write-MoonshineCIPhase 'script-entered'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
Write-MoonshineCIPhase 'desktop-assemblies-loaded'
$script:operation=$null;$script:timer=$null;$script:notify=$null;$script:quit=$false;$script:launchInstalled=$false
$mutex=$null;$ownsMutex=$false;$signals=@{};$script:trayItems=@{};$script:model=$null;$script:evidence=$null
try {
    . (Join-Path $PSScriptRoot 'Installation.ps1')
    . (Join-Path $PSScriptRoot 'Pilotes.ps1')
    . (Join-Path $PSScriptRoot 'Manager-State.ps1')
    [xml]$layout=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher.xaml'))
    $reader=New-Object Xml.XmlNodeReader($layout);$script:window=[Windows.Markup.XamlReader]::Load($reader)
    Write-MoonshineCIPhase 'window-constructed'
    $script:controls=@{}
    foreach ($name in @('MainTabs','BrandImage','StatusText','DetailText','InstallStep','DriverStep','RunStep','PrimaryButton','StopButton','OperationProgress','OperationText','InstallChoices','MigrateChoice','AutomaticChoice','RepairButton','DriversButton','BackupButton','DiagnosticButton','HelpButton','RemoveButton','TrayButton')) {
        $controls[$name]=$window.FindName($name);if (-not $controls[$name]) {throw ('Controle absent : '+$name)}
    }
    $iconBytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Moonshine.ico'))
    $stream=New-Object IO.MemoryStream(,$iconBytes)
    try { $decoder=[Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad);$bitmap=@($decoder.Frames | Sort-Object PixelWidth -Descending)[0];$bitmap.Freeze();$controls.BrandImage.Source=$bitmap;$window.Icon=$bitmap } finally {$stream.Dispose()}
    if ($ValidateWindowOnly) {
        $previewModel=Get-MoonshineManagerModel @{installed=$false;running=$false;drivers=$false;reboot=$false;service_present=$false;update=$false;blocked=$false;busy=$false}
        $controls.StatusText.Text=$previewModel.title;$controls.DetailText.Text=$previewModel.detail;$controls.PrimaryButton.Content=$previewModel.primary;$controls.PrimaryButton.IsEnabled=$true;$controls.StopButton.IsEnabled=$false;$controls.TrayButton.IsEnabled=$false
        $window.Show();$window.UpdateLayout()
        if ($PreviewPath) {
            $width=[int]$window.ActualWidth;$height=[int]$window.ActualHeight
            $render=New-Object Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$render.Render($window)
            $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
            $parent=Split-Path -Parent ([IO.Path]::GetFullPath($PreviewPath));[IO.Directory]::CreateDirectory($parent)|Out-Null
            $file=[IO.File]::Create([IO.Path]::GetFullPath($PreviewPath));try {$encoder.Save($file)} finally {$file.Dispose()}
        }
        $window.Close();Write-Output 'Moonshine RC2 WPF constructed; icon loaded without keeping a file handle.';return
    }
    [Environment]::CurrentDirectory=$env:WINDIR;Set-Location -LiteralPath $env:WINDIR
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.IsSystem -or (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Ouvrir Moonshine normalement. Ses operations systeme demandent elles-memes la confirmation Windows.' }
    $script:ownerSid=$identity.User.Value
    Write-MoonshineCIPhase 'normal-account-verified'
    $installedKit=Join-Path $script:MoonshineServiceRoot 'Kit'
    $script:fromInstalled=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ieq [IO.Path]::GetFullPath($installedKit).TrimEnd('\')
    foreach ($purpose in @('Show','Uninstall','Release')) {$signals[$purpose]=New-MoonshineManagerSignal $ownerSid $purpose}
    $mutex=New-Object Threading.Mutex($false,('Local\Moonshine.Setup.Window.'+$ownerSid))
    try{$ownsMutex=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ownsMutex=$true}
    if (-not $ownsMutex) {
        if (-not $fromInstalled -and -not $TrayOnly -and -not $Uninstall) {
            $null=$signals.Release.Set()
            for ($n=0;$n -lt 25 -and -not $ownsMutex;$n++) {try{$ownsMutex=$mutex.WaitOne(200)}catch [Threading.AbandonedMutexException]{$ownsMutex=$true}}
        }
        if (-not $ownsMutex) {
            $null=$signals[$(if($Uninstall){'Uninstall'}else{'Show'})].Set()
            if (-not $fromInstalled -and -not $TrayOnly) { $null=[Windows.MessageBox]::Show('Fermer la fenetre Moonshine precedente, puis ouvrir de nouveau ce nouveau ZIP. Le service peut rester installe.','Moonshine') }
            return
        }
    }
    foreach($signal in $signals.Values){$null=$signal.Reset()}
    Write-MoonshineCIPhase 'instance-acquired'
    $build=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'build-info.json')))
    $script:sourceCommit=[string]$build.commit
    if ($sourceCommit -cnotmatch '\A[a-f0-9]{40}\z') {throw 'Identite du paquet absente. Extraire le ZIP complet.'}
    $preview=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonshine-Preview\service-receipt.json'
    $controls.MigrateChoice.IsChecked=[IO.File]::Exists($preview)
    $script:application=New-Object Windows.Application;$application.ShutdownMode=[Windows.ShutdownMode]::OnExplicitShutdown
    Write-MoonshineCIPhase 'application-created'
    function Show-MoonshineWindow([switch]$Maintenance) {
        if ($Maintenance) {$controls.MainTabs.SelectedIndex=1}
        $window.Show();$window.WindowState=[Windows.WindowState]::Normal;$null=$window.Activate()
    }
    function Stop-MoonshineManager {
        if ($script:operation -and -not $operation.process.HasExited) { $null=[Windows.MessageBox]::Show('Attendre la fin de l operation systeme avant de quitter l icone.','Moonshine');return }
        $script:quit=$true;$application.Shutdown()
    }
    function Enter-MoonshineTray {
        if (-not $evidence.installed) {return}
        if ($script:operation -and -not $operation.process.HasExited) {$null=[Windows.MessageBox]::Show('Attendre la fin de l operation avant de changer de gestionnaire.','Moonshine');return}
        if (-not $fromInstalled) {$script:launchInstalled=$true;Stop-MoonshineManager} else {$window.Hide()}
    }
    function Add-MoonshineTrayItem([string]$Key,[string]$Text,[scriptblock]$Handler) {
        $item=New-Object Windows.Forms.ToolStripMenuItem($Text);$item.Add_Click($Handler);$null=$script:trayMenu.Items.Add($item);$trayItems[$Key]=$item
    }
    function Ensure-MoonshineTray {
        if ($script:notify -or -not $evidence.installed) {return}
        $script:trayMenu=New-Object Windows.Forms.ContextMenuStrip
        Add-MoonshineTrayItem 'Status' 'Moonshine' {}; $trayItems.Status.Enabled=$false
        $null=$trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        Add-MoonshineTrayItem 'Open' 'Ouvrir la bibliotheque' {Start-Process 'https://localhost:48990/v2/library'}
        Add-MoonshineTrayItem 'Start' 'Demarrer le service' {Invoke-MoonshineSetupAction 'Start'}
        Add-MoonshineTrayItem 'Stop' 'Arreter le service' {Invoke-MoonshineSetupAction 'Stop'}
        $null=$trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        Add-MoonshineTrayItem 'Manage' 'Gerer Moonshine' {Show-MoonshineWindow}
        Add-MoonshineTrayItem 'Maintenance' 'Entretien' {Show-MoonshineWindow -Maintenance}
        $null=$trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        Add-MoonshineTrayItem 'Exit' 'Quitter l icone (laisser le service actif)' {Stop-MoonshineManager}
        $iconStream=New-Object IO.MemoryStream(,$iconBytes)
        try { $loaded=New-Object Drawing.Icon($iconStream);$script:trayIcon=$loaded.Clone();$loaded.Dispose() } finally {$iconStream.Dispose()}
        $script:notify=New-Object Windows.Forms.NotifyIcon;$notify.Icon=$trayIcon;$notify.ContextMenuStrip=$trayMenu;$notify.Text='Moonshine';$notify.Visible=$true
        $notify.Add_DoubleClick({if($evidence.running){Start-Process 'https://localhost:48990/v2/library'}else{Show-MoonshineWindow}})
    }
    function Invoke-MoonshineSetupAction([string]$Action) {
        $fromTray=-not $window.IsVisible -and $Action -in @('Start','Stop')
        try {
            if ($script:operation) {return}
            if ($Action -eq 'Open') {Start-Process 'https://localhost:48990/v2/library';Enter-MoonshineTray;return}
            $message=switch($Action){
                'Install' {'Installer / mettre a jour Moonshine? Le catalogue existant est sauvegarde. Les pilotes auront leur propre etape de confirmation.'}
                'Repair' {'Reparer le programme depuis ce paquet verifie? Catalogue et appairage sont conserves. Le service doit etre arrete.'}
                'Drivers' {'Preparer les pilotes signes d ecran et de manettes? L editeur SignPath Foundation peut etre approuve. Le service doit etre arrete.'}
                'Backup' {'Sauvegarder reglages, appairage et bibliotheque en prive? Le service doit etre arrete.'}
                'Diagnostic' {'Exporter un diagnostic local? Les identifiants et certificats ne sont pas inclus. Vous choisirez ou enregistrer le ZIP.'}
                'Uninstall' {'Desinstaller Moonshine? Arretez d abord le service. Une sauvegarde sera verifiee, le programme archive et l inscription Windows retiree. Bibliotheque et pilotes partages seront conserves.'}
                'Stop' {'Arreter Moonshine? Terminez les streams et les operations de bibliotheque avant de continuer.'}
                default {'Demarrer le service Moonshine? Les autres hotes de streaming doivent etre arretes.'}
            }
            if ($Action -ne 'Start' -and [Windows.MessageBox]::Show($message,'Moonshine',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -ne [Windows.MessageBoxResult]::Yes) {return}
            $id=[guid]::NewGuid().ToString('N')
            $arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'Action.ps1')+'" -Action '+$Action+' -OwnerSid '+$ownerSid+' -OperationId '+$id
            if ($Action -eq 'Install') {if($controls.MigrateChoice.IsChecked){$arguments+=' -Migrate'};if($controls.AutomaticChoice.IsChecked){$arguments+=' -Automatic'}}
            $controls.OperationText.Text='Confirmation Windows...';$controls.OperationProgress.Value=0
            $process=Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -PassThru
            $script:operation=@{id=$id;action=$Action;process=$process;from_tray=$fromTray}
            if(-not $fromTray){Show-MoonshineWindow}
            foreach($key in @('PrimaryButton','StopButton','RepairButton','DriversButton','BackupButton','DiagnosticButton','RemoveButton')){$controls[$key].IsEnabled=$false}
            if($notify){$trayItems.Start.Enabled=$false;$trayItems.Stop.Enabled=$false}
            $controls.StatusText.Text='Operation en cours'
        } catch {$controls.OperationText.Text=$_.Exception.Message;if($fromTray -and $notify){$notify.ShowBalloonTip(5000,'Moonshine',$_.Exception.Message,[Windows.Forms.ToolTipIcon]::Info)}else{Show-MoonshineWindow}}
    }
    function Update-MoonshineManager {
        try {
            if ($signals.Release.WaitOne(0) -and -not $script:operation) {Stop-MoonshineManager;return}
            if ($signals.Show.WaitOne(0)) {Show-MoonshineWindow}
            if ($signals.Uninstall.WaitOne(0)) {Show-MoonshineWindow -Maintenance;Invoke-MoonshineSetupAction 'Uninstall'}
            if ($script:operation) {
                $report=Read-MoonshineOperation $ownerSid $operation.id $operation.action
                if ($report) {$controls.OperationText.Text=$report.message;$controls.OperationProgress.Value=[int]$report.percent}
                if ($operation.process.HasExited) {
                    $completed=$operation;$script:operation=$null;$code=$completed.process.ExitCode;$completed.process.Dispose();$script:MoonshineDeviceStatus=$null
                    if ($report -and $report.phase -eq 'completed' -and $code -eq 0) {
                        $controls.OperationText.Text=if($report.result.restart_required){'Pilotes prepares. Redemarrer Windows avant le stream.'}elseif($report.result.path){'Copie privee conservee : '+$report.result.path}else{'Operation terminee.'}
                        if ($completed.action -eq 'Diagnostic') {
                            $dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='Archive ZIP (*.zip)|*.zip';$dialog.FileName='Moonshine-diagnostic.zip'
                            if ($dialog.ShowDialog() -eq $true) {[IO.File]::Copy((Join-Path (Get-MoonshineOperationFolder $ownerSid $completed.id) 'diagnostic.zip'),$dialog.FileName,$true)}
                        }
                        if ($completed.action -eq 'Uninstall') { $null=[Windows.MessageBox]::Show(('Moonshine est desinstalle. Bibliotheque et pilotes conserves. Archive : '+$report.result.path),'Moonshine');Stop-MoonshineManager;return }
                        if($completed.from_tray -and $notify){$notify.ShowBalloonTip(2500,'Moonshine',$(if($completed.action -eq 'Start'){'Le service est demarre.'}else{'Le service est arrete.'}),[Windows.Forms.ToolTipIcon]::Info)}
                    } else { $controls.OperationText.Text=if($report){$report.message}else{'Operation non terminee ou confirmation Windows annulee. Reprendre la meme action.'} }
                } else {return}
            }
            $previouslyInstalled=$script:evidence -and $evidence.installed
            $script:ticks++;$script:evidence=Read-MoonshineManagerEvidence $ownerSid $sourceCommit -RefreshDevices:($script:ticks % 10 -eq 1)
            if($fromInstalled -and $previouslyInstalled -and -not $evidence.installed -and -not $evidence.blocked){Stop-MoonshineManager;return}
            $script:model=Get-MoonshineManagerModel $evidence
            $controls.StatusText.Text=$model.title;$controls.DetailText.Text=$model.detail;$controls.PrimaryButton.Content=$model.primary;$controls.PrimaryButton.IsEnabled=$model.enabled
            $controls.InstallStep.Text=$model.install_step;$controls.DriverStep.Text=$model.driver_step;$controls.RunStep.Text=$model.run_step
            $controls.StopButton.IsEnabled=$evidence.running -and -not $evidence.blocked
            foreach($key in @('RepairButton','DriversButton','BackupButton','RemoveButton')) {$controls[$key].IsEnabled=$evidence.installed -and -not $evidence.running -and -not $evidence.blocked}
            $controls.DiagnosticButton.IsEnabled=$evidence.installed -and -not $evidence.blocked
            $controls.InstallChoices.Visibility=if($evidence.installed){'Collapsed'}else{'Visible'}
            $controls.MigrateChoice.IsEnabled=(-not $evidence.installed -and [IO.File]::Exists($preview))
            if(-not $script:choicesInitialized -and $evidence.installed){$controls.AutomaticChoice.IsChecked=$evidence.automatic;$script:choicesInitialized=$true}
            $controls.TrayButton.IsEnabled=$evidence.installed
            Ensure-MoonshineTray
            if($notify){$notify.Text=('Moonshine - '+$model.title).Substring(0,[Math]::Min(63,('Moonshine - '+$model.title).Length));$trayItems.Status.Text=$model.title;$trayItems.Open.Enabled=$evidence.running;$trayItems.Start.Enabled=$model.action -eq 'Start';$trayItems.Stop.Enabled=$evidence.running -and -not $evidence.blocked}
        } catch {$controls.OperationText.Text=$_.Exception.Message}
    }
    $controls.PrimaryButton.Add_Click({Invoke-MoonshineSetupAction $model.action})
    $controls.StopButton.Add_Click({Invoke-MoonshineSetupAction 'Stop'})
    $controls.RepairButton.Add_Click({Invoke-MoonshineSetupAction 'Repair'})
    $controls.DriversButton.Add_Click({Invoke-MoonshineSetupAction 'Drivers'})
    $controls.BackupButton.Add_Click({Invoke-MoonshineSetupAction 'Backup'})
    $controls.DiagnosticButton.Add_Click({Invoke-MoonshineSetupAction 'Diagnostic'})
    $controls.RemoveButton.Add_Click({Invoke-MoonshineSetupAction 'Uninstall'})
    $controls.HelpButton.Add_Click({Start-Process (Join-Path $PSScriptRoot 'LIRE-MOI.txt')})
    $controls.TrayButton.Add_Click({Enter-MoonshineTray})
    $window.Add_Closing({param($sender,$event)
        if($script:quit){return}
        $event.Cancel=$true
        if($evidence.installed){$null=$window.Dispatcher.BeginInvoke([Action]{Enter-MoonshineTray})}
        elseif(-not $script:operation){$null=$window.Dispatcher.BeginInvoke([Action]{Stop-MoonshineManager})}
    })
    $script:ticks=0;Write-MoonshineCIPhase 'reading-state';Update-MoonshineManager;Write-MoonshineCIPhase 'state-read'
    $window.ShowInTaskbar=-not $fromInstalled
    if($Uninstall){Show-MoonshineWindow -Maintenance;Invoke-MoonshineSetupAction 'Uninstall'}elseif((-not $fromInstalled -and -not $TrayOnly) -or -not $evidence.installed){$window.Show()}
    if($CITrace){
        if($env:GITHUB_ACTIONS -ne 'true' -or $env:CI -ne 'true'){throw 'CI trace is restricted to a disposable runner.'}
        [IO.File]::WriteAllText($CITrace,(ConvertTo-Json @{icon_visible=[bool]($notify -and $notify.Visible);window_visible=$window.IsVisible;sid=$ownerSid;system=$identity.IsSystem;admin=(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);menu_items=@($trayItems.Keys);service_running=$evidence.running}))
    }
    $script:timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(1);$timer.Add_Tick({Update-MoonshineManager});$timer.Start()
    $null=$application.Run()
} catch {
    if($ValidateWindowOnly){throw}
    if($CITrace -and $env:GITHUB_ACTIONS -eq 'true' -and $env:CI -eq 'true'){[IO.File]::WriteAllText($CITrace,(ConvertTo-Json @{error=$_.Exception.Message;stack=$_.ScriptStackTrace}));exit 1}
    $null=[Windows.MessageBox]::Show($_.Exception.Message,'Moonshine')
}
finally {
    if($script:timer){$timer.Stop()};if($script:notify){$notify.Visible=$false;$notify.Dispose()};if($script:trayIcon){$trayIcon.Dispose()};if($script:trayMenu){$trayMenu.Dispose()}
    if($script:operation){$operation.process.Dispose()};foreach($signal in $signals.Values){$signal.Dispose()};if($ownsMutex){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
if($script:launchInstalled){Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $script:MoonshineServiceRoot 'Kit\Gestion-Moonshine.ps1')+'" -TrayOnly')}

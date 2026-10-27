#Requires -Version 5.1
function Init-DesktopTypes {
    foreach ($assembly in @('PresentationFramework','PresentationCore','WindowsBase','System.Xaml')) { Add-Type -AssemblyName $assembly }
    if ('OPi5DesktopController' -as [type]) { return }
    if ('OPi5GuiBridge' -as [type]) { throw 'Interface partiellement chargée; fermer le programme et relancer Demarrer.cmd.' }
    $references=@('System.dll','System.Core.dll',[Management.Automation.PowerShell].Assembly.Location,
        [Windows.Window].Assembly.Location,[Windows.Media.ImageSource].Assembly.Location,
        [Windows.Threading.Dispatcher].Assembly.Location,[System.Xaml.XamlReader].Assembly.Location)
    Add-Type -Path @((Join-Path $PSScriptRoot 'GuiBridge.cs'),(Join-Path $PSScriptRoot 'DesktopView.cs')) -ReferencedAssemblies $references -ErrorAction Stop
}
function Invoke-GuiSelfTests {
    . (Join-Path $PSScriptRoot 'GuiDiagnostics.ps1')
    $script:SelfTestCheckpoint='Compilation de l interface Windows et du pont de travail'
    Init-DesktopTypes
    Assert ($null -ne ('OPi5DesktopController' -as [type])) 'Contrôleur WPF et pont compilés dans Windows PowerShell 5.1'
    Assert ([OPi5GuiBridge]::ValidCommand('Preview') -and [OPi5GuiBridge]::ValidCommand('RestoreReset') -and
        -not [OPi5GuiBridge]::ValidCommand('commande.exe')) 'Interface limitée à des actions connues, sans commande libre'
    $bridge=New-Object OPi5GuiBridge
    try {
        $command=New-Object OPi5GuiCommand;$command.Name='Preview'
        Assert ($bridge.Enqueue($command)) 'Première action graphique mise en file'
        $second=New-Object OPi5GuiCommand;$second.Name='SyncAll'
        Assert (-not $bridge.Enqueue($second)) 'Double clic ne met pas une deuxième synchronisation en attente'
        $request=$bridge.NextCommand()
        Assert ($request.Name -eq 'Preview') 'Action transmise au moteur par objet typé'
        $request.Dispose();$second.Dispose();$bridge.FinishCommand()
        $savedBridge=$script:GuiBridge
        $cancelled=$false
        try { $script:GuiBridge=$bridge;$bridge.Cancel();try { Operation-Checkpoint } catch { $cancelled=$true } }
        finally { $script:GuiBridge=$savedBridge }
        Assert $cancelled 'Annulation vérifiée aux points de reprise du moteur'
        $secret=New-Object Security.SecureString;$secret.AppendChar('x')
        $login=New-Object OPi5GuiCommand;$login.Name='Connect';$login.Password=$secret;$login.Dispose()
        Assert ($null -eq $login.Password) 'Mot de passe conservé en SecureString puis libéré avec la requête'
        $properties=@([OPi5GuiSnapshot].GetProperties() | ForEach-Object { $_.Name })
        Assert ('Password' -notin $properties -and 'Authorization' -notin $properties) 'Aucun secret dans les données de présentation'
    } finally { $bridge.Dispose() }
    Assert ([OPi5GuiBridge]::TestPromptRoundTrip()) 'Confirmation graphique aller-retour et rejet d une réponse périmée'
    $filterGame=New-Object OPi5GuiGame;$filterGame.Title='PGA Tour';$filterGame.Platform='EA';$filterGame.Key='ea:16425629';$filterGame.Action='update'
    Assert ([OPi5DesktopController]::Matches($filterGame,'16425629','EA','Changements')) 'Filtres combinent identifiant, plateforme et changements'
    Assert (-not [OPi5DesktopController]::Matches($filterGame,'','Steam','Changements')) 'Filtre plateforme n inclut pas un jeu EA dans Steam'
    Assert (-not [OPi5DesktopController]::Matches($filterGame,'','Toutes','À jour / présents')) 'Filtre à jour exclut les mises à jour proposées'
    $filterGame.Action='pending'
    Assert ([OPi5DesktopController]::Matches($filterGame,'pga','Toutes','À vérifier')) 'Attente retrouvée dans les éléments à vérifier'
    Invoke-GuiBoundarySelfTests
    $preferences=Parse-GuiHostPreferences "# commentaire`ncapture = wgc`nencoder = nvenc`npassword = ne_pas_copier`napi_token = ne_pas_copier`nnvenc_preset = 3"
    Assert ($preferences.Count -eq 3 -and $preferences.capture -eq 'wgc' -and -not $preferences.ContainsKey('password')) 'Diagnostic limité aux préférences autorisées, sans identifiants du fichier de configuration'
    $imageFolder=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('opi5-ui-image-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($imageFolder) | Out-Null
    try {
        $imagePath=Join-Path $imageFolder 'pochette [test].png'
        $bitmap=New-Object System.Drawing.Bitmap 16,16
        try { $bitmap.Save($imagePath,[System.Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
        $game=New-Object OPi5GuiGame;$game.Cover=$imagePath
        $row=New-Object OPi5DesktopRow($game)
        $image=$row.CoverImage
        Assert ($null -ne $image -and $image.IsFrozen) 'Pochette locale décodée et figée pour l interface'
        $exclusive=[IO.File]::Open($imagePath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $exclusive.Dispose()
        Remove-Item -LiteralPath $imagePath
        Assert (-not (Test-Path -LiteralPath $imagePath)) 'Interface ne conserve aucun verrou sur la pochette après chargement'
    } finally { if (Test-Path -LiteralPath $imageFolder) { Remove-Item -LiteralPath $imageFolder -Recurse -Force } }
    $window=$null;$controller=$null
    $script:SelfTestCheckpoint='Construction XAML réelle sans afficher de fenêtre de test'
    $stream=[IO.File]::OpenRead((Join-Path $PSScriptRoot 'Desktop.xaml'))
    try { $window=[Windows.Markup.XamlReader]::Load($stream) } finally { $stream.Dispose() }
    try {
        foreach ($name in [OPi5DesktopController]::RequiredNames) { Assert ($null -ne $window.FindName($name)) ('Contrôle de la fenêtre : '+$name) }
        $uiBridge=New-Object OPi5GuiBridge
        $controller=New-Object OPi5DesktopController($window,$uiBridge,$PSScriptRoot)
        $snapshot=New-Object OPi5GuiSnapshot
        $one=New-Object OPi5GuiGame;$one.Title='Jeu synthétique';$one.Platform='Steam';$one.Action='update';$one.State='À mettre à jour';$one.Uuid='synthetique'
        $snapshot.Games=[OPi5GuiGame[]]@($one);$snapshot.Cached=$true;$snapshot.Connected=$true;$snapshot.Connection='Test local';$snapshot.PlanScope='Tous les jeux'
        $controller.ApplySnapshot($snapshot)
        Assert ($window.FindName('GameCount').Text -eq '1' -and $window.FindName('ChangeCount').Text -eq '1') 'Comptes de bibliothèque et de changements liés aux données réelles du modèle'
        Assert ($window.FindName('NoticeText').Text -like '*précédente*') 'Résultats en cache explicitement distingués d une nouvelle analyse'
        $window.FindName('SearchBox').Text='inexistant'
        Assert ($window.FindName('EmptyTitle').Text -like '*filtres*' -and $window.FindName('FilteredCount').Text -like '0 / 1*') 'Recherche vide explique les filtres et conserve le nombre total'
        Assert (-not $window.FindName('SyncButton').IsEnabled) 'Synchronisation désactivée quand l état de session n est pas confirmé'
        $window.FindName('SearchBox').Text=''
        Assert ($window.FindName('SearchBox').GetValue([Windows.Automation.AutomationProperties]::NameProperty)) 'Champ de recherche nommé pour les outils d accessibilité'
    } finally { if ($controller) { $controller.Dispose() };if ($window) { $window.Close() } }
}
function Invoke-GuiBoundarySelfTests {
    $savedData=$script:Data;$savedRuntime=$script:Runtime;$savedBridge=$script:GuiBridge;$savedRepairs=$script:Repairs
    $temporary=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('opi5-ui-boundary-'+[guid]::NewGuid().ToString('N'))
    $localBridge=New-Object OPi5GuiBridge
    function Session-Idle { }
    function Get-Apps { return Clone-Object @{apps=@($script:UiTestApps)} }
    function Api-Call([string]$Method,[string]$Path,$Body=$null) {
        if ($Method -ne 'POST' -or $Path -ne '/api/apps') { throw 'Appel inattendu dans le test de limite d annulation.' }
        $script:UiTestPosts++
        $script:UiTestApps=@($script:UiTestApps | Where-Object { $_.uuid -ne $Body.uuid })+@((Clone-Object $Body))
        if ($script:UiTestPosts -eq 1) { $localBridge.Cancel() }
        return @{status=$true}
    }
    try {
        $script:Data=$temporary;$script:Runtime=Join-Path $temporary 'versions\0.8.0'
        $script:Repairs=New-Object 'Collections.Generic.List[object]'
        $script:UiTestApps=@();$script:UiTestPosts=0
        $games=@()
        foreach ($id in @('990080','1926590','4374500')) { $key='steam:'+$id;$games+=@{key=$key;uuid=(Stable-Id $key);kind='steam';title=('Jeu '+$id);steam_id=$id;install='C:\Jeu';cover='';monitor_names=@()} }
        $state=Empty-State
        $plan=@(Build-Plan $games @() $state $script:Runtime $script:Data)
        $failure=$null
        try { $script:GuiBridge=$localBridge;$null=Apply-Plan $plan $games $state (Get-Apps) 6>$null }
        catch { $failure=$_ }
        finally { $script:GuiBridge=$savedBridge }
        $cause=$(if ($failure) {$failure.Exception} else {$null})
        while ($cause -and $cause.InnerException) { $cause=$cause.InnerException }
        if ($failure -and $cause -isnot [OperationCanceledException]) { throw $failure }
        Assert ($cause -is [OperationCanceledException] -and $script:UiTestPosts -eq 1) 'Annulation arrivée pendant POST : le jeu suivant n est pas écrit'
        $savedState=Load-State
        Assert ($savedState.managed.Count -eq 1 -and $savedState.pending.Count -eq 0) 'POST en cours vérifié et journalisé avant de prendre en compte l annulation'
        $localBridge.FinishCommand()
        $again=@(Build-Plan $games (Get-Apps).apps $savedState $script:Runtime $script:Data)
        try { $script:GuiBridge=$localBridge;$null=Apply-Plan $again $games $savedState (Get-Apps) 6>$null }
        finally { $script:GuiBridge=$savedBridge }
        Assert ($script:UiTestPosts -eq 3 -and (Load-State).managed.Count -eq 3) 'Reprise après annulation sans renvoyer le POST du premier jeu'
    } finally {
        $script:Data=$savedData;$script:Runtime=$savedRuntime;$script:GuiBridge=$savedBridge;$script:Repairs=$savedRepairs
        Remove-Variable -Name @('UiTestApps','UiTestPosts') -Scope Script -ErrorAction SilentlyContinue
        $localBridge.Dispose()
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Input;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

public sealed class OPi5DesktopRow {
    public OPi5GuiGame Source { get; private set; }
    BitmapImage image;
    bool imageLoaded;
    public OPi5DesktopRow(OPi5GuiGame source) { Source = source; }
    public string Title { get { return Source.Title; } }
    public string Platform { get { return Source.Platform; } }
    public string State { get { return Source.State; } }
    public string Detail { get { return Source.Detail; } }
    public string StateColor { get { return Source.Action == "conflict" || Source.Action == "pending" ? "#EBC58B" : Source.Action == "update" || Source.Action == "add" ? "#B8EB79" : "#BAC7DA"; } }
    public ImageSource CoverImage {
        get {
            if (imageLoaded) return image;
            imageLoaded = true;
            try {
                string path = Source.Cover;
                if (String.IsNullOrEmpty(path) || !Path.IsPathRooted(path) || path.StartsWith(@"\\", StringComparison.Ordinal) || !String.Equals(Path.GetExtension(path), ".png", StringComparison.OrdinalIgnoreCase)) return null;
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                    image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad;
                    image.DecodePixelWidth = 124; image.StreamSource = stream; image.EndInit(); image.Freeze();
                }
            } catch { image = null; }
            return image;
        }
    }
}
public sealed class OPi5DesktopController : IDisposable {
    readonly Window window;
    readonly OPi5GuiBridge bridge;
    readonly OPi5GuiWorker worker = new OPi5GuiWorker();
    readonly DispatcherTimer timer;
    readonly string root, data;
    readonly ObservableCollection<OPi5DesktopRow> games = new ObservableCollection<OPi5DesktopRow>();
    readonly List<Button> actionButtons = new List<Button>();
    OPi5GuiSnapshot snapshot;
    bool ready, busy = true, closing, allowClose, disposed, workerStarted, observedCompletion;
    string lastExport, currentError;
    readonly Queue<string> history = new Queue<string>();
    bool applyingSnapshot;
    DateTime lastRefresh = DateTime.UtcNow;
    public static bool Matches(OPi5GuiGame row, string query, string platform, string state) {
        string searchable = (row.Title ?? "") + " " + (row.Platform ?? "") + " " + (row.Key ?? "");
        if (!String.IsNullOrWhiteSpace(query) && searchable.IndexOf(query.Trim(), StringComparison.CurrentCultureIgnoreCase) < 0) return false;
        if (platform != "Toutes" && !String.Equals(platform, row.Platform, StringComparison.OrdinalIgnoreCase)) return false;
        if (state == "Changements" && row.Action != "add" && row.Action != "update") return false;
        if (state == "À vérifier" && row.Action != "conflict" && row.Action != "pending" && row.Action != "unknown") return false;
        if (state == "À jour / présents" && row.Action != "unchanged" && row.Action != "existing") return false;
        return true;
    }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr handle, int attribute, ref int value, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr handle);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr handle, int command);
    public static bool ActivateExisting() {
        IntPtr handle = FindWindow(null, "OPi5 · VibeShine");
        if (handle == IntPtr.Zero) return false;
        ShowWindow(handle, 9); SetForegroundWindow(handle); return true;
    }
    public static readonly string[] RequiredNames = {
        "NavLibrary","NavStream","NavMaintenance","ConnectButton","OpenVibeButton","SearchBox","PlatformFilter","GameRows",
        "ProfileButton","PreviewButton","SyncButton","DiagnosticsButton","StreamProfileButton","EnableAutoButton","DisableAutoButton",
        "ResetButton","RestoreResetButton","UndoSyncButton","ExportButton","OpenBackupsButton","ConsoleButton","CancelButton",
        "PageTitle","PageSubtitle","NoticePanel","NoticeText","GameCount","ChangeCount","IssueCount","EmptyLibrary","ScanTime",
        "ConnectionState","ConnectionDetail","DiagnosticRows","DiagnosticScope","BackupRows","ProfileScope","AutoState","ResetState","OperationProgress","OpenDiagnosticButton","PilotButton","EaButton","EaPilotButton",
        "OperationState","LastSyncText","LibraryPage","StreamPage","MaintenancePage",
        "TestState","StateFilter","ClearFiltersButton","FilteredCount","DetailsButton","EmptyTitle","EmptyDetail","SessionState","RecoveryState","HistoryText","CopyHistoryButton"
    };
    T Find<T>(string name) where T : class { T value = window.FindName(name) as T; if (value == null) throw new InvalidOperationException("Contrôle absent : " + name); return value; }
    Button Button(string name) { return Find<Button>(name); }
    void Text(string name, string value) { Find<TextBlock>(name).Text = value ?? ""; }
    public OPi5DesktopController(Window window, OPi5GuiBridge bridge, string scriptRoot) {
        this.window = window; this.bridge = bridge; root = Path.GetFullPath(scriptRoot);
        Rect workArea = SystemParameters.WorkArea;
        double width = Math.Max(640, workArea.Width - 24), height = Math.Max(480, workArea.Height - 28);
        window.MinWidth = Math.Min(window.MinWidth, width); window.MinHeight = Math.Min(window.MinHeight, height);
        window.Width = Math.Min(window.Width, width); window.Height = Math.Min(window.Height, height);
        data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"OPi5\VibeShine-Xbox");
        foreach (string name in RequiredNames) if (window.FindName(name) == null) throw new InvalidOperationException("Contrôle absent : " + name);
        Find<ListBox>("GameRows").ItemsSource = games;
        CollectionViewSource.GetDefaultView(games).Filter = Filter;
        Find<TextBox>("SearchBox").TextChanged += delegate { CollectionViewSource.GetDefaultView(games).Refresh(); UpdateEmpty(); };
        Find<ComboBox>("PlatformFilter").SelectionChanged += delegate { CollectionViewSource.GetDefaultView(games).Refresh(); UpdateEmpty(); };
        Find<ComboBox>("StateFilter").SelectionChanged += delegate { CollectionViewSource.GetDefaultView(games).Refresh(); UpdateEmpty(); };
        Button("ClearFiltersButton").Click += delegate { Find<TextBox>("SearchBox").Clear(); Find<ComboBox>("PlatformFilter").SelectedIndex = 0; Find<ComboBox>("StateFilter").SelectedIndex = 0; };
        Find<ListBox>("GameRows").SelectionChanged += delegate { if (!applyingSnapshot) { UpdateButtons(); UpdateProfileScope(); } };
        Find<ListBox>("GameRows").MouseDoubleClick += delegate { if (!busy) Safe(Details); };
        Button("DetailsButton").Click += delegate { Safe(Details); };
        Button("CopyHistoryButton").Click += delegate { Safe(delegate { Clipboard.SetText(Find<TextBox>("HistoryText").Text); }); };
        window.PreviewKeyDown += delegate(object sender, KeyEventArgs e) {
            if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { Page("Library"); Find<TextBox>("SearchBox").Focus(); Find<TextBox>("SearchBox").SelectAll(); e.Handled = true; }
            else if (e.Key == Key.F5 && ready && !busy && !closing) { Submit(new OPi5GuiCommand { Name = "Preview" }); e.Handled = true; }
            else if (e.Key == Key.Escape && busy && !closing) { CancelOperation(); e.Handled = true; }
        };
        Button("NavLibrary").Click += delegate { Page("Library"); };
        Button("NavStream").Click += delegate { Page("Stream"); if (ready && !busy && !closing) { OPi5DesktopRow selected = Selected; Submit(new OPi5GuiCommand { Name = "Status", GameId = selected == null ? null : selected.Source.Uuid }); } };
        Button("NavMaintenance").Click += delegate { Page("Maintenance"); };
        Bind("PreviewButton", "Preview"); Bind("SyncButton", "SyncAll"); Bind("DiagnosticsButton", "Status");
        Bind("EnableAutoButton", "EnableAuto"); Bind("DisableAutoButton", "DisableAuto");
        Bind("ResetButton", "Reset"); Bind("RestoreResetButton", "RestoreReset"); Bind("UndoSyncButton", "UndoSync"); Bind("ExportButton", "Export");
        Bind("PilotButton", "SyncPilot"); Bind("EaButton", "SyncEA"); Bind("EaPilotButton", "SyncEAPilot");
        Button("ConnectButton").Click += delegate { Safe(Login); }; actionButtons.Add(Button("ConnectButton"));
        Button("ProfileButton").Click += delegate { Safe(Profile); }; Button("StreamProfileButton").Click += delegate { Safe(Profile); };
        Button("CancelButton").Click += delegate { CancelOperation(); };
        Button("OpenVibeButton").Click += delegate { OpenVibe(); };
        Button("OpenBackupsButton").Click += delegate { OpenFolder(Path.Combine(data, "Backups")); };
        Button("OpenDiagnosticButton").Click += delegate { if (!String.IsNullOrEmpty(lastExport) && File.Exists(lastExport)) OpenFolder(Path.GetDirectoryName(lastExport)); };
        Button("ConsoleButton").Click += delegate { StartConsole(); };
        window.Closing += OnClosing;
        window.SourceInitialized += delegate { try { int enabled = 1; DwmSetWindowAttribute(new WindowInteropHelper(window).Handle, 20, ref enabled, sizeof(int)); } catch { } };
        timer = new DispatcherTimer(DispatcherPriority.Background); timer.Interval = TimeSpan.FromMilliseconds(130); timer.Tick += Tick;
        Page("Library"); UpdateButtons(); timer.Start();
    }
    void Bind(string control, string action) {
        Button button = Button(control); actionButtons.Add(button);
        button.Click += delegate {
            OPi5DesktopRow selected = Selected;
            Submit(new OPi5GuiCommand { Name = action, GameId = selected == null ? null : selected.Source.Uuid });
        };
    }
    OPi5DesktopRow Selected { get { return Find<ListBox>("GameRows").SelectedItem as OPi5DesktopRow; } }
    bool Filter(object value) {
        OPi5DesktopRow row = value as OPi5DesktopRow; if (row == null) return false;
        var item = Find<ComboBox>("PlatformFilter").SelectedItem as ComboBoxItem;
        var state = Find<ComboBox>("StateFilter").SelectedItem as ComboBoxItem;
        return Matches(row.Source, Find<TextBox>("SearchBox").Text, item == null ? "Toutes" : Convert.ToString(item.Content), state == null ? "Tous les états" : Convert.ToString(state.Content));
    }
    void UpdateEmpty() {
        var view = CollectionViewSource.GetDefaultView(games);
        int count = view.Cast<object>().Count();
        Find<StackPanel>("EmptyLibrary").Visibility = count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Text("FilteredCount", count.ToString(CultureInfo.CurrentCulture) + " / " + games.Count.ToString(CultureInfo.CurrentCulture) + " jeu(x) affiché(s)");
        Text("EmptyTitle", games.Count == 0 ? "Votre bibliothèque commence ici." : "Aucun jeu avec ces filtres.");
        Text("EmptyDetail", games.Count == 0 ? "Cliquez sur Analyser pour détecter les installations et préparer les changements." : "Modifiez la recherche ou cliquez sur Effacer les filtres.");
    }
    void CancelOperation() {
        bridge.Cancel(); Text("OperationState", "Annulation demandée : vérification de l’étape en cours avant l’arrêt."); Button("CancelButton").IsEnabled = false;
    }
    void Page(string name) {
        foreach (string page in new[] { "Library", "Stream", "Maintenance" }) {
            Find<FrameworkElement>(page + "Page").Visibility = page == name ? Visibility.Visible : Visibility.Collapsed;
            Button("Nav" + page).Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(page == name ? "#28372E" : "#101621"));
        }
        Text("PageTitle", name == "Library" ? "Vos jeux, prêts à streamer." : name == "Stream" ? "Une diffusion bien réglée." : "Vos données, sous contrôle.");
        Text("PageSubtitle", name == "Library" ? "Steam, Xbox et EA réunis dans VibeShine." : name == "Stream" ? "Profils par jeu et préférences détectées sur ce PC." : "Automatisation, sauvegardes et récupération.");
    }
    public void Start() {
        if (workerStarted) return; workerStarted = true;
        try { worker.Start(Path.Combine(root, "VibeShine-Xbox.ps1"), bridge); }
        catch (Exception ex) { workerStarted = false; ready = false; busy = false; Notice(ex.Message, true); Text("OperationState", "Le moteur n’a pas démarré. Le mode console reste disponible."); UpdateButtons(); }
    }
    bool Submit(OPi5GuiCommand command, bool quiet = false) {
        if (!ready || busy || closing || !bridge.Enqueue(command)) { command.Dispose(); return false; }
        if (!quiet) currentError = null;
        if (!quiet) Notice("Opération en cours. Les changements du catalogue restent soumis à confirmation.", false);
        lastRefresh = DateTime.UtcNow;
        if (!quiet) AppendHistory("Action", command.Name == "Preview" ? "Analyse de la bibliothèque" : command.Name == "SyncAll" ? "Synchronisation de tous les jeux" : command.Name);
        busy = true; UpdateButtons();
        Find<ProgressBar>("OperationProgress").IsIndeterminate = true;
        Text("OperationState", "Préparation de l’opération…");
        return true;
    }
    void UpdateButtons() {
        bool available = ready && !busy && !closing;
        foreach (Button button in actionButtons) button.IsEnabled = available;
        bool connected = snapshot != null && snapshot.Connected;
        foreach (string name in new[] { "SyncButton", "EnableAutoButton", "ResetButton", "RestoreResetButton", "UndoSyncButton","PilotButton","EaButton","EaPilotButton" }) Button(name).IsEnabled = available && connected;
        if (snapshot != null) {
            foreach (string name in new[] { "SyncButton", "PilotButton", "EaButton", "EaPilotButton", "EnableAutoButton" }) Button(name).IsEnabled = available && snapshot.CanSync;
            Button("ResetButton").IsEnabled = available && snapshot.CanReset;
            Button("RestoreResetButton").IsEnabled = available && snapshot.CanRestoreReset;
            Button("UndoSyncButton").IsEnabled = available && snapshot.CanUndoSync;
            Button("UndoSyncButton").Content = snapshot.UndoPending ? "Reprendre l’annulation" : "Annuler la dernière sync";
        }
        Button("DetailsButton").IsEnabled = !busy && Selected != null && !closing;
        bool managed = Selected != null && Selected.Source.Managed;
        Button("ProfileButton").IsEnabled = Button("StreamProfileButton").IsEnabled = available && connected && managed && snapshot.CanSync;
        Button("CancelButton").IsEnabled = busy && !closing;
        Button("ConsoleButton").IsEnabled = !busy && !closing;
        Button("OpenDiagnosticButton").IsEnabled = !String.IsNullOrEmpty(lastExport) && File.Exists(lastExport);
    }
    void UpdateProfileScope() {
        OPi5DesktopRow row = Selected;
        string profile = row == null ? "" : row.Source.Profile;
        if (profile == "game-provided") profile = "FG fourni par le jeu";
        else if (profile == "off") profile = "Sans coordination FG";
        Text("ProfileScope", row == null ? "Sélectionnez un jeu dans la bibliothèque pour configurer son profil." : row.Title + " · " + (profile ?? "Réglages conservés"));
    }
    public void ApplySnapshot(OPi5GuiSnapshot value) {
        snapshot = value; lastRefresh = DateTime.UtcNow; string selectedKey = Selected == null ? null : Selected.Source.Key;
        applyingSnapshot = true;
        try {
            using (CollectionViewSource.GetDefaultView(games).DeferRefresh()) {
                games.Clear();
                foreach (OPi5GuiGame game in (value.Games ?? new OPi5GuiGame[0]).OrderBy(x => x.Title, StringComparer.CurrentCultureIgnoreCase)) games.Add(new OPi5DesktopRow(game));
            }
            if (selectedKey != null) Find<ListBox>("GameRows").SelectedItem = games.FirstOrDefault(x => x.Source.Key == selectedKey);
        } finally { applyingSnapshot = false; }
        Text("GameCount", games.Count.ToString(CultureInfo.CurrentCulture));
        Text("ChangeCount", games.Count(x => x.Source.Action == "add" || x.Source.Action == "update").ToString(CultureInfo.CurrentCulture));
        Text("IssueCount", games.Count(x => x.Source.Action == "conflict" || x.Source.Action == "pending").ToString(CultureInfo.CurrentCulture));
        Text("ConnectionState", value.Connected ? "VibeShine connecté" : "Connexion requise"); Text("ConnectionDetail", value.Connection);
        Button("ConnectButton").Content = value.Connected ? "Reconnecter" : "Connecter VibeShine";
        Text("TestState", value.Tests.ToString(CultureInfo.CurrentCulture) + " autotests réussis à l’ouverture"); Text("SessionState", value.Session); Text("RecoveryState", value.Recovery);
        Text("ScanTime", value.LastScan); Text("LastSyncText", value.LastSync); Text("AutoState", value.Automation); Text("ResetState", value.Reset);
        Find<DataGrid>("DiagnosticRows").ItemsSource = value.Diagnostics ?? new OPi5GuiDiagnostic[0];
        Find<DataGrid>("BackupRows").ItemsSource = value.Backups ?? new OPi5GuiBackup[0];
        Text("DiagnosticScope", "VÉRIFICATION · " + (value.Selection ?? "Préférences hôte"));
        if (currentError != null) Notice(currentError, true);
        else if (!String.IsNullOrEmpty(value.Recovery)) Notice(value.Recovery, true);
        else if (value.Connected && !value.CanSync && (value.Session ?? "").Length > 0) Notice(value.Session + ". Actualisez le diagnostic pour vérifier à nouveau.", false);
        else if (!value.Connected) Notice("Catalogue local : connectez VibeShine pour vérifier les correspondances avant la synchronisation.", false);
        else if (value.Cached) Notice("Résultats d’une analyse précédente. Cliquez sur Analyser pour les actualiser.", false);
        else if (value.CatalogOnly) Notice("Entrées présentes dans VibeShine. Analysez les installations pour actualiser le plan.", false);
        else Notice("Plan : " + (value.PlanScope ?? "Tous les jeux") + ". Une confirmation précède chaque écriture dans VibeShine.", false);
        UpdateEmpty(); UpdateProfileScope(); UpdateButtons();
    }
    void Notice(string message, bool error) {
        if (error) currentError = message;
        Text("NoticeText", message);
        Find<Border>("NoticePanel").Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(error ? "#432C30" : "#253045"));
    }
    void AppendHistory(string kind, string message) {
        if (String.IsNullOrWhiteSpace(message)) return;
        string clean = message.Length > 1800 ? message.Substring(0, 1800) + "…" : message;
        history.Enqueue(DateTime.Now.ToString("HH:mm:ss", CultureInfo.CurrentCulture) + " · " + kind + " · " + clean.Replace("\r", ""));
        while (history.Count > 150) history.Dequeue();
        Find<TextBox>("HistoryText").Text = String.Join(Environment.NewLine, history.ToArray());
        Find<TextBox>("HistoryText").ScrollToEnd();
    }
    void Safe(Action action) { try { action(); } catch (Exception ex) { Notice("Impossible de terminer cette action : " + ex.Message, true); } }
    void Tick(object sender, EventArgs args) {
        for (int i = 0; i < 250; i++) {
            OPi5GuiMessage message = bridge.TakeMessage(); if (message == null) break;
            switch (message.Kind) {
                case "ready": ready = true; busy = false; Text("OperationState", "Prêt. Contrôles de démarrage réussis."); Find<ProgressBar>("OperationProgress").IsIndeterminate = false; UpdateButtons(); break;
                case "idle": busy = false; Find<ProgressBar>("OperationProgress").IsIndeterminate = false; Find<ProgressBar>("OperationProgress").Value = 0; UpdateButtons(); break;
                case "result": Text("OperationState", message.Text); AppendHistory("Résultat", message.Text); break;
                case "progress": case "log": Text("OperationState", message.Text); if (message.Kind == "log") AppendHistory("Info", message.Text); if (message.Kind == "progress") { Find<ProgressBar>("OperationProgress").IsIndeterminate = message.Percent < 0; if (message.Percent >= 0) Find<ProgressBar>("OperationProgress").Value = message.Percent; } break;
                case "snapshot": ApplySnapshot((OPi5GuiSnapshot)message.Data); break;
                case "prompt":
                    var prompt = (OPi5GuiPrompt)message.Data;
                    try { Confirm(prompt); } catch (Exception ex) { bridge.Reply(prompt.Id, ""); Notice("Confirmation fermée sans application : " + ex.Message, true); }
                    break;
                case "error": AppendHistory("Erreur", message.Text); Notice(message.Text, true); Text("OperationState", "Opération suspendue. Le diagnostic peut être exporté depuis Maintenance."); break;
                case "fatal": AppendHistory("Démarrage", message.Text); ready = false; busy = false; Notice(message.Text, true); Text("OperationState", "Démarrage interrompu. Le mode console reste disponible."); Find<ProgressBar>("OperationProgress").IsIndeterminate = false; UpdateButtons(); break;
                case "export": lastExport = message.Text; Notice("Diagnostic créé sur le Bureau : " + Path.GetFileName(lastExport), false); UpdateButtons(); break;
            }
        }
        if (ready && !busy && !closing && window.IsActive && DateTime.UtcNow.Subtract(lastRefresh).TotalSeconds >= 60) {
            OPi5DesktopRow selected = Selected;
            Submit(new OPi5GuiCommand { Name = "Status", GameId = selected == null ? null : selected.Source.Uuid }, true);
        }
        if (worker.Completed && !observedCompletion) {
            observedCompletion = true;
            worker.Complete(); ready = false; busy = false; UpdateButtons();
            Find<ProgressBar>("OperationProgress").IsIndeterminate = false;
            if (!closing && currentError == null) Notice("Le moteur s’est arrêté. Fermez la fenêtre puis relancez OPi5." + (String.IsNullOrEmpty(worker.Error) ? "" : " " + worker.Error), true);
            if (closing) { allowClose = true; window.Close(); }
        }
    }
    Window Dialog(string title, int width) {
        return new Window { Title = title, Owner = window, Width = Math.Min(width, Math.Max(450, window.ActualWidth - 26)), SizeToContent = SizeToContent.Height,
            MaxHeight = Math.Max(450, window.ActualHeight - 35), WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize, Background = window.Background, Foreground = window.Foreground,
            FontFamily = window.FontFamily, FontSize = 14, Resources = window.Resources, ShowInTaskbar = false };
    }
    static TextBlock Label(string text) { return new TextBlock { Text = text, Margin = new Thickness(0, 12, 0, 7), TextWrapping = TextWrapping.Wrap }; }
    StackPanel DialogBody(Window dialog) {
        var panel = new StackPanel { Margin = new Thickness(23) };
        dialog.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = dialog.MaxHeight - 45 };
        return panel;
    }
    void Confirm(OPi5GuiPrompt prompt) {
        if (closing) { bridge.Reply(prompt.Id, ""); return; }
        Window dialog = Dialog(prompt.Title, 610); StackPanel panel = DialogBody(dialog);
        panel.Children.Add(Label(prompt.Text));
        TextBox typed = null;
        if (prompt.Typed) { panel.Children.Add(Label("Pour confirmer, saisissez " + prompt.Expected + ".")); typed = new TextBox(); panel.Children.Add(typed); }
        var warning = new TextBlock { Foreground = Brushes.Salmon, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) }; panel.Children.Add(warning);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 17, 0, 0) };
        var cancel = new Button { Content = "Revenir", IsCancel = true, Margin = new Thickness(0, 0, 10, 0) };
        var apply = new Button { Content = prompt.Typed ? "Confirmer le retrait" : "Confirmer", IsDefault = true, Style = (Style)window.Resources["Primary"] };
        buttons.Children.Add(cancel); buttons.Children.Add(apply); panel.Children.Add(buttons);
        apply.Click += delegate {
            if (typed != null && typed.Text != prompt.Expected) { warning.Text = "Le texte ne correspond pas. Aucune entrée n’a été retirée."; typed.Focus(); return; }
            dialog.DialogResult = true;
        };
        bool accepted = dialog.ShowDialog() == true;
        bridge.Reply(prompt.Id, accepted ? prompt.Expected : "");
    }
    void Details() {
        OPi5DesktopRow row = Selected; if (row == null) return;
        Window dialog = Dialog("Détails du jeu", 940); StackPanel panel = DialogBody(dialog);
        panel.Children.Add(new TextBlock { Text = row.Title, FontSize = 23, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(Label(row.Platform + " · " + row.State + Environment.NewLine + row.Detail));
        panel.Children.Add(Label(snapshot != null && snapshot.PlanVerified ? "Comparaison du catalogue VibeShine et du plan proposé. Les réglages personnels sont conservés." : "Valeurs disponibles à titre indicatif. Analysez et connectez VibeShine pour vérifier le plan."));
        var grid = new DataGrid { Height = Math.Max(180, Math.Min(360, dialog.MaxHeight - 260)), Margin = new Thickness(0, 10, 0, 10), ItemsSource = row.Source.Fields ?? new OPi5GuiField[0] };
        grid.Columns.Add(new DataGridTextColumn { Header = "Réglage", Binding = new Binding("Name"), Width = new DataGridLength(175) });
        grid.Columns.Add(new DataGridTextColumn { Header = "Actuellement", Binding = new Binding("Current"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        grid.Columns.Add(new DataGridTextColumn { Header = "Après synchronisation", Binding = new Binding("Proposed"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        grid.Columns.Add(new DataGridTextColumn { Header = "Décision", Binding = new Binding("Decision"), Width = new DataGridLength(155) });
        panel.Children.Add(grid);
        panel.Children.Add(new Button { Content = "Fermer", IsCancel = true, IsDefault = true, HorizontalAlignment = HorizontalAlignment.Right });
        dialog.ShowDialog();
    }
    void Login() {
        Window dialog = Dialog("Connecter VibeShine", 480); StackPanel panel = DialogBody(dialog);
        panel.Children.Add(Label("Utilisez les identifiants de l’interface Web de VibeShine sur ce PC."));
        panel.Children.Add(Label("Port HTTPS")); var port = new TextBox { Text = snapshot != null && !String.IsNullOrEmpty(snapshot.Endpoint) ? new Uri(snapshot.Endpoint).Port.ToString(CultureInfo.InvariantCulture) : "47990" }; panel.Children.Add(port);
        panel.Children.Add(Label("Nom d’utilisateur")); var user = new TextBox(); panel.Children.Add(user);
        panel.Children.Add(Label("Mot de passe")); var password = new PasswordBox(); panel.Children.Add(password);
        panel.Children.Add(Label("La connexion enregistrée reste chiffrée pour votre compte Windows."));
        var error = new TextBlock { Foreground = Brushes.Salmon, TextWrapping = TextWrapping.Wrap }; panel.Children.Add(error);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var cancel = new Button { Content = "Revenir", IsCancel = true, Margin = new Thickness(0, 0, 10, 0) };
        var connect = new Button { Content = "Connecter", IsDefault = true, Style = (Style)window.Resources["Primary"] }; buttons.Children.Add(cancel); buttons.Children.Add(connect); panel.Children.Add(buttons);
        OPi5GuiCommand request = null;
        connect.Click += delegate {
            int number; string value = port.Text.Trim(); if (value.Length == 0) value = "47990";
            if (!Int32.TryParse(value, out number) || number < 1 || number > 65535 || String.IsNullOrWhiteSpace(user.Text)) { error.Text = "Entrez un port valide et un nom d’utilisateur."; return; }
            SecureString secret = password.SecurePassword;
            if (secret.Length == 0) { secret.Dispose(); error.Text = "Entrez le mot de passe VibeShine."; return; }
            request = new OPi5GuiCommand { Name = "Connect", Port = number.ToString(CultureInfo.InvariantCulture), User = user.Text, Password = secret };
            dialog.DialogResult = true;
        };
        bool accepted = dialog.ShowDialog() == true; password.Clear();
        if (accepted && request != null) Submit(request); else if (request != null) request.Dispose();
    }
    void Profile() {
        OPi5DesktopRow row = Selected; if (row == null || !row.Source.Managed) return;
        Window dialog = Dialog("Profil de diffusion", 600); StackPanel panel = DialogBody(dialog);
        panel.Children.Add(new TextBlock { Text = row.Title, FontSize = 21, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(Label("Choisissez comment VibeShine coordonne les images. Les options graphiques internes du jeu restent à régler dans le jeu."));
        var native = new RadioButton { Content = "DLSS / FSR Frame Generation fourni par le jeu", GroupName = "mode" };
        var off = new RadioButton { Content = "Aucune génération d’images coordonnée par VibeShine", GroupName = "mode" };
        var inherit = new RadioButton { Content = "Conserver les réglages actuels sans les gérer", GroupName = "mode" };
        if (row.Source.Profile == "off") off.IsChecked = true; else if (row.Source.Profile == "game-provided") native.IsChecked = true; else inherit.IsChecked = true;
        panel.Children.Add(native); panel.Children.Add(off); panel.Children.Add(inherit);
        panel.Children.Add(Label("Pour le FG natif : vérifier l’écran virtuel, WGC et RTSS. Évitez de le cumuler avec NVIDIA Smooth Motion."));
        panel.Children.Add(Label("Le choix sera proposé à la prochaine synchronisation, avec aperçu et sauvegarde."));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 15, 0, 0) };
        buttons.Children.Add(new Button { Content = "Revenir", IsCancel = true, Margin = new Thickness(0, 0, 10, 0) });
        var save = new Button { Content = "Enregistrer le profil", IsDefault = true, Style = (Style)window.Resources["Primary"] }; buttons.Children.Add(save); panel.Children.Add(buttons);
        save.Click += delegate { dialog.DialogResult = true; };
        if (dialog.ShowDialog() == true) Submit(new OPi5GuiCommand { Name = "Profile", GameId = row.Source.Uuid, Mode = native.IsChecked == true ? "game-provided" : off.IsChecked == true ? "off" : "unmanaged" });
    }
    void OpenVibe() {
        try {
            Uri url = new Uri(snapshot == null || String.IsNullOrEmpty(snapshot.Endpoint) ? "https://127.0.0.1:47990" : snapshot.Endpoint);
            if (url.Scheme != "https" || url.Host != "127.0.0.1" || url.AbsolutePath != "/" || url.Query.Length != 0 || url.Fragment.Length != 0) throw new InvalidOperationException("Adresse locale invalide.");
            Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
        }
        catch (Exception ex) { Notice("Impossible d’ouvrir VibeShine : " + ex.Message, true); }
    }
    void OpenFolder(string path) {
        try { Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo("explorer.exe", "\"" + path + "\"") { UseShellExecute = true }); }
        catch (Exception ex) { Notice("Impossible d’ouvrir le dossier : " + ex.Message, true); }
    }
    void StartConsole() {
        try {
            string path = Path.Combine(root, "Bootstrap.ps1");
            if (path.IndexOfAny(new[] { '"', '\r', '\n' }) >= 0) throw new InvalidOperationException("Chemin invalide.");
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            Process.Start(new ProcessStartInfo(powershell, "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \"" + path + "\" -Action Menu") { UseShellExecute = true });
        } catch (Exception ex) { Notice("Impossible d’ouvrir la console : " + ex.Message, true); }
    }
    void OnClosing(object sender, CancelEventArgs args) {
        if (allowClose || !workerStarted || worker.Completed) return;
        args.Cancel = true; closing = true; bridge.RequestClose(); UpdateButtons();
        Text("OperationState", busy ? "Fermeture demandée : vérification de l’opération en cours avant l’arrêt…" : "Fermeture…");
    }
    public void Dispose() {
        if (disposed) return; disposed = true; timer.Stop();
        if (!workerStarted || worker.Completed) { worker.Dispose(); bridge.Dispose(); }
    }
}

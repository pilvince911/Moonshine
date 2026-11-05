// OPi5 native desktop: typed messages, no credentials in JSON or log streams.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Security;
using System.Threading;

public sealed class OPi5GuiField {
    public string Name { get; set; }
    public string Current { get; set; }
    public string Proposed { get; set; }
    public string Decision { get; set; }
}
public sealed class OPi5GuiGame {
    public OPi5GuiField[] Fields { get; set; }
    public string Uuid { get; set; }
    public string Key { get; set; }
    public string Title { get; set; }
    public string Platform { get; set; }
    public string Action { get; set; }
    public string State { get; set; }
    public string Detail { get; set; }
    public string Cover { get; set; }
    public string Profile { get; set; }
    public bool Managed { get; set; }
}
public sealed class OPi5GuiDiagnostic {
    public string Name { get; set; }
    public string Value { get; set; }
    public string Source { get; set; }
}
public sealed class OPi5GuiBackup {
    public string Name { get; set; }
    public string Kind { get; set; }
    public string Date { get; set; }
    public string State { get; set; }
}
public sealed class OPi5GuiSnapshot {
    public OPi5GuiGame[] Games { get; set; }
    public OPi5GuiDiagnostic[] Diagnostics { get; set; }
    public OPi5GuiBackup[] Backups { get; set; }
    public bool CanSync { get; set; }
    public bool CanReset { get; set; }
    public bool CanRestoreReset { get; set; }
    public bool CanUndoSync { get; set; }
    public bool UndoPending { get; set; }
    public bool PlanVerified { get; set; }
    public string Session { get; set; }
    public string Recovery { get; set; }
    public bool Connected { get; set; }
    public bool Cached { get; set; }
    public bool CatalogOnly { get; set; }
    public string Endpoint { get; set; }
    public string PlanScope { get; set; }
    public string Connection { get; set; }
    public string LastScan { get; set; }
    public string LastSync { get; set; }
    public string Automation { get; set; }
    public string Reset { get; set; }
    public string Selection { get; set; }
    public int Tests { get; set; }
}
public sealed class OPi5GuiCommand : IDisposable {
    public string Name { get; set; }
    public string GameId { get; set; }
    public string Mode { get; set; }
    public string User { get; set; }
    public string Port { get; set; }
    public SecureString Password { get; set; }
    public void Dispose() { if (Password != null) { Password.Dispose(); Password = null; } }
}
public sealed class OPi5GuiPrompt {
    public string Id { get; set; }
    public string Title { get; set; }
    public string Text { get; set; }
    public string Expected { get; set; }
    public bool Typed { get; set; }
}
public sealed class OPi5GuiMessage {
    public string Kind { get; set; }
    public string Text { get; set; }
    public int Percent { get; set; }
    public object Data { get; set; }
}
public sealed class OPi5GuiBridge : IDisposable {
    readonly ConcurrentQueue<OPi5GuiCommand> commands = new ConcurrentQueue<OPi5GuiCommand>();
    readonly ConcurrentQueue<OPi5GuiMessage> messages = new ConcurrentQueue<OPi5GuiMessage>();
    readonly ConcurrentDictionary<string, string> replies = new ConcurrentDictionary<string, string>();
    readonly AutoResetEvent wake = new AutoResetEvent(false);
    readonly object promptGate = new object();
    string activePrompt;
    int pending;
    volatile bool canceled, closing;
    public bool Closing { get { return closing; } }
    public bool IsCancellationRequested { get { return canceled || closing; } }
    public bool IsPending { get { return Interlocked.CompareExchange(ref pending, 0, 0) != 0; } }
    public static bool ValidCommand(string name) {
        switch (name) {
            case "Preview": case "SyncAll": case "SyncPilot": case "SyncEA": case "SyncEAPilot":
            case "Connect": case "Status": case "Export": case "Reset": case "RestoreReset":
            case "UndoSync": case "EnableAuto": case "DisableAuto": case "Profile": return true;
            default: return false;
        }
    }
    public bool Enqueue(OPi5GuiCommand command) {
        if (command == null || !ValidCommand(command.Name)) throw new ArgumentException("Action inconnue.");
        if (closing || Interlocked.CompareExchange(ref pending, 1, 0) != 0) return false;
        canceled = false;
        commands.Enqueue(command); wake.Set(); return true;
    }
    public OPi5GuiCommand NextCommand() {
        while (!closing) {
            OPi5GuiCommand value;
            if (commands.TryDequeue(out value)) return value;
            wake.WaitOne(250);
        }
        return null;
    }
    public void FinishCommand() { Interlocked.Exchange(ref pending, 0); canceled = false; Publish("idle", "Prêt.", -1, null); }
    public void MarkReady() { Publish("ready", "Prêt à analyser votre bibliothèque.", -1, null); }
    public void Publish(string kind, string text, int percent, object data) {
        messages.Enqueue(new OPi5GuiMessage { Kind = kind, Text = text ?? "", Percent = percent, Data = data });
    }
    public OPi5GuiMessage TakeMessage() { OPi5GuiMessage value; return messages.TryDequeue(out value) ? value : null; }
    public void Checkpoint() { if (canceled || closing) throw new OperationCanceledException("Opération annulée à un point de reprise sûr."); }
    public void Cancel() { canceled = true; wake.Set(); }
    public void RequestClose() { closing = true; canceled = true; wake.Set(); }
    public string Ask(string title, string text, string expected, bool typed) {
        Checkpoint();
        string id = Guid.NewGuid().ToString("N");
        lock (promptGate) { activePrompt = id; }
        try {
            Publish("prompt", "", -1, new OPi5GuiPrompt { Id = id, Title = title, Text = text, Expected = expected, Typed = typed });
            while (true) {
                Checkpoint();
                string reply;
                if (replies.TryRemove(id, out reply)) return reply;
                wake.WaitOne(100);
            }
        } finally {
            lock (promptGate) { activePrompt = null; }
            string ignored; replies.TryRemove(id, out ignored);
        }
    }
    public bool Reply(string id, string value) {
        lock (promptGate) {
            if (id == null || id != activePrompt) return false;
            bool added = replies.TryAdd(id, value ?? ""); wake.Set(); return added;
        }
    }
    public void Dispose() {
        RequestClose(); OPi5GuiCommand command;
        while (commands.TryDequeue(out command)) command.Dispose();
        wake.Dispose();
    }
    public static bool TestPromptRoundTrip() {
        var bridge = new OPi5GuiBridge(); string answer = null; Exception failure = null;
        var thread = new Thread(delegate() { try { answer = bridge.Ask("Test", "Données synthétiques", "APPLIQUER", false); } catch (Exception ex) { failure = ex; } });
        thread.IsBackground = true;
        try {
            thread.Start(); OPi5GuiMessage message = null;
            var until = DateTime.UtcNow.AddSeconds(3);
            while (DateTime.UtcNow < until && message == null) { message = bridge.TakeMessage(); if (message == null) Thread.Sleep(10); }
            var prompt = message == null ? null : message.Data as OPi5GuiPrompt;
            if (prompt == null || !bridge.Reply(prompt.Id, "APPLIQUER") || !thread.Join(3000)) return false;
            return answer == "APPLIQUER" && failure == null && !bridge.Reply(prompt.Id, "APPLIQUER");
        } finally { bridge.Cancel(); if (!thread.IsAlive || thread.Join(3000)) bridge.Dispose(); }
    }
}
public sealed class OPi5GuiWorker : IDisposable {
    Runspace runspace;
    PowerShell shell;
    IAsyncResult invocation;
    bool ended;
    public bool Completed { get { return invocation != null && invocation.IsCompleted; } }
    public string Error { get; private set; }
    public void Start(string scriptPath, OPi5GuiBridge bridge) {
        if (shell != null) throw new InvalidOperationException("Moteur déjà lancé.");
        runspace = RunspaceFactory.CreateRunspace();
        runspace.ApartmentState = ApartmentState.STA;
        runspace.ThreadOptions = PSThreadOptions.ReuseThread;
        runspace.Open();
        shell = PowerShell.Create(); shell.Runspace = runspace;
        shell.AddCommand(scriptPath).AddParameter("Action", "Gui").AddParameter("GuiBridge", bridge);
        invocation = shell.BeginInvoke();
    }
    public void Complete() {
        if (!Completed || ended) return;
        ended = true;
        try { shell.EndInvoke(invocation); }
        catch (Exception ex) { Error = ex.Message; }
    }
    public void Dispose() {
        if (invocation != null && !invocation.IsCompleted) throw new InvalidOperationException("Attendre la fin de l'opération avant de fermer le moteur.");
        Complete();
        if (shell != null) shell.Dispose();
        if (runspace != null) runspace.Dispose();
    }
}

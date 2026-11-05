using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

// Temporary test file only. A .NET timer releases the lock without running a
// PowerShell scriptblock on a thread without a runspace.
public sealed class OPi5FileLease : IDisposable {
    private FileStream held;
    private Timer releaseTimer;
    public OPi5FileLease(string path, int milliseconds) {
        if (milliseconds < 1 || milliseconds > 5000) throw new ArgumentOutOfRangeException("milliseconds");
        held = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        releaseTimer = new Timer(state => Dispose(), null, milliseconds, Timeout.Infinite);
    }
    public bool Released { get { return Interlocked.CompareExchange(ref held, null, null) == null; } }
    public void Dispose() {
        var stream = Interlocked.Exchange(ref held, null);
        if (stream != null) stream.Dispose();
        var timer = Interlocked.Exchange(ref releaseTimer, null);
        if (timer != null) timer.Dispose();
    }
}

// Synthetic local server only. Never connects to VibeShine or a public site.
public static class OPi5TransportTests {
    public static int Run(string certificatePath) {
        var globalCallback = ServicePointManager.ServerCertificateValidationCallback;
        // Temporary user key container works with Windows PowerShell's SChannel.
        // No PersistKeySet and no addition to a Windows certificate store.
        using (var certificate = new X509Certificate2(File.ReadAllBytes(certificatePath), "opi5-test-only", X509KeyStorageFlags.UserKeySet)) {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            string[] verbs = {"GET", "GET", "POST", "POST", "DELETE", "GET", "GET", "GET"};
            string[] bodies = {"", "", "{\"title\":\"échantillon\"}", "", "", "", "", ""};
            Exception serverError = null;
            var server = new Thread(() => {
                try {
                    for (int index = 0; index < verbs.Length; index++) {
                        using (var client = listener.AcceptTcpClient())
                        using (var ssl = new SslStream(client.GetStream(), false)) {
                            ssl.ReadTimeout = 6000; ssl.WriteTimeout = 6000;
                            try { ssl.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false); }
                            catch { if (index == 7) continue; throw; }
                            if (index == 7) continue;
                            var header = new StringBuilder();
                            while (!header.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal)) {
                                int value = ssl.ReadByte();
                                if (value < 0 || header.Length > 16384) throw new Exception("En-tete de test invalide.");
                                header.Append((char)value);
                            }
                            string[] lines = header.ToString().Split(new[] {"\r\n"}, StringSplitOptions.None);
                            if (!lines[0].StartsWith(verbs[index]+" /api/", StringComparison.Ordinal)) throw new Exception("Verbe HTTP de test incorrect.");
                            int length = 0; string authorization = "";
                            foreach (string line in lines) {
                                if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = Int32.Parse(line.Substring(15).Trim());
                                if (line.StartsWith("Authorization:", StringComparison.OrdinalIgnoreCase)) authorization = line.Substring(14).Trim();
                            }
                            if (length < 0 || length > 4096) throw new Exception("Taille de requete de test invalide.");
                            byte[] received = new byte[length]; int offset = 0;
                            while (offset < length) { int n = ssl.Read(received, offset, length-offset); if (n <= 0) throw new Exception("Corps de test incomplet."); offset += n; }
                            if (Encoding.UTF8.GetString(received) != bodies[index]) throw new Exception("Corps HTTP ou longueur UTF-8 incorrect.");
                            if (authorization != (index == 0 ? "" : "Bearer synthetic-test")) throw new Exception("Authentification du test incorrecte.");
                            string status = index == 5 ? "401 Unauthorized" : index == 6 ? "302 Found" : "200 OK";
                            string location = index == 6 ? "Location: https://example.com/never-follow\r\n" : "";
                            byte[] payload = Encoding.UTF8.GetBytes("{\"status\":true}");
                            byte[] response = Encoding.ASCII.GetBytes("HTTP/1.1 "+status+"\r\n"+location+"Content-Type: application/json\r\nContent-Length: "+payload.Length+"\r\nConnection: close\r\n\r\n");
                            ssl.Write(response, 0, response.Length); ssl.Write(payload, 0, payload.Length); ssl.Flush();
                        }
                    }
                } catch (Exception error) { serverError = error; }
            });
            server.IsBackground = true;
            server.Start();
            int passed = 0;
            string url = "https://127.0.0.1:"+port+"/api/";
            try {
                var probe = OPi5Native.Send(url+"csrf-token", "GET", "", "", "");
                if (probe.Status != 200 || String.IsNullOrEmpty(probe.Fingerprint)) throw new Exception("GET initial de test echoue.");
                passed++;
                for (int index = 1; index <= 5; index++) {
                    var reply = OPi5Native.Send(url+"synthetic", verbs[index], "Bearer synthetic-test", index == 1 ? null : bodies[index], probe.Fingerprint);
                    if (reply.Status != (index == 5 ? 401 : 200)) throw new Exception("Statut HTTP synthetique incorrect.");
                    passed++;
                }
                bool blocked = false;
                try { OPi5Native.Send(url+"synthetic", "GET", "Bearer synthetic-test", "", probe.Fingerprint); }
                catch (InvalidOperationException) { blocked = true; }
                if (!blocked) throw new Exception("Redirection de test non bloquee.");
                passed++;
                blocked = false;
                try { OPi5Native.Send(url+"synthetic", "GET", "Bearer synthetic-test", "", new string('0', 64)); }
                catch (InvalidOperationException) { blocked = true; }
                if (!blocked) throw new Exception("Certificat de test incorrect non bloque.");
                passed++;
                if (!server.Join(8000)) throw new Exception("Serveur synthetique non termine.");
                if (serverError != null) throw new Exception("Serveur synthetique : "+serverError.Message);
                if (!Object.Equals(globalCallback, ServicePointManager.ServerCertificateValidationCallback)) throw new Exception("Validation TLS globale modifiee.");
                return passed+1;
            } finally { listener.Stop(); server.Join(1000); }
        }
    }
}

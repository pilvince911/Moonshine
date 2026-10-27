// OPi5 VibeShine Xbox Sync 0.8.0. Windows PowerShell 5.1 / .NET Framework.
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public sealed class OPi5HttpReply {
    public int Status;
    public string Body;
    public string Fingerprint;
}

public sealed class OPi5HttpPlan {
    public HttpWebRequest Request;
    public byte[] Body;
    public string Fingerprint;
}

public static class OPi5Native {
    // Certificate exceptions are per request, restricted to literal loopback,
    // and pinned after an unauthenticated first contact. No global TLS bypass.
    // Preparing a request performs no network I/O. Send uses this same plan.
    public static OPi5HttpPlan Prepare(string url, string method, string auth,
                                       string body, string pin) {
        method = (method ?? "").ToUpperInvariant();
        if (method != "GET" && method != "POST" && method != "DELETE")
            throw new InvalidOperationException("Methode API non prise en charge.");
        if (method != "POST" && !String.IsNullOrEmpty(body))
            throw new InvalidOperationException("Cette methode API ne doit pas avoir de corps.");
        Uri uri = new Uri(url);
        if (uri.Scheme != "https" || uri.Host != "127.0.0.1" ||
            !String.IsNullOrEmpty(uri.UserInfo) || !String.IsNullOrEmpty(uri.Query) ||
            !String.IsNullOrEmpty(uri.Fragment) || !uri.AbsolutePath.StartsWith("/api/", StringComparison.Ordinal))
            throw new InvalidOperationException("Adresse API locale invalide.");
        if (!String.IsNullOrEmpty(pin) && !Regex.IsMatch(pin, "^[A-Fa-f0-9]{64}$"))
            throw new InvalidOperationException("Empreinte de certificat invalide.");
        if (String.IsNullOrEmpty(pin) && (!String.IsNullOrEmpty(auth) || method != "GET"))
            throw new InvalidOperationException("Certificat local non initialise.");
        var request = (HttpWebRequest)WebRequest.Create(uri);
        var plan = new OPi5HttpPlan { Request = request };
        request.Proxy = null;
        request.AllowAutoRedirect = false;
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        request.KeepAlive = false;
        request.Method = method;
        request.UserAgent = "OPi5-VibeShine-Xbox-Sync/0.8.0";
        request.Accept = "application/json";
        request.ServerCertificateValidationCallback = (sender, certificate, chain, errors) => {
            if (certificate == null) return false;
            using (var sha = SHA256.Create()) {
                plan.Fingerprint = BitConverter.ToString(sha.ComputeHash(certificate.GetRawCertData())).Replace("-", "");
            }
            return String.IsNullOrEmpty(pin) || String.Equals(plan.Fingerprint, pin, StringComparison.OrdinalIgnoreCase);
        };
        if (!String.IsNullOrEmpty(auth)) request.Headers[HttpRequestHeader.Authorization] = auth;
        // PowerShell 5.1 can turn $null into "" when binding a string argument.
        // A GET or DELETE never opens a request stream, including for "".
        if (method == "POST") {
            request.ContentType = "application/json; charset=utf-8";
            plan.Body = String.IsNullOrEmpty(body) ? null : Encoding.UTF8.GetBytes(body);
            request.ContentLength = plan.Body == null ? 0 : plan.Body.Length;
        }
        return plan;
    }

    public static OPi5HttpReply Send(string url, string method, string auth,
                                    string body, string pin) {
        var plan = Prepare(url, method, auth, body, pin);
        var request = plan.Request;
        if (plan.Body != null) {
            using (var stream = request.GetRequestStream()) stream.Write(plan.Body, 0, plan.Body.Length);
        }
        HttpWebResponse response;
        try { response = (HttpWebResponse)request.GetResponse(); }
        catch (WebException e) {
            response = e.Response as HttpWebResponse;
            if (response == null) throw new InvalidOperationException("Connexion HTTPS locale impossible; verifier VibeShine, le port et son certificat.");
        }
        using (response) {
            if ((int)response.StatusCode >= 300 && (int)response.StatusCode < 400)
                throw new InvalidOperationException("Redirection API refusee.");
            using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8)) {
                char[] buffer = new char[8192];
                var content = new StringBuilder();
                int count;
                while ((count = reader.Read(buffer, 0, buffer.Length)) > 0) {
                    content.Append(buffer, 0, count);
                    if (content.Length > 16777216) throw new InvalidOperationException("Reponse API trop volumineuse.");
                }
                return new OPi5HttpReply { Status = (int)response.StatusCode, Body = content.ToString(), Fingerprint = plan.Fingerprint };
            }
        }
    }

    public static bool PublicArtworkUrl(string url) {
        Uri uri;
        if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Scheme != "https" ||
            uri.Port != 443 || !String.IsNullOrEmpty(uri.UserInfo) || !String.IsNullOrEmpty(uri.Fragment)) return false;
        string host = uri.Host.ToLowerInvariant();
        if (host == "displaycatalog.mp.microsoft.com") return uri.AbsolutePath == "/v7.0/products";
        if (host == "store-images.s-microsoft.com") return uri.AbsolutePath.StartsWith("/image/", StringComparison.Ordinal);
        if (host == "store.steampowered.com") return uri.AbsolutePath == "/api/appdetails" || uri.AbsolutePath == "/api/storesearch/";
        if (host == "api.steampowered.com") return uri.AbsolutePath == "/IStoreBrowseService/GetItems/v1/";
        if (host == "shared.akamai.steamstatic.com" || host == "cdn.akamai.steamstatic.com" || host == "cdn.cloudflare.steamstatic.com")
            return Regex.IsMatch(uri.AbsolutePath, "^/(?:store_item_assets/)?steam/apps/[0-9]+/");
        return false;
    }

    // Separate public client: normal certificate validation; no API auth or pin.
    public static byte[] FetchArtwork(string url, int limit) {
        if (limit < 1 || limit > 8388608) throw new ArgumentOutOfRangeException("limit");
        for (int redirect = 0; redirect < 3; redirect++) {
            if (!PublicArtworkUrl(url)) throw new InvalidOperationException("Source de pochette non autorisee.");
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "GET";
            request.Proxy = null;
            request.AllowAutoRedirect = false;
            request.Timeout = 8000;
            request.ReadWriteTimeout = 8000;
            request.KeepAlive = false;
            request.UserAgent = "OPi5-VibeShine-Xbox-Sync/0.8.0";
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            using (var response = (HttpWebResponse)request.GetResponse()) {
                int status = (int)response.StatusCode;
                if (status >= 300 && status < 400) {
                    string location = response.Headers[HttpResponseHeader.Location];
                    if (String.IsNullOrEmpty(location)) throw new InvalidOperationException("Redirection de pochette invalide.");
                    url = new Uri(new Uri(url), location).AbsoluteUri;
                    continue;
                }
                if (status != 200 || response.ContentLength > limit) throw new InvalidOperationException("Reponse de pochette invalide ou trop volumineuse.");
                using (var input = response.GetResponseStream())
                using (var output = new MemoryStream()) {
                    byte[] buffer = new byte[16384];
                    int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                        if (output.Length + count > limit) throw new InvalidOperationException("Pochette trop volumineuse.");
                        output.Write(buffer, 0, count);
                    }
                    return output.ToArray();
                }
            }
        }
        throw new InvalidOperationException("Trop de redirections pour la pochette.");
    }

    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager {
        [PreserveSig]
        int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
    }
    [DllImport("ole32.dll")]
    private static extern int CoAllowSetForegroundWindow([MarshalAs(UnmanagedType.IUnknown)] object instance, IntPtr reserved);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr window, int command);

    public static uint Activate(string aumid) {
        object instance = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")));
        try {
            CoAllowSetForegroundWindow(instance, IntPtr.Zero);
            uint pid;
            int result = ((IApplicationActivationManager)instance).ActivateApplication(aumid, "", 0, out pid);
            if (result < 0) Marshal.ThrowExceptionForHR(result);
            return pid;
        } finally { Marshal.FinalReleaseComObject(instance); }
    }
    public static void Focus(IntPtr window) {
        if (window == IntPtr.Zero) return;
        ShowWindowAsync(window, 9);
        SetForegroundWindow(window);
    }
}

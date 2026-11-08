using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

// OAuth settings match upstream Fluent-Steam-Lua's CloudOAuthService (zlib)
// and CloudRedirect's public native-client registrations. PKCE + state are
// session-specific; only the private result file contains returned tokens.
internal static class CloudOAuth
{
    static string Base64(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    static string Query(IDictionary<string, string> values) => string.Join('&', values.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value)));
    public static async Task<object> Authorize(string provider, string status, CancellationToken ct)
    {
        bool google = provider == "gdrive";
        if (!google && provider != "onedrive") throw new Exception("Unsupported cloud OAuth provider");
        string id = google ? "REMOVED_GOOGLE_OAUTH_CLIENT_ID" : "REMOVED_MICROSOFT_OAUTH_CLIENT_ID";
        string secret = google ? "REMOVED_GOOGLE_OAUTH_CLIENT_SECRET" : "REMOVED_MICROSOFT_OAUTH_CLIENT_SECRET";
        string scope = google ? "https://www.googleapis.com/auth/drive.file" : "Files.ReadWrite offline_access";
        string auth = google ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
        string endpoint = google ? "https://oauth2.googleapis.com/token" : "https://login.microsoftonline.com/common/oauth2/v2.0/token";
        using var listener = new TcpListener(IPAddress.Loopback, google ? 0 : 53682);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        string redirect = $"http://localhost:{port}/" + (google ? "callback" : "");
        string state = Base64(RandomNumberGenerator.GetBytes(32));
        string verifier = Base64(RandomNumberGenerator.GetBytes(48));
        var fields = new Dictionary<string, string> { ["client_id"] = id, ["redirect_uri"] = redirect, ["response_type"] = "code", ["scope"] = scope, ["prompt"] = "consent", ["state"] = state, ["code_challenge"] = Base64(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))), ["code_challenge_method"] = "S256" };
        if (google) fields["access_type"] = "offline";
        Program.Write(status, new { state = "browser", url = auth + "?" + Query(fields) });
        string code;
        while (true)
        {
            using var connection = await listener.AcceptTcpClientAsync(ct);
            using var stream = connection.GetStream();
            using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            requestTimeout.CancelAfter(TimeSpan.FromSeconds(5));
            string request;
            try
            {
                var buffer = new byte[16384]; int length = 0;
                while (length < buffer.Length)
                {
                    int read = await stream.ReadAsync(buffer.AsMemory(length), requestTimeout.Token);
                    if (read == 0) break;
                    length += read;
                    if (Encoding.ASCII.GetString(buffer, 0, length).Contains("\r\n\r\n")) break;
                }
                request = Encoding.ASCII.GetString(buffer, 0, length);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { continue; }
            var first = request.Split("\r\n")[0].Split(' ');
            var callback = first.Length == 3 && first[0] == "GET" && first[1].StartsWith('/') && !first[1].StartsWith("//") ? new Uri($"http://localhost:{port}" + first[1]) : null;
            var query = new Dictionary<string, string>();
            if (callback != null)
                foreach (var item in callback.Query.TrimStart('?').Split('&'))
                {
                    var parts = item.Split('=', 2);
                    if (parts.Length == 2) query[Uri.UnescapeDataString(parts[0])] = Uri.UnescapeDataString(parts[1].Replace('+', ' '));
                }
            bool valid = callback?.AbsolutePath == new Uri(redirect).AbsolutePath && query.GetValueOrDefault("state") == state;
            string body = valid ? "Authorization received. Return to Fluent Steam Mac." : "This request does not match the active authorization session.";
            var reply = Encoding.UTF8.GetBytes($"HTTP/1.1 {(valid ? "200 OK" : "400 Bad Request")}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {Encoding.UTF8.GetByteCount(body)}\r\nConnection: close\r\n\r\n{body}");
            await stream.WriteAsync(reply, ct);
            if (!valid) continue;
            if (query.TryGetValue("error", out var error)) throw new Exception("Cloud authorization: " + error);
            code = query.GetValueOrDefault("code") ?? "";
            if (!string.IsNullOrEmpty(code)) break;
        }
        listener.Stop();
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var exchange = new Dictionary<string, string> { ["code"] = code, ["client_id"] = id, ["client_secret"] = secret, ["redirect_uri"] = redirect, ["grant_type"] = "authorization_code", ["code_verifier"] = verifier };
        if (!google) exchange["scope"] = scope;
        using var response = await http.PostAsync(endpoint, new FormUrlEncodedContent(exchange), ct);
        if (!response.IsSuccessStatusCode) throw new Exception("Cloud token exchange failed: HTTP " + (int)response.StatusCode);
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        string access = json.RootElement.GetProperty("access_token").GetString() ?? "";
        string refresh = json.RootElement.TryGetProperty("refresh_token", out var rt) ? rt.GetString() ?? "" : "";
        if (string.IsNullOrEmpty(refresh)) throw new Exception("Provider did not return a refresh token; grant offline access and retry");
        long lifetime = json.RootElement.TryGetProperty("expires_in", out var exp) ? exp.GetInt64() : 3600;
        return new { ok = true, cloudTokens = new Dictionary<string, string> { ["access_token"] = access, ["refresh_token"] = refresh, ["expires_at"] = (DateTimeOffset.UtcNow.ToUnixTimeSeconds() + lifetime).ToString() } };
    }
}

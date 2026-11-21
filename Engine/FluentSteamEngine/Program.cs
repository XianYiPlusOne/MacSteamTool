using System.Text.Json;
using SteamKit2;
using SteamKit2.Authentication;

// A separate, cancellable process owns each Steam network session. Secrets are
// exchanged only in files inside a private 0700 directory, never arguments/logs.
internal static class Program
{
    static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
    public static void Write(string path, object value)
    {
        var temporary = path + ".new";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value, Json));
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.Move(temporary, path, true);
    }
    static async Task<int> Main(string[] args)
    {
        if (args.Length != 2) return 2;
        try
        {
            var request = JsonSerializer.Deserialize<Request>(await File.ReadAllTextAsync(args[0]), Json) ?? throw new Exception("Invalid request");
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(request.Operation is "login" or "login-password" or "login-local" or "cloud-oauth" ? 180 : request.Operation is "patch-extract" or "library-import" or "tool-download" or "runtime-download" or "extract" ? 900 : 120));
            if (request.Operation.StartsWith("onlinefix-")) throw new NotSupportedException("Patch-based multiplayer has been removed. Use the bundled ConnectTool client.");
            if (request.Operation == "tool-download") { Write(args[1], await ToolPackages.Download(request, timeout.Token)); return 0; }
            if (request.Operation is "runtime-release" or "runtime-download") { Write(args[1], await RuntimeReleases.Run(request, timeout.Token)); return 0; }
            if (request.Operation is "patch-extract" or "library-import") { Write(args[1], await PatchArchive.Extract(request, timeout.Token)); return 0; }
            if (request.Operation == "cloud-oauth")
            {
                Write(args[1], await CloudOAuth.Authorize(request.Provider, args[1] + ".status", timeout.Token));
                return 0;
            }
            using var session = new Session();
            await session.Connect(timeout.Token);
            var response = await session.Execute(request, args[1] + ".status", timeout.Token);
            Write(args[1], response);
            return 0;
        }
        catch (Exception ex)
        {
            // SteamKit errors contain no request JSON or login tokens.
            Write(args[1], new { ok = false, error = ex is OperationCanceledException ? "Steam session timed out or was cancelled" : ex.Message });
            return 1;
        }
    }
}

internal sealed record Request(string Operation, string Account = "", string Token = "", uint AppID = 0, uint DepotID = 0, ulong ManifestID = 0, string DepotKey = "", string Destination = "", string Provider = "", string Query = "", string URL = "", string Referer = "", string Archive = "", string Password = "", string Mirror = "direct", bool IncludeDLC = true, string SteamPath = "", string SteamID = "", RuntimeRelease? RuntimeRelease = null, uint[]? DepotIDs = null, uint[]? AppIDs = null, uint[]? MissingDepotAppIDs = null);

internal sealed class Session : IDisposable
{
    readonly SteamClient client = new(SteamConfiguration.Create(builder => builder.WithProtocolTypes(ProtocolTypes.WebSocket)));
    readonly CallbackManager callbacks;
    readonly SteamUser user;
    readonly SteamApps apps;
    readonly CancellationTokenSource stop = new();
    readonly TaskCompletionSource connected = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly TaskCompletionSource<EResult> loggedOn = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly TaskCompletionSource<SteamApps.LicenseListCallback> licenses = new(TaskCreationOptions.RunContinuationsAsynchronously);
    Task? pump;
    public Session()
    {
        callbacks = new(client); user = client.GetHandler<SteamUser>()!; apps = client.GetHandler<SteamApps>()!;
        callbacks.Subscribe<SteamClient.ConnectedCallback>(_ => connected.TrySetResult());
        callbacks.Subscribe<SteamClient.DisconnectedCallback>(_ => { connected.TrySetException(new Exception("Steam disconnected")); loggedOn.TrySetException(new Exception("Steam disconnected")); });
        callbacks.Subscribe<SteamUser.LoggedOnCallback>(x => loggedOn.TrySetResult(x.Result));
        callbacks.Subscribe<SteamApps.LicenseListCallback>(x => licenses.TrySetResult(x));
    }
    public async Task Connect(CancellationToken ct)
    {
        pump = Task.Run(() => { while (!stop.IsCancellationRequested) callbacks.RunWaitCallbacks(TimeSpan.FromMilliseconds(100)); });
        client.Connect(); await connected.Task.WaitAsync(TimeSpan.FromSeconds(30), ct);
    }
    async Task LogOn(Request r, CancellationToken ct)
    {
        if (r.Operation == "anonymous") user.LogOnAnonymous();
        else
        {
            if (string.IsNullOrWhiteSpace(r.Account) || string.IsNullOrWhiteSpace(r.Token)) throw new Exception("Sign in with Steam Guard first");
            user.LogOn(new SteamUser.LogOnDetails { Username = r.Account, AccessToken = r.Token, ShouldRememberPassword = true });
        }
        var result = await loggedOn.Task.WaitAsync(TimeSpan.FromSeconds(30), ct);
        if (result != EResult.OK) throw new Exception("Steam login: " + result);
    }
    public async Task<object> Execute(Request r, string status, CancellationToken ct)
    {
        if (r.Operation == "login")
        {
            var auth = await client.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails { IsPersistentSession = true, DeviceFriendlyName = "Fluent Steam Mac" });
            void Update() => Program.Write(status, new { state = "qr", url = auth.ChallengeURL });
            auth.ChallengeURLChanged = Update; Update();
            var result = await auth.PollingWaitForResultAsync(ct);
            return new { ok = true, account = result.AccountName, token = result.RefreshToken };
        }
        if (r.Operation == "login-password") {
            var auth = await client.Authentication.BeginAuthSessionViaCredentialsAsync(new AuthSessionDetails {
                Username = r.Account, Password = r.Password, IsPersistentSession = true,
                DeviceFriendlyName = "Fluent Steam Mac", Authenticator = new LoginAuthenticator(status, ct)
            });
            var result = await auth.PollingWaitForResultAsync(ct);
            await LogOn(r with { Token = result.RefreshToken, Account = result.AccountName }, ct);
            return new { ok = true, account = result.AccountName, token = result.RefreshToken };
        }
        if (r.Operation == "login-local") {
            var token = LocalSteamLogin.Read(r);
            await LogOn(r with { Token = token }, ct);
            return new { ok = true, account = r.Account, token };
        }
        await LogOn(r, ct);
        if (r.Operation == "generation-metadata") return await GenerationMetadata(r, ct);
        if (r.Operation == "anonymous") return new { ok = true, protocol = "SteamKit2 3.4.0", connected = true };
        if (r.Operation == "library")
        {
            var ids = await OwnedIDs(ct);
            var games = new List<object>();
            foreach (var batch in ids.Order().Chunk(100))
            {
                var tokens = await apps.PICSGetAccessTokens(batch, []).ToTask().WaitAsync(ct);
                var info = await apps.PICSGetProductInfo(batch.Select(id => new SteamApps.PICSRequest(id, tokens.AppTokens.GetValueOrDefault(id))), []).ToTask().WaitAsync(ct);
                foreach (var callback in (info.Results ?? throw new Exception("Incomplete Steam metadata")))
                    foreach (var entry in callback.Apps)
                        games.Add(new { id = entry.Key, name = entry.Value.KeyValues["common"]["name"].AsString() ?? entry.Key.ToString(), type = entry.Value.KeyValues["common"]["type"].AsString() ?? "" });
            }
            return new { ok = true, games };
        }
        if (r.AppID == 0) throw new Exception("AppID is required");
        if (r.Operation == "extract")
        {
            var owned = await OwnedIDs(ct);
            return await OwnedExtraction.Run(r.AppID, r.IncludeDLC, owned, async id => {
                var tokens = await apps.PICSGetAccessTokens([id], []).ToTask().WaitAsync(ct);
                var token = tokens.AppTokens.GetValueOrDefault(id);
                var info = await apps.PICSGetProductInfo([new SteamApps.PICSRequest(id, token)], []).ToTask().WaitAsync(ct);
                var app = (info.Results ?? throw new Exception("Incomplete Steam metadata")).SelectMany(x => x.Apps).FirstOrDefault(x => x.Key == id).Value ?? throw new Exception("Steam returned no app metadata");
                return OwnedExtraction.Parse(id, app.KeyValues, token);
            }, async (depot, source) => {
                var response = await apps.GetDepotDecryptionKey(depot, source).ToTask().WaitAsync(ct);
                return (response.Result == EResult.OK ? Convert.ToHexString(response.DepotKey).ToLowerInvariant() : "", response.Result.ToString());
            }, ct, r.DepotIDs is { Length: > 0 } ? r.DepotIDs.ToHashSet() : null);
        }

        if (r.Operation == "manifest")
        {
            if (r.DepotID == 0 || r.ManifestID == 0 || !Path.IsPathFullyQualified(r.Destination)) throw new Exception("Invalid manifest destination");
            var content = client.GetHandler<SteamContent>()!;
            var code = await content.GetManifestRequestCode(r.DepotID, r.AppID, r.ManifestID).WaitAsync(ct);
            if (code == 0) throw new Exception("This account cannot download the requested manifest");
            var servers = await content.GetServersForSteamPipe();
            using var cdn = new SteamKit2.CDN.Client(client);
            Exception? last = null;
            foreach (var server in servers.Take(4))
            {
                try
                {
                    string? auth = null;
                    try { auth = (await content.GetCDNAuthToken(r.AppID, r.DepotID, server.Host ?? "").WaitAsync(ct)).Token; } catch { }
                    var key = string.IsNullOrEmpty(r.DepotKey) ? null : Convert.FromHexString(r.DepotKey);
                    var manifest = await cdn.DownloadManifestAsync(r.DepotID, r.ManifestID, code, server, key, null, auth).WaitAsync(ct);
                    manifest.SaveToFile(r.Destination);
                    return new { ok = true, path = r.Destination };
                }
                catch (Exception ex) { last = ex; }
            }
            throw last ?? new Exception("Steam returned no content servers");
        }
        throw new Exception("Unknown operation");
    }
    async Task<object> GenerationMetadata(Request request, CancellationToken ct)
    {
        var ids = request.AppIDs?.Distinct().ToArray() ?? [];
        if (ids.Length is 0 or > 100 || ids.Contains(0u)) throw new ArgumentException("Invalid generation AppIDs");
        var issued = await apps.PICSGetAccessTokens(ids, []).ToTask().WaitAsync(ct);
        var tokens = ids.Where(id => issued.AppTokens.GetValueOrDefault(id) != 0)
            .ToDictionary(id => id, id => issued.AppTokens[id]);
        var missing = (request.MissingDepotAppIDs ?? []).Intersect(tokens.Keys).ToArray();
        var metadata = new Dictionary<uint, string>();
        if (missing.Length > 0)
        {
            var requests = missing.Select(id => new SteamApps.PICSRequest(id, tokens[id]));
            try
            {
                var response = await apps.PICSGetProductInfo(requests, []).ToTask().WaitAsync(TimeSpan.FromSeconds(30), ct);
                foreach (var callback in response.Results ?? Enumerable.Empty<SteamApps.PICSProductInfoCallback>())
                foreach (var (id, app) in callback.Apps)
                {
                    if (!app.MissingToken && missing.Contains(id))
                        metadata[id] = ProductMetadataJson(app.KeyValues);
                }
            }
            // The app tokens have already been issued. A missing product response
            // is returned as null so the caller can retain them and the public data.
            catch (Exception ex) when (!ct.IsCancellationRequested && ex is TimeoutException or AsyncJobFailedException or OperationCanceledException) { }
        }
        var generationApps = tokens.Select(pair => new {
            id = pair.Key, accessToken = pair.Value.ToString(System.Globalization.CultureInfo.InvariantCulture),
            productInfo = metadata.GetValueOrDefault(pair.Key)
        });
        return new { ok = true, generationApps };
    }

    internal static string ProductMetadataJson(KeyValue app)
    {
        // Keep the SteamCMD shape so both sources share the Swift depot/branch parser.
        static object Value(KeyValue node)
        {
            if (node.Value != null) return node.Value;
            var children = new Dictionary<string, object>();
            foreach (var child in node.Children)
                if (child.Name != null) children[child.Name] = Value(child);
            return children;
        }
        var fields = new Dictionary<string, object>();
        foreach (var field in app.Children)
            if (field.Name is "common" or "extended" or "depots") fields[field.Name] = Value(field);
        return JsonSerializer.Serialize(fields);
    }

    async Task<HashSet<uint>> OwnedIDs(CancellationToken ct)
    {
        var list = await licenses.Task.WaitAsync(TimeSpan.FromSeconds(30), ct);
        if (list.Result != EResult.OK) throw new Exception("Steam licenses: " + list.Result);
        var packageRequests = list.LicenseList.Where(x => !x.LicenseFlags.HasFlag(ELicenseFlags.Expired)).Select(x => new SteamApps.PICSRequest(x.PackageID, x.AccessToken)).ToArray();
        var ids = new HashSet<uint>();
        foreach (var batch in packageRequests.Chunk(100))
        {
            var info = await apps.PICSGetProductInfo([], batch).ToTask().WaitAsync(ct);
            foreach (var callback in (info.Results ?? throw new Exception("Incomplete Steam metadata")))
                foreach (var package in callback.Packages.Values)
                foreach (var child in package.KeyValues["appids"].Children)
                    if (uint.TryParse(child.Value, out var id)) ids.Add(id);
        }
        return ids;
    }
    public void Dispose()
    {
        user.LogOff(); client.Disconnect(); stop.Cancel();
        try { pump?.Wait(TimeSpan.FromSeconds(1)); } catch { }
        stop.Dispose();
    }
}

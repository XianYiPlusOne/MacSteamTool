using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using HtmlAgilityPack;

internal static class ToolPackages
{
    private const string GoldbergRepository = "https://github.com/Detanup01/gbe_fork";
    private const string GoldbergFilename = "emu-win-release-vs22.7z";
    private static readonly string[] Mirrors = ["https://gh-proxy.com/", "https://ghfast.top/", "https://gh-proxy.org/"];
    // Taken from the official release digest. Also available on a fresh install without GitHub metadata.
    private static readonly ToolRelease PinnedGoldberg = new("release-2026_09_27", "300186c34f49a9ea75b33ce2af299267cc1dad0225cf45e81a229578d4e11c85");

    private static bool ValidTag(string tag) => Regex.IsMatch(tag, @"\A[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}\z");
    private static string GoldbergURL(string tag) => $"{GoldbergRepository}/releases/download/{tag}/{GoldbergFilename}";

    private static ToolRelease ValidateGoldberg(string tag, string url, string digest)
    {
        if (!ValidTag(tag) ||
            url != GoldbergURL(tag) || !Regex.IsMatch(digest, @"\Asha256:[0-9a-f]{64}\z"))
            throw new InvalidDataException("Invalid official Goldberg asset or SHA-256");
        return new ToolRelease(tag, digest[7..]);
    }

    private static async Task<string> OfficialText(HttpClient http, string url, CancellationToken ct)
    {
        using var response = await http.GetAsync(url, ct);
        response.EnsureSuccessStatusCode();
        if (response.RequestMessage?.RequestUri?.AbsoluteUri != url) throw new InvalidDataException("Unexpected GitHub metadata redirect");
        return await response.Content.ReadAsStringAsync(ct);
    }

    private static async Task<ToolRelease> LatestGoldberg(HttpClient http, CancellationToken ct)
    {
        try {
            using var json = JsonDocument.Parse(await OfficialText(http, "https://api.github.com/repos/Detanup01/gbe_fork/releases/latest", ct));
            var release = json.RootElement;
            var asset = release.GetProperty("assets").EnumerateArray().Single(a => a.GetProperty("name").GetString() == GoldbergFilename);
            return ValidateGoldberg(release.GetProperty("tag_name").GetString() ?? "", asset.GetProperty("browser_download_url").GetString() ?? "", asset.GetProperty("digest").GetString() ?? "");
        } catch (Exception) when (!ct.IsCancellationRequested) {
            // The public API may be unavailable or rate-limited while the release page still works.
            using var page = await http.GetAsync(GoldbergRepository + "/releases/latest", HttpCompletionOption.ResponseHeadersRead, ct);
            page.EnsureSuccessStatusCode();
            var prefix = GoldbergRepository + "/releases/tag/";
            var resolved = page.RequestMessage?.RequestUri?.AbsoluteUri ?? "";
            if (!resolved.StartsWith(prefix, StringComparison.Ordinal)) throw new InvalidDataException("Unexpected Goldberg release location");
            var tag = resolved[prefix.Length..];
            if (!ValidTag(tag)) throw new InvalidDataException("Invalid release tag");
            var doc = new HtmlDocument();
            doc.LoadHtml(await OfficialText(http, GoldbergRepository + "/releases/expanded_assets/" + tag, ct));
            var path = new Uri(GoldbergURL(tag)).AbsolutePath;
            if (doc.DocumentNode.SelectSingleNode($"//a[@href='{path}']") == null) throw new InvalidDataException("Missing official Goldberg asset");
            var digest = doc.DocumentNode.SelectSingleNode($"//clipboard-copy[@aria-label='Copy to clipboard digest for {GoldbergFilename}']")?.GetAttributeValue("value", "") ?? "";
            return ValidateGoldberg(tag, GoldbergURL(tag), digest);
        }
    }

    public static async Task<object> Download(Request r, CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20), MaxResponseContentBufferSize = 4 * 1024 * 1024 };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("MacSteamTool/0.1");
        return await Download(r, http, ct);
    }

    internal static async Task<object> Download(Request r, HttpClient http, CancellationToken ct)
    {
        if (!Path.IsPathFullyQualified(r.Destination) || Path.Exists(r.Destination)) throw new Exception("Tool package destination must be a new directory");
        var warnings = new List<string>();
        string url, hash, version, filename;
        if (r.Provider == "steamless") {
            version = "3.1.0.5"; filename = "Steamless.v3.1.0.5.zip";
            url = "https://github.com/atom0s/Steamless/releases/download/v3.1.0.5/Steamless.v3.1.0.5.-.by.atom0s.zip";
            hash = "e3e2d22e098ff3fb359b2876aa2bed9596f0501e6ff588cbffae90a76d2dc4f5";
        } else if (r.Provider == "goldberg") {
            ToolRelease release;
            try { release = await LatestGoldberg(http, ct); }
            catch (Exception) when (!ct.IsCancellationRequested) {
                release = r.CachedGoldberg ?? PinnedGoldberg;
                ValidateGoldberg(release.Version, GoldbergURL(release.Version), "sha256:" + release.SHA256);
                warnings.Add($"无法查询最新版本，使用已校验版本 {release.Version} / Latest release unavailable; using verified version {release.Version}");
            }
            version = release.Version; filename = GoldbergFilename; hash = release.SHA256; url = GoldbergURL(version);
        } else throw new Exception("Unknown tool provider");
        var stage = Path.Combine(Path.GetDirectoryName(r.Destination)!, ".tool-download-" + Guid.NewGuid().ToString("N"));
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(stage);
        else Directory.CreateDirectory(stage, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try {
            var archive = Path.Combine(stage, filename);
            var preferred = Mirrors.Contains(r.Mirror) ? r.Mirror : "";
            var candidates = new[] { preferred, "" }.Concat(Mirrors).Distinct().Select(source => source + url);
            Exception? lastError = null;
            foreach (var candidate in candidates) {
                try {
                    using var attempt = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    var idleTimeout = TimeSpan.FromSeconds(30);
                    attempt.CancelAfter(idleTimeout);
                    var token = attempt.Token;
                    using var response = await http.GetAsync(candidate, HttpCompletionOption.ResponseHeadersRead, token);
                    response.EnsureSuccessStatusCode();
                    if (response.RequestMessage?.RequestUri?.Scheme != "https" || response.Content.Headers.ContentLength > 256L * 1024 * 1024) throw new Exception("Tool archive transport or size rejected");
                    await using (var input = await response.Content.ReadAsStreamAsync(token))
                    await using (var output = new FileStream(archive, FileMode.CreateNew, FileAccess.Write)) {
                        var buffer = new byte[65536]; long total = 0; int count;
                        while ((count = await input.ReadAsync(buffer, token)) > 0) {
                            attempt.CancelAfter(idleTimeout);
                            total += count; if (total > 256L * 1024 * 1024) throw new Exception("Tool archive exceeds 256 MiB");
                            await output.WriteAsync(buffer.AsMemory(0, count), token);
                        }
                    }
                    await using (var stream = File.OpenRead(archive)) {
                        if (Convert.ToHexString(await SHA256.HashDataAsync(stream, ct)).ToLowerInvariant() != hash) throw new Exception("Tool archive SHA-256 mismatch");
                    }
                    lastError = null; break;
                } catch (Exception e) when (!ct.IsCancellationRequested) { lastError = e; if (File.Exists(archive)) File.Delete(archive); }
            }
            if (lastError != null) throw lastError;
            var payload = Path.Combine(stage, "payload");
            await PatchArchive.Extract(r with { Archive = archive, Destination = payload, Password = "" }, ct);
            var files = new Dictionary<string, string>();
            foreach (var file in Directory.GetFiles(payload, "*", SearchOption.AllDirectories)) {
                await using var stream = File.OpenRead(file); files[Path.GetRelativePath(payload, file).Replace('\\', '/')] = Convert.ToHexString(await SHA256.HashDataAsync(stream, ct)).ToLowerInvariant();
            }
            Program.Write(Path.Combine(stage, "tool.json"), new { provider = r.Provider, version, source = url, archiveSHA256 = hash, files });
            ct.ThrowIfCancellationRequested();
            Directory.Move(stage, r.Destination);
            return new { ok = true, path = r.Destination, warnings };
        } catch { Directory.Delete(stage, true); throw; }
    }
}

internal sealed record ToolRelease(string Version, string SHA256);

using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using HtmlAgilityPack;

internal static class ToolPackages
{
    public static async Task<object> Download(Request r, CancellationToken ct)
    {
        if (!Path.IsPathFullyQualified(r.Destination) || Path.Exists(r.Destination)) throw new Exception("Tool package destination must be a new directory");
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("FluentSteamMac/0.1");
        string url, hash, version, filename;
        if (r.Provider == "steamless") {
            version = "3.1.0.5"; filename = "Steamless.v3.1.0.5.zip";
            url = "https://github.com/atom0s/Steamless/releases/download/v3.1.0.5/Steamless.v3.1.0.5.-.by.atom0s.zip";
            hash = "e3e2d22e098ff3fb359b2876aa2bed9596f0501e6ff588cbffae90a76d2dc4f5";
        } else if (r.Provider == "goldberg") {
            using var latest = await http.GetAsync("https://github.com/Detanup01/gbe_fork/releases/latest", HttpCompletionOption.ResponseHeadersRead, ct);
            latest.EnsureSuccessStatusCode();
            var resolved = latest.RequestMessage!.RequestUri!;
            if (resolved.Host != "github.com" || !resolved.AbsolutePath.StartsWith("/Detanup01/gbe_fork/releases/tag/")) throw new Exception("Unexpected Goldberg release location");
            version = resolved.Segments.Last();
            if (!Regex.IsMatch(version, "^[A-Za-z0-9_.-]{1,100}$")) throw new Exception("Invalid release tag");
            var doc = new HtmlDocument(); doc.LoadHtml(await http.GetStringAsync("https://github.com/Detanup01/gbe_fork/releases/expanded_assets/" + version, ct));
            filename = "emu-win-release-vs22.7z";
            var link = doc.DocumentNode.SelectSingleNode("//a[contains(@href,'/" + filename + "')]") ?? throw new Exception("This release has no supported Windows emulator package");
            url = new Uri(new Uri("https://github.com"), link.GetAttributeValue("href", "")).AbsoluteUri;
            if (!url.StartsWith("https://github.com/Detanup01/gbe_fork/releases/download/" + version + "/")) throw new Exception("Unexpected release asset");
            var digest = doc.DocumentNode.SelectSingleNode("//clipboard-copy[@aria-label='Copy to clipboard digest for " + filename + "']")?.GetAttributeValue("value", "") ?? "";
            if (!Regex.IsMatch(digest, "^sha256:[0-9a-f]{64}$")) throw new Exception("GitHub did not provide an asset SHA-256; download refused");
            hash = digest[7..];
        } else throw new Exception("Unknown tool provider");
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(r.Destination);
        else Directory.CreateDirectory(r.Destination, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try {
            var archive = Path.Combine(r.Destination, filename);
            var mirrors = new[] { "https://gh-proxy.com/", "https://ghfast.top/", "https://gh-proxy.org/" };
            var candidates = mirrors.Contains(r.Mirror) ? new[] { r.Mirror + url, url } : new[] { url };
            Exception? lastError = null;
            foreach (var candidate in candidates) {
                try {
                    using var response = await http.GetAsync(candidate, HttpCompletionOption.ResponseHeadersRead, ct);
                    response.EnsureSuccessStatusCode();
                    if (response.RequestMessage?.RequestUri?.Scheme != "https" || response.Content.Headers.ContentLength > 256L * 1024 * 1024) throw new Exception("Tool archive transport or size rejected");
                    await using (var input = await response.Content.ReadAsStreamAsync(ct))
                    await using (var output = new FileStream(archive, FileMode.CreateNew, FileAccess.Write)) {
                        var buffer = new byte[65536]; long total = 0; int count;
                        while ((count = await input.ReadAsync(buffer, ct)) > 0) {
                            total += count; if (total > 256L * 1024 * 1024) throw new Exception("Tool archive exceeds 256 MiB");
                            await output.WriteAsync(buffer.AsMemory(0, count), ct);
                        }
                    }
                    await using (var stream = File.OpenRead(archive)) {
                        if (Convert.ToHexString(await SHA256.HashDataAsync(stream, ct)).ToLowerInvariant() != hash) throw new Exception("Tool archive SHA-256 mismatch");
                    }
                    lastError = null; break;
                } catch (Exception e) when (!ct.IsCancellationRequested) { lastError = e; if (File.Exists(archive)) File.Delete(archive); }
            }
            if (lastError != null) throw lastError;
            var payload = Path.Combine(r.Destination, "payload");
            await PatchArchive.Extract(r with { Archive = archive, Destination = payload, Password = "" }, ct);
            var files = new Dictionary<string, string>();
            foreach (var file in Directory.GetFiles(payload, "*", SearchOption.AllDirectories)) {
                await using var stream = File.OpenRead(file); files[Path.GetRelativePath(payload, file).Replace('\\', '/')] = Convert.ToHexString(await SHA256.HashDataAsync(stream, ct)).ToLowerInvariant();
            }
            Program.Write(Path.Combine(r.Destination, "tool.json"), new { provider = r.Provider, version, source = url, archiveSHA256 = hash, files });
            return new { ok = true, path = r.Destination };
        } catch { Directory.Delete(r.Destination, true); throw; }
    }
}

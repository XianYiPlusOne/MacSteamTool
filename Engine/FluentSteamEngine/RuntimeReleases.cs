using System.Security.Cryptography;
using System.Text.RegularExpressions;
using HtmlAgilityPack;
using System.Text.Json.Serialization;

internal sealed record RuntimeRelease(string Provider, string Tag, string Version, string AssetName, string URL, [property: JsonPropertyName("sha256")] string SHA256, string ReleaseURL);
internal static class RuntimeReleases
{
    internal static string Repository(string provider) => provider switch {
        "macsteam" => "crghofficial/macsteam", "notproton" => "NotProtonNot/NotProton", _ => throw new Exception("Unknown runtime provider")
    };
    internal static void Validate(RuntimeRelease r)
    {
        var repo = Repository(r.Provider);
        if (!Regex.IsMatch(r.Tag, "^v?[0-9]+(?:\\.[0-9]+){1,3}$") || r.Version != r.Tag.TrimStart('v') ||
            r.AssetName != (r.Provider == "macsteam" ? $"macSteam-{r.Version}.dmg" : "NotProton.zip") ||
            r.URL != $"https://github.com/{repo}/releases/download/{r.Tag}/{r.AssetName}" ||
            r.ReleaseURL != $"https://github.com/{repo}/releases/tag/{r.Tag}" || !Regex.IsMatch(r.SHA256, "^[0-9a-f]{64}$"))
            throw new Exception("Unexpected official runtime release metadata");
    }
    internal static RuntimeRelease Parse(string provider, Uri location, string html)
    {
        var repo = Repository(provider); var prefix = $"https://github.com/{repo}/releases/tag/";
        if (!location.AbsoluteUri.StartsWith(prefix, StringComparison.Ordinal)) throw new Exception("Unexpected official release location");
        var tag = location.AbsoluteUri[prefix.Length..];
        if (!Regex.IsMatch(tag, "^v?[0-9]+(?:\\.[0-9]+){1,3}$")) throw new Exception("Unsupported release tag");
        var version = tag.TrimStart('v'); var filename = provider == "macsteam" ? $"macSteam-{version}.dmg" : "NotProton.zip";
        var path = $"/{repo}/releases/download/{tag}/{filename}";
        var doc = new HtmlDocument(); doc.LoadHtml(html);
        var link = doc.DocumentNode.SelectNodes("//a[@href]")?.FirstOrDefault(x => x.GetAttributeValue("href", "") == path)
            ?? throw new Exception("Official release has no supported runtime package");
        var digest = doc.DocumentNode.SelectSingleNode("//clipboard-copy[@aria-label='Copy to clipboard digest for " + filename + "']")?.GetAttributeValue("value", "") ?? "";
        if (!Regex.IsMatch(digest, "^sha256:[0-9a-f]{64}$")) throw new Exception("GitHub asset SHA-256 is missing; download refused");
        var release = new RuntimeRelease(provider, tag, version, filename, "https://github.com" + path, digest[7..], prefix + tag);
        Validate(release); return release;
    }
    public static async Task<object> Run(Request r, CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("FluentSteamMac/0.2");
        if (r.Operation == "runtime-release") {
            var repo = Repository(r.Provider);
            using var latest = await http.GetAsync($"https://github.com/{repo}/releases/latest", HttpCompletionOption.ResponseHeadersRead, ct);
            latest.EnsureSuccessStatusCode(); var location = latest.RequestMessage!.RequestUri!;
            var prefix = $"https://github.com/{repo}/releases/tag/";
            if (!location.AbsoluteUri.StartsWith(prefix, StringComparison.Ordinal)) throw new Exception("Unexpected official release redirect");
            var tag = location.AbsoluteUri[prefix.Length..];
            if (!Regex.IsMatch(tag, "^v?[0-9]+(?:\\.[0-9]+){1,3}$")) throw new Exception("Unsupported release tag");
            var html = await http.GetStringAsync($"https://github.com/{repo}/releases/expanded_assets/{tag}", ct);
            if (html.Length > 2 * 1024 * 1024) throw new Exception("Release metadata exceeds limit");
            return new { ok = true, runtimeRelease = Parse(r.Provider, location, html) };
        }
        var release = r.RuntimeRelease ?? throw new Exception("Release metadata required"); Validate(release);
        if (!Path.IsPathFullyQualified(r.Destination) || Path.Exists(r.Destination)) throw new Exception("Download requires a new absolute destination");
        if (OperatingSystem.IsWindows()) throw new Exception("Official macOS runtime download requires macOS or Unix");
        Directory.CreateDirectory(r.Destination, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try {
            var file = Path.Combine(r.Destination, release.AssetName);
            using var response = await http.GetAsync(release.URL, HttpCompletionOption.ResponseHeadersRead, ct); response.EnsureSuccessStatusCode();
            var resolved = response.RequestMessage!.RequestUri!;
            if (resolved.Scheme != "https" || !new[] { "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com" }.Contains(resolved.Host) || response.Content.Headers.ContentLength > 256L * 1024 * 1024)
                throw new Exception("Runtime download redirect or size rejected");
            await using (var input = await response.Content.ReadAsStreamAsync(ct))
            await using (var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write)) {
                var buffer = new byte[65536]; long total = 0; int count;
                while ((count = await input.ReadAsync(buffer, ct)) > 0) { total += count; if (total > 256L * 1024 * 1024) throw new Exception("Runtime archive exceeds 256 MiB"); await output.WriteAsync(buffer.AsMemory(0, count), ct); }
            }
            await using (var stream = File.OpenRead(file)) if (Convert.ToHexString(await SHA256.HashDataAsync(stream, ct)).ToLowerInvariant() != release.SHA256) throw new Exception("Runtime archive SHA-256 mismatch");
            return new { ok = true, path = file, runtimeRelease = release };
        } catch { Directory.Delete(r.Destination, true); throw; }
    }
}

using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;

internal static class ToolPackageTests
{
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            var response = respond(request);
            response.RequestMessage ??= request;
            return Task.FromResult(response);
        }
    }

    public static async Task Run()
    {
        const string filename = "emu-win-release-vs22.7z";
        const string tag = "fixture-1";
        const string direct = $"https://github.com/Detanup01/gbe_fork/releases/download/{tag}/{filename}";
        const string first = "https://gh-proxy.com/", second = "https://ghfast.top/", third = "https://gh-proxy.org/";
        using var bytes = new MemoryStream();
        using (var zip = new ZipArchive(bytes, ZipArchiveMode.Create, true)) {
            using var entry = new StreamWriter(zip.CreateEntry("fixture.txt").Open());
            entry.Write("verified");
        }
        var archive = bytes.ToArray();
        var hash = Convert.ToHexString(SHA256.HashData(archive)).ToLowerInvariant();
        var metadata = JsonSerializer.Serialize(new { tag_name = tag, assets = new[] { new { name = filename, browser_download_url = direct, digest = "sha256:" + hash } } });

        async Task Exercise(string preference, string[] expected, bool metadataUnavailable = false, bool allBad = false, bool cancel = false, bool coldInstall = false)
        {
            var folder = Directory.CreateTempSubdirectory("tool-route-");
            var destination = Path.Combine(folder.FullName, "package");
            try {
                using var stop = new CancellationTokenSource();
                var assets = new List<string>();
                using var http = new HttpClient(new Handler(request => {
                    var uri = request.RequestUri!;
                    if (uri.AbsolutePath.EndsWith("/releases/latest"))
                        return metadataUnavailable ? new(HttpStatusCode.ServiceUnavailable) : new(HttpStatusCode.OK) { Content = new StringContent(metadata) };
                    assets.Add(uri.AbsoluteUri);
                    if (cancel) { stop.Cancel(); stop.Token.ThrowIfCancellationRequested(); }
                    if (assets.Count == 1 && !allBad) return new(HttpStatusCode.BadGateway);
                    var data = !allBad && assets.Count == expected.Length ? archive : new byte[] { 0xff };
                    return new(HttpStatusCode.OK) { Content = new ByteArrayContent(data) };
                }));
                var req = new Request("tool-download", Provider: "goldberg", Destination: destination, Mirror: preference,
                    CachedGoldberg: metadataUnavailable && !coldInstall ? new ToolRelease(tag, hash) : null);
                try {
                    var result = JsonSerializer.SerializeToElement(await ToolPackages.Download(req, http, stop.Token));
                    if (allBad || cancel || File.ReadAllText(Path.Combine(destination, "payload", "fixture.txt")) != "verified" ||
                        result.GetProperty("warnings").GetArrayLength() != (metadataUnavailable ? 1 : 0))
                        throw new Exception("Unexpected package download result");
                } catch (OperationCanceledException) when (cancel) {
                } catch (Exception e) when (allBad && e.Message.Contains("SHA-256 mismatch")) {
                }
                if (!assets.SequenceEqual(expected) || (allBad || cancel) && folder.EnumerateFileSystemInfos().Any())
                    throw new Exception("Unexpected route or partial files: " + string.Join(", ", assets));
            } finally { folder.Delete(true); }
        }

        await Exercise("direct", [direct, first + direct]);                     // direct HTTP failure
        await Exercise(second, [second + direct, direct]);                      // mirror HTTP failure
        await Exercise(second, [second + direct, direct, first + direct], true); // cache, then corrupt download
        await Exercise("direct", [direct, first + direct, second + direct, third + direct], allBad: true);
        const string pinned = $"https://github.com/Detanup01/gbe_fork/releases/download/release-2026_09_27/{filename}";
        await Exercise("direct", [pinned, first + pinned, second + pinned, third + pinned], metadataUnavailable: true, allBad: true, coldInstall: true);
        await Exercise("direct", [direct], cancel: true);
        Console.WriteLine("PASS: tool download preference, two-way failover, cached release without metadata, checksum retry, all-sources failure cleanup and cancellation");
    }
}

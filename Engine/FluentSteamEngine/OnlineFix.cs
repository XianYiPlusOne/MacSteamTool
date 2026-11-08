// Independent macOS adaptation of Fluent-Steam-Lua's zlib-licensed OnlineFixService.
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using HtmlAgilityPack;

internal sealed class OnlineFix : IDisposable
{
    readonly HttpClient http = new(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(90) };
    DateTime lastRequest = DateTime.MinValue;
    public OnlineFix()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36");
        http.DefaultRequestHeaders.AcceptLanguage.ParseAdd("ru-RU,ru;q=0.9,en;q=0.8");
    }
    public void Dispose() => http.Dispose();
    static Uri Validate(string url)
    {
        var uri = new Uri(url);
        if (uri.Scheme != "https" || uri.Host != "online-fix.me" || !string.IsNullOrEmpty(uri.UserInfo) || uri.Port is not (443 or 2053)) throw new Exception("Only official HTTPS OnlineFix URLs are accepted");
        return uri;
    }
    async Task<HttpResponseMessage> Get(string url, CancellationToken ct, string? referer = null)
    {
        var uri = Validate(url);
        for (int redirects = 0; redirects < 5; redirects++)
        {
            var wait = TimeSpan.FromSeconds(3) - (DateTime.UtcNow - lastRequest);
            if (wait > TimeSpan.Zero) await Task.Delay(wait, ct);
            lastRequest = DateTime.UtcNow;
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            if (referer != null) request.Headers.Referrer = Validate(referer);
            var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if ((int)response.StatusCode is >= 300 and <= 399 && response.Headers.Location is { } location)
            {
                uri = Validate(new Uri(uri, location).AbsoluteUri); response.Dispose(); continue;
            }
            if (!response.IsSuccessStatusCode) { var status = (int)response.StatusCode; response.Dispose(); throw new Exception($"OnlineFix HTTP {status}; open the source page to check service access"); }
            return response;
        }
        throw new Exception("Too many redirects");
    }
    async Task<HtmlDocument> Document(string url, CancellationToken ct)
    {
        using var response = await Get(url, ct);
        if (response.Content.Headers.ContentLength > 4 * 1024 * 1024) throw new Exception("Page exceeds size limit");
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var memory = new MemoryStream(); var buffer = new byte[65536]; int count;
        while ((count = await stream.ReadAsync(buffer, ct)) > 0) { if (memory.Length + count > 4 * 1024 * 1024) throw new Exception("Page exceeds size limit"); memory.Write(buffer, 0, count); }
        var doc = new HtmlDocument(); doc.LoadHtml(Encoding.GetEncoding("windows-1251").GetString(memory.ToArray())); return doc;
    }
    internal static string Plain(HtmlNode? node) => HtmlEntity.DeEntitize(node?.InnerText ?? "").Trim();
    internal static object[] ParseSearch(HtmlDocument doc)
    {
        return (doc.DocumentNode.SelectNodes("//div[contains(@class,'news-search')]//a[@class='big-link']")?.ToArray() ?? []).Select(a => {
            var title = Plain(a.ParentNode.SelectSingleNode(".//h2[contains(@class,'title')]"));
            var url = new Uri(new Uri("https://online-fix.me"), HtmlEntity.DeEntitize(a.GetAttributeValue("href", ""))).AbsoluteUri;
            Validate(url); return new { title, url, version = Plain(a.ParentNode.SelectSingleNode(".//div[@class='edit']")) };
        }).Where(x => x.title.Length > 0).Cast<object>().ToArray();
    }
    async Task<object[]> Files(string directory, CancellationToken ct)
    {
        if (!directory.EndsWith('/')) directory += "/";
        var doc = await Document(directory, ct);
        return (doc.DocumentNode.SelectNodes("//pre/a[@href]")?.ToArray() ?? []).Where(a => a.GetAttributeValue("href", "") is not ("../" or "") && !a.GetAttributeValue("href", "").EndsWith('/')).Select(a => {
            var url = Validate(new Uri(new Uri(directory), HtmlEntity.DeEntitize(a.GetAttributeValue("href", ""))).AbsoluteUri);
            return (object)new { name = Uri.UnescapeDataString(url.Segments.Last()), url = url.AbsoluteUri, info = Plain(a.NextSibling), directory };
        }).ToArray();
    }
    public async Task<object> Execute(Request r, CancellationToken ct)
    {
        if (r.Operation == "onlinefix-search")
        {
            var all = new List<object>(); var query = r.Query.Trim();
            if (query.Length is < 2 or > 200) throw new Exception("Enter a game title (2–200 characters)");
            foreach (var variant in new[] { query, query.ToLowerInvariant(), query.ToUpperInvariant() }.Distinct())
                all.AddRange(ParseSearch(await Document("https://online-fix.me/index.php?do=search&subaction=search&story=" + Uri.EscapeDataString(variant), ct)));
            return new { ok = true, fixes = all.DistinctBy(x => System.Text.Json.JsonSerializer.Serialize(x)).ToArray() };
        }
        if (r.Operation == "onlinefix-detail")
        {
            var doc = await Document(r.URL, ct);
            var link = doc.DocumentNode.SelectNodes("//div[@class='quote']//a[@href]")?.FirstOrDefault(a => a.GetAttributeValue("href", "").Contains("online-fix.me:2053/uploads/"));
            if (link == null) throw new Exception("This page has no supported official patch directory");
            var directory = Validate(HtmlEntity.DeEntitize(link.GetAttributeValue("href", ""))).AbsoluteUri.TrimEnd('/') + "/Fix%20Repair/";
            var body = doc.DocumentNode.SelectSingleNode("//div[@itemprop='articleBody']");
            if (body != null) foreach (var br in body.SelectNodes(".//br")?.ToArray() ?? []) br.ParentNode.ReplaceChild(HtmlNode.CreateNode("\n"), br);
            var instructions = Plain(body); if (instructions.Length > 8000) instructions = instructions[..8000];
            return new { ok = true, fixDetail = new { title = Plain(doc.DocumentNode.SelectSingleNode("//h1[@id='news-title']")), url = r.URL, instructions, files = await Files(directory, ct) } };
        }
        if (r.Operation == "onlinefix-download")
        {
            Validate(r.URL); Validate(r.Referer);
            if (!Path.IsPathFullyQualified(r.Destination) || File.Exists(r.Destination)) throw new Exception("Download destination must be a new absolute file");
            using (var warm = await Get(r.Referer, ct)) { }
            using var response = await Get(r.URL, ct, r.Referer);
            if (response.Content.Headers.ContentType?.MediaType?.Contains("html") == true) throw new Exception("Server returned a web page instead of an archive");
            const long maximum = 2L * 1024 * 1024 * 1024;
            if (response.Content.Headers.ContentLength > maximum) throw new Exception("Archive exceeds 2 GiB limit");
            var temporary = r.Destination + ".partial-" + Guid.NewGuid().ToString("N");
            Directory.CreateDirectory(Path.GetDirectoryName(r.Destination)!);
            try
            {
                await using (var input = await response.Content.ReadAsStreamAsync(ct))
                await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write))
                {
                    var buffer = new byte[65536]; long done = 0; int count;
                    while ((count = await input.ReadAsync(buffer, ct)) > 0) { done += count; if (done > maximum) throw new Exception("Archive exceeds 2 GiB limit"); await output.WriteAsync(buffer.AsMemory(0, count), ct); }
                    if (done == 0 || response.Content.Headers.ContentLength is long size && done != size) throw new Exception("Incomplete download");
                }
                File.Move(temporary, r.Destination);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
            return new { ok = true, path = r.Destination };
        }
        throw new Exception("Unknown OnlineFix operation");
    }
}

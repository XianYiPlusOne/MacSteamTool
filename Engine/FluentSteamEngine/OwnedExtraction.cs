using SteamKit2;

internal sealed record ExtractionDepot(uint ID, uint Owner, uint SourceApp, string Manifest);
internal sealed record ExtractionApp(uint ID, string Name, string AccessToken, uint[] DLC, ExtractionDepot[] Depots);
internal sealed record ExtractedDepot(uint ID, uint Owner, uint SourceApp, string Key, string Result, string Manifest);
internal sealed record ExtractedApp(uint ID, string Name, string AccessToken);
internal sealed record ExtractionResult(bool OK, uint AppID, string Name, string AccessToken, ExtractedApp[] ExtractedApps, ExtractedDepot[] Depots, string[] Warnings);

/// Network-independent traversal; all key requests still go through the signed-in
/// Steam session. Logical Lua ownership and shared-depot download ownership differ.
internal static class OwnedExtraction
{
    public static ExtractionApp Parse(uint id, KeyValue app, ulong token)
    {
        var dlc = new HashSet<uint>();
        var list = app["extended"]["listofdlc"];
        foreach (var value in (list.AsString() ?? "").Split(',').Concat(list.Children.Select(x => x.Value ?? "")))
            if (uint.TryParse(value.Trim(), out var child) && child > 0 && child != id) dlc.Add(child);
        var depots = new List<ExtractionDepot>();
        foreach (var d in app["depots"].Children)
        {
            if (!uint.TryParse(d.Name, out var depot) || depot == 0) continue;
            var owner = d["dlcappid"].AsUnsignedInteger(id); if (owner == 0) owner = id;
            if (owner != id) dlc.Add(owner);
            var source = d["depotfromapp"].AsUnsignedInteger(owner); if (source == 0) source = owner;
            depots.Add(new(depot, owner, source, d["manifests"]["public"]["gid"].AsUnsignedLong().ToString()));
        }
        return new(id, app["common"]["name"].AsString() ?? id.ToString(), token.ToString(), dlc.Order().ToArray(), depots.OrderBy(x => x.ID).ToArray());
    }
    public static async Task<ExtractionResult> Run(uint root, bool includeDLC, ISet<uint> owned,
        Func<uint, Task<ExtractionApp>> fetch, Func<uint, uint, Task<(string Key, string Result)>> key,
        CancellationToken ct, ISet<uint>? requestedDepots = null)
    {
        if (!owned.Contains(root)) throw new Exception("This signed-in account has no license for the selected app");
        var warnings = new List<string>(); var known = new Dictionary<uint, ExtractionApp>();
        var pending = new Queue<uint>(); pending.Enqueue(root); var visited = new HashSet<uint>();
        while (pending.Count > 0)
        {
            ct.ThrowIfCancellationRequested(); var id = pending.Dequeue();
            if (!visited.Add(id)) continue;
            if (visited.Count > 2048) throw new Exception("DLC graph exceeds 2048 apps");
            if (!owned.Contains(id)) { warnings.Add($"App {id}: not licensed to this account; skipped"); continue; }
            ExtractionApp app;
            try { app = await fetch(id); if (app.ID != id) throw new Exception("Metadata AppID mismatch"); }
            catch (Exception e) when (id != root && e is not OperationCanceledException) { warnings.Add($"DLC {id}: {e.Message}"); continue; }
            known.Add(id, app);
            if (includeDLC) foreach (var child in app.DLC.Order()) if (!visited.Contains(child)) pending.Enqueue(child);
        }
        var unique = new Dictionary<uint, ExtractionDepot>();
        foreach (var app in known.Values.OrderBy(x => x.ID == root ? 0 : x.ID))
            foreach (var depot in app.Depots)
            {
                if (depot.Owner != root && (!includeDLC || !known.ContainsKey(depot.Owner))) continue;
                if (unique.TryGetValue(depot.ID, out var previous)) {
                    if (previous.SourceApp != depot.SourceApp || previous.Manifest != depot.Manifest) warnings.Add($"Depot {depot.ID}: conflicting metadata; first definition retained");
                    continue;
                }
                if (unique.Count >= 10000) throw new Exception("Depot graph exceeds 10000 entries");
                unique.Add(depot.ID, depot);
            }
        if (requestedDepots != null) {
            if (requestedDepots.Count == 0 || requestedDepots.Any(id => !unique.ContainsKey(id)))
                throw new Exception("Requested depot is not in this account's accessible app metadata");
            foreach (var id in unique.Keys.Except(requestedDepots).ToArray()) unique.Remove(id);
        }
        using var limit = new SemaphoreSlim(6);
        var requests = unique.Values.Select(async depot => {
            await limit.WaitAsync(ct);
            try {
                var result = await key(depot.ID, depot.SourceApp);
                var valid = result.Key.Length == 64 && result.Key.All(Uri.IsHexDigit);
                return new ExtractedDepot(depot.ID, depot.Owner, depot.SourceApp, valid ? result.Key.ToLowerInvariant() : "", valid ? result.Result : result.Result == "OK" ? "Invalid key length" : result.Result, depot.Manifest);
            } catch (OperationCanceledException) { throw; }
            catch (Exception e) { return new ExtractedDepot(depot.ID, depot.Owner, depot.SourceApp, "", e.Message, depot.Manifest); }
            finally { limit.Release(); }
        });
        var depots = (await Task.WhenAll(requests)).OrderBy(x => x.Owner == root ? 0 : x.Owner).ThenBy(x => x.ID).ToArray();
        var included = known.Values.Where(app => app.ID == root ||
            !unique.Values.Any(d => d.Owner == app.ID) || depots.Any(d => d.Owner == app.ID && d.Key.Length == 64)).ToArray();
        foreach (var skipped in known.Keys.Except(included.Select(x => x.ID))) warnings.Add($"DLC {skipped}: no accessible depot keys; omitted from Lua");
        var main = known[root];
        return new(true, root, main.Name, main.AccessToken,
            included.OrderBy(x => x.ID == root ? 0 : x.ID).Select(x => new ExtractedApp(x.ID, x.Name, x.AccessToken)).ToArray(), depots, warnings.ToArray());
    }
}

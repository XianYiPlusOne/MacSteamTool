using SteamKit2;

static void Check(bool value, string message) { if (!value) throw new Exception(message); }
static async Task Fails(Func<Task> run) { try { await run(); } catch { return; } throw new Exception("Expected failure"); }
var apps = new Dictionary<uint, ExtractionApp> {
    [100] = new(100,"Root","18446744073709551615",[200,300,400,500,600], [new(101,100,100,"18446744073709551615"), new(201,200,900,"20"), new(301,300,300,"30")]),
    [200] = new(200,"DLC","22",[100,700], [new(201,200,900,"20"),new(202,200,200,"21")]),
    [400] = new(400,"Depotless DLC","0",[],[]),
    [500] = new(500,"Partial failure DLC","0",[],[new(501,500,500,"50")]),
    [700] = new(700,"Child DLC","33",[],[new(701,700,700,"70")])
};
var owned = new HashSet<uint> { 100,200,400,500,600,700 };
var fetched = new List<uint>(); var requested = new List<(uint,uint)>();
Task<ExtractionApp> Fetch(uint id) { fetched.Add(id); return Task.FromResult(apps[id]); }
Task<(string,string)> Key(uint depot,uint source) { requested.Add((depot,source)); return Task.FromResult(depot is 202 or 501 ? ("", "AccessDenied") : (new string('a',64),"OK")); }
var result = await OwnedExtraction.Run(100,true,owned,Fetch,Key,default);
Check(result.OK && result.ExtractedApps.Select(x=>x.ID).SequenceEqual(new uint[]{100,200,400,700}), "licensed DLC recursion and omission");
Check(requested.Count==5 && requested.Count(x=>x.Item1==201)==1 && requested.Contains((201,900)), "shared source and depot deduplication");
Check(!fetched.Contains(300) && result.Warnings.Any(x=>x.Contains("300")) && result.Warnings.Any(x=>x.Contains("600")) && result.Warnings.Any(x=>x.Contains("500")), "partial failures must be visible");
Check(result.Depots.Single(x=>x.ID==202).Result=="AccessDenied", "key failure retained");
fetched.Clear();requested.Clear();
result=await OwnedExtraction.Run(100,false,owned,Fetch,Key,default);
Check(fetched.SequenceEqual(new uint[]{100}) && requested.SequenceEqual(new[]{(101u,100u)}) && result.ExtractedApps.Length==1,"DLC opt out");
await Fails(()=>OwnedExtraction.Run(999,true,owned,Fetch,Key,default));
using(var stop = new CancellationTokenSource()) { stop.Cancel(); await Fails(()=>OwnedExtraction.Run(100,true,owned,Fetch,Key,stop.Token)); }
var kv = KeyValue.LoadFromString("\"appinfo\" { \"common\" { \"name\" \"Root\" } \"extended\" { \"listofdlc\" \"200,400,bad\" } \"depots\" { \"201\" { \"dlcappid\" \"200\" \"depotfromapp\" \"900\" \"manifests\" { \"public\" { \"gid\" \"18446744073709551615\" } } } } }")!;
var parsed=OwnedExtraction.Parse(100,kv,ulong.MaxValue);
using (var metadata = System.Text.Json.JsonDocument.Parse(Session.ProductMetadataJson(kv)))
{
    var root = metadata.RootElement;
    var depot = root.GetProperty("depots").GetProperty("201");
    Check(root.GetProperty("extended").GetProperty("listofdlc").GetString() == "200,400,bad"
        && depot.GetProperty("depotfromapp").GetString() == "900"
        && depot.GetProperty("manifests").GetProperty("public").GetProperty("gid").GetString() == ulong.MaxValue.ToString(),
        "PICS fallback must preserve shared depot, DLC and full-width manifest fields");
}
Check(parsed.DLC.SequenceEqual(new uint[]{200,400}) && parsed.Depots[0].SourceApp==900 && parsed.Depots[0].Owner==200 && parsed.Depots[0].Manifest==ulong.MaxValue.ToString(),"metadata ownership and UInt64");
var hash=new string('a',64); var html=$"<a href='/NotProtonNot/NotProton/releases/download/v1.2.4/NotProton.zip'>Download</a><clipboard-copy aria-label='Copy to clipboard digest for NotProton.zip' value='sha256:{hash}'></clipboard-copy>";
var release=RuntimeReleases.Parse("notproton",new Uri("https://github.com/NotProtonNot/NotProton/releases/tag/v1.2.4"),html);
Check(release.Version=="1.2.4" && release.SHA256==hash,"official asset parser");
foreach(var bad in new[]{release with { URL=release.URL+"?redirect=evil" }, release with { SHA256="" },release with { AssetName="other.zip" }, release with { Tag="../evil" }}) await Fails(()=>{RuntimeReleases.Validate(bad);return Task.CompletedTask;});
await Fails(()=>{RuntimeReleases.Parse("notproton",new Uri("https://evil.example/releases/tag/v1.2.4"),html);return Task.CompletedTask;});
await Fails(()=>{RuntimeReleases.Parse("notproton",new Uri(release.ReleaseURL),html.Replace("sha256:","none:"));return Task.CompletedTask;});
// Content repair requests only the explicitly selected, accessible depot.
requested.Clear();
var repair = await OwnedExtraction.Run(100, false, owned, Fetch, Key, default, new HashSet<uint> { 101 });
Check(repair.Depots.Length == 1 && requested.SequenceEqual(new[] { ((uint)101, (uint)100) }), "repair only requests selected depot with owner app");
requested.Clear();
await Fails(() => OwnedExtraction.Run(100, false, owned, Fetch, Key, default, new HashSet<uint> { 999 }));
Check(requested.Count == 0, "unknown depot fails before key requests");
Console.WriteLine("PASS: owned-license gate, recursive DLC/cycles, DLC opt-out, unlicensed and inaccessible DLC, shared-source keys, depot deduplication, partial metadata/key failures, cancellation, UInt64 metadata, official release parser and URL/digest validation");
var temp=Path.Combine(Path.GetTempPath(),"FluentTar-"+Guid.NewGuid());Directory.CreateDirectory(temp);
try {
    var path=Path.Combine(temp,"sample.tar");
    using(var output=File.Create(path)) using(var tar=new System.Formats.Tar.TarWriter(output)) {
        var entry=new System.Formats.Tar.UstarTarEntry(System.Formats.Tar.TarEntryType.RegularFile,"100.lua");entry.DataStream=new MemoryStream("addappid(100)"u8.ToArray());tar.WriteEntry(entry);
    }
    await PatchArchive.Extract(new Request("library-import",Archive:path,Destination:Path.Combine(temp,"extracted")),default);
    Check(File.ReadAllText(Path.Combine(temp,"extracted/100.lua"))=="addappid(100)","TAR adapter");
    Console.WriteLine("PASS: TAR library adapter");
} finally { Directory.Delete(temp,true); }
static void WriteReply(string path,object value) { var temp=path+".new"; File.WriteAllText(temp,System.Text.Json.JsonSerializer.Serialize(value)); File.Move(temp,path,true); }
// Synthetic cached credentials only: no local Steam cache or account is read.
var now=DateTimeOffset.UtcNow;
string Jwt(string subject,long expiry) {
    var json=System.Text.Json.JsonSerializer.Serialize(new { sub=subject, exp=expiry });
    return "eyJhbGciOiJSUzI1NiJ9."+Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json)).TrimEnd('=').Replace('+','-').Replace('/','_')+".fixture";
}
byte[] Envelope(string account,string token) {
    using var aes=System.Security.Cryptography.Aes.Create();aes.Key=System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(account));
    var iv=Enumerable.Range(0,16).Select(x=>(byte)x).ToArray();
    return aes.EncryptEcb(iv,System.Security.Cryptography.PaddingMode.None).Concat(aes.EncryptCbc(System.Text.Encoding.UTF8.GetBytes(token),iv,System.Security.Cryptography.PaddingMode.PKCS7)).ToArray();
}
var jwt=Jwt("76561197960265729",now.AddHours(1).ToUnixTimeSeconds());var envelope=Envelope("fixture",jwt);
Check(LocalSteamLogin.Decrypt(envelope,"fixture","76561197960265729",now)==jwt,"macOS cached-token envelope");
Check(LocalSteamLogin.Decrypt(envelope,"other","76561197960265729",now)==null,"different account encryption");
Check(LocalSteamLogin.Decrypt(envelope,"fixture","76561197960265730",now)==null,"cached-token subject isolation");
Check(LocalSteamLogin.Decrypt(envelope,"fixture","76561197960265729",now.AddHours(2))==null,"expired cached-token rejection");
Check(LocalSteamLogin.Decrypt(new byte[17],"fixture","76561197960265729",now)==null,"malformed cached-token rejection");
var fixtureDir=Path.Combine(Path.GetTempPath(),"FluentAuth-"+Guid.NewGuid());Directory.CreateDirectory(fixtureDir);
try {
    var hex=Convert.ToHexString(envelope);
    File.WriteAllText(Path.Combine(fixtureDir,"local.vdf"),$"\"MachineUserConfigStore\" {{ \"Software\" {{ \"Valve\" {{ \"Steam\" {{ \"ConnectCache\" {{ \"bad\" \"bad\" \"fixture\" \"{hex}\" }} }} }} }} }}");
    Check(LocalSteamLogin.Read(new Request("login-local",Account:"fixture",SteamPath:fixtureDir,SteamID:"76561197960265729"))==jwt,"local VDF credential envelope traversal");
    var status=Path.Combine(fixtureDir,"status");using var authTimeout=new CancellationTokenSource(TimeSpan.FromSeconds(5));
    var authenticator=new LoginAuthenticator(status,authTimeout.Token);
    var answer=authenticator.GetDeviceCodeAsync(false);
    using(var message=System.Text.Json.JsonDocument.Parse(File.ReadAllText(status))) {
        WriteReply(status+".reply",new { requestID=message.RootElement.GetProperty("requestID").GetString(),code="ABCDE" });
    }
    Check(await answer=="ABCDE","interactive Guard code roundtrip");
    answer=authenticator.GetEmailCodeAsync("fixture@example.invalid",true);
    using(var message=System.Text.Json.JsonDocument.Parse(File.ReadAllText(status))) {
        Check(message.RootElement.GetProperty("prompt").GetString()!.Contains("Incorrect"),"incorrect Guard code prompt");
        WriteReply(status+".reply",new { requestID=message.RootElement.GetProperty("requestID").GetString(),code="" });
    }
    await Fails(async ()=>{await answer;});
} finally { Directory.Delete(fixtureDir,true); }
Console.WriteLine("PASS: macOS cached-token envelope, account/expiry/malformed rejection, local VDF traversal, interactive Guard code roundtrip, retry and cancellation");

var notes=RuntimeReleases.ReleaseNotes("<div class='markdown-body'><h2>Fixes</h2><p>Updated <strong>runtime</strong>.</p><ul><li>Safe update</li></ul><a href='https://example.invalid/release'>Details</a></div>");
Check(notes!=null && notes.Contains("## Fixes") && notes.Contains("**runtime**") && notes.Contains("- Safe update") && notes.Contains("[Details](https://example.invalid/release)"),"GitHub HTML release notes fallback to Markdown");
Console.WriteLine("PASS: release notes Markdown fallback");

await ToolPackageTests.Run();

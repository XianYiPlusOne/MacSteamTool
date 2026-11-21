#!/usr/bin/env python3
"""Compile unchanged upstream method bodies; fake only I/O and Steam reply boundaries."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = root / 'work/fluent-steam-lua-review'
out = root / 'work/upstream-san14-repro'
out.mkdir(parents=True, exist_ok=True)
service = (source / 'Services/SteamDepotService.cs').read_text()
account = (source / 'Services/SteamAccountService.cs').read_text()
view = (source / 'ViewModels/ExtractionViewModel.cs').read_text()

def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]

build = section(service, '    private async Task<string?> BuildLuaCoreAsync(', '    private sealed record DlcBuildInfo')
keys = section(account, '    public async Task<Dictionary<uint, byte[]>> GetDepotKeysAsync(', '    public async Task<ManifestDownloadResult> DownloadManifestAsync(')
assembly = section(view, '            var dlcIdSet = new HashSet<int>(queryResult.DlcAppIds);', '            // DLC 子仓库小结')
record = section(view, '    private sealed record PendingDepot(', '\n\n')
model = (source / 'Models/DepotQueryResult.cs').read_text()
(out / 'DepotQueryResult.cs').write_text(model)

prefix = r'''
using System.Text;
using SteamLuaManager.Models;
static class L { public static string Get(string key, params object?[] args) => key + ": " + string.Join(",", args); }
static class LogService {
 public static readonly List<string> Lines = new();
 public static void Info(string category, string text) => Lines.Add(text);
 public static void Warn(string category, string text) => Lines.Add(text);
 public static void Error(string category, string text) => Lines.Add(text);
}
class Paths(string folder) { public string GetLuaFolder() => folder; }
class DepotBoundary(Dictionary<int, DepotQueryResult?> metadata) {
 public Task<DepotQueryResult?> QueryAppAsync(int id, CancellationToken ct) => Task.FromResult(metadata.GetValueOrDefault(id));
}
enum EResult { OK, AccessDenied }
record Reply(EResult Result, byte[] DepotKey);
class Job(Reply reply) { public TimeSpan Timeout { get; set; } public Task<Reply> ToTask() => Task.FromResult(reply); }
class SteamBoundary(bool deny415) {
 public readonly List<(uint depot, uint app)> Requests = new();
 public Job GetDepotDecryptionKey(uint depot, uint app) {
  Requests.Add((depot, app));
  return new Job(depot == 872410 || (deny415 && depot == 872415)
    ? new Reply(EResult.AccessDenied, []) : new Reply(EResult.OK, Enumerable.Repeat((byte)0xab, 32).ToArray()));
 }
}
class OriginalAccount {
 public bool IsLoggedOn { get; set; } = true;
 readonly SteamBoundary _apps;
 public OriginalAccount(SteamBoundary steam) { _apps = steam; }
'''
wrappers = r'''
}
class OriginalGenerator {
 readonly Dictionary<string,string> fixtureKeys;
 readonly DepotBoundary boundary;
 readonly Paths _steamPathService;
 public OriginalGenerator(Dictionary<string,string> keys, DepotBoundary metadata, string folder) { fixtureKeys=keys; boundary=metadata; _steamPathService=new Paths(folder); }
 Task<bool> EnsureKeyFilesAsync(CancellationToken ct) => Task.FromResult(true);
 Task<(Dictionary<string,string>, Dictionary<string,string>)> LoadKeyDictionariesAsync(CancellationToken ct) => Task.FromResult((fixtureKeys,new Dictionary<string,string>()));
 Task<DepotQueryResult?> QueryAppAsync(int id, CancellationToken ct) => boundary.QueryAppAsync(id,ct);
 Task<string> TryGetDisplayNameAsync(int id,string name,CancellationToken ct) => Task.FromResult(name);
 static string SanitizeLuaComment(string text) => text.Replace('\n',' ');
 async Task<DlcBuildInfo[]> FetchDlcInfosAsync(List<int> ids,IProgress<(int Done,int Total)>? p,bool names,CancellationToken ct) {
  var list=new List<DlcBuildInfo>(); foreach(var id in ids) list.Add(new(id,await boundary.QueryAppAsync(id,ct),"")); return list.ToArray();
 }
 public Task<string?> Run(bool dlc) => BuildLuaCoreAsync(872410,dlc,false,default);
 private sealed record DlcBuildInfo(int AppId, DepotQueryResult? Result,string DisplayName);
'''
assembly_wrapper = r'''
}
class OriginalExtractionAssembly {
 readonly DepotBoundary _depotService;
 readonly OriginalAccount _accountService;
 public OriginalExtractionAssembly(DepotBoundary metadata,OriginalAccount account) { _depotService=metadata; _accountService=account; }
 public string StatusMessage { get; set; }="";
 public bool PinManifest { get; set; }
 static void PostLog(string text) => LogService.Lines.Add(text);
 static string ScopeDisplay(string scope) => scope;
 public async Task<string> Run(DepotQueryResult queryResult) {
  var ct=CancellationToken.None; var appId=872410;
'''
main = r'''
 }
}
class Program {
 static void Check(bool value,string message) { if(!value) throw new Exception(message); }
 static async Task Main(string[] args) {
  var folder=args[0]; Directory.CreateDirectory(folder);
  var key=new string('a',64); // SYNTHETIC: never a real key or live account.
  DepotQueryResult MainInfo(bool dlc=false) => new() { AppId=872410,AppName="SAN14 offline fixture",GameDepots=Enumerable.Range(872411,5).Select(id=>new DepotKeyInfo { DepotId=id,ManifestId=id.ToString() }).ToList(),DlcAppIds=dlc ? [1258150] : [] };
  DepotBoundary Metadata(bool dlc=false) => new(new() { [872410]=MainInfo(dlc),[1258150]=new DepotQueryResult { AppId=1258150 } });
  var four=Enumerable.Range(872411,4).ToDictionary(id=>id.ToString(),_=>key);
  var generated=await new OriginalGenerator(four,Metadata(),folder).Run(false);
  Check(generated!=null,"A source method must generate Lua with four known keys");
  var text=File.ReadAllText(generated!); Check(!text.Contains("872415"),"A missing depot is silently omitted");
  Check(text.Split('\n').Count(x=>x.StartsWith("addappid(") && x.Contains(", 1,"))==4,"A source writes exactly four depot keys");
  File.Copy(generated!,Path.Combine(folder,"A-generator-missing-415.lua"),true);
  Console.WriteLine("PASS A: exact source BuildLuaCoreAsync returned a Lua path; 4 keyed depots; 872415 omitted (not repaired)");

  var all=new Dictionary<string,string>(four) { ["872415"]=key };
  generated=await new OriginalGenerator(all,Metadata(),folder).Run(false);
  Check(File.ReadAllText(generated!).Contains("addappid(872415, 1,"),"B key is retained");
  File.Copy(generated!,Path.Combine(folder,"B-generator-with-415.lua"),true);
  Console.WriteLine("PASS B: same source method with synthetic 872415 key writes the missing depot");

  bool rejected=false;
  try { await new OriginalGenerator(new(),Metadata(),folder).Run(false); } catch(InvalidOperationException) { rejected=true; }
  Check(rejected,"C zero total matches must fail");
  Console.WriteLine("PASS C: exact generator throws when no key/token matches at all");

  generated=await new OriginalGenerator(four,Metadata(true),folder).Run(true);
  Check(File.ReadAllText(generated!).Contains("addappid(1258150)"),"D empty DLC metadata writes bare DLC row");
  Console.WriteLine("PASS D: empty optional-DLC metadata becomes a bare addappid in original generator");

  foreach(var deny in new[] {false,true}) {
   var steam=new SteamBoundary(deny);
   var account=new OriginalAccount(steam);
   var lua=await new OriginalExtractionAssembly(Metadata(),account).Run(MainInfo());
   Check(steam.Requests.Contains((872415,872410)),"source requests correct depot/app pair");
   Check(lua.Contains("addappid(872415, 1,")==!deny,"Steam result controls key row");
   if(deny) Check(lua.Contains("addappid(872415)"),"original source keeps bare depot row on denial");
   File.WriteAllText(Path.Combine(folder,deny ? "F-extract-denied.lua" : "E-extract-ok.lua"),lua);
   Console.WriteLine(deny
    ? "PASS F: original GetDepotKeysAsync + assembly: injected AccessDenied -> no key, bare addappid(872415) remains"
    : "PASS E: original GetDepotKeysAsync + assembly: request (872415,872410), injected OK -> keyed depot emitted");
  }
  var loggedOut=new OriginalAccount(new SteamBoundary(false)) {IsLoggedOn=false};
  rejected=false;
  try {await loggedOut.GetDepotKeysAsync([(872415u,872410u)]);} catch(InvalidOperationException) {rejected=true;}
  Check(rejected,"logged-out gate rejects");
  Console.WriteLine("PASS G: original GetDepotKeysAsync refuses logged-out session");

  // Real local metadata/key cache, original generator body, private temporary output.
  // No real key values are printed or copied into the reproduction artifacts.
  var support=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"Library/Application Support/FluentSteamMac");
  using(var cache=System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(support,"Cache/depotkeys.json"))))
  using(var metadata=System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(support,"Cache/Metadata/appinfo-872410.json")))) {
   var realKeys=cache.RootElement.EnumerateObject().Where(p=>p.Value.ValueKind==System.Text.Json.JsonValueKind.String).ToDictionary(p=>p.Name,p=>p.Value.GetString()!);
   var data=metadata.RootElement;
   var actual=new DepotQueryResult {AppId=872410,AppName="SAN14 local metadata"};
   foreach(var d in data.GetProperty("depots").EnumerateArray()) actual.GameDepots.Add(new DepotKeyInfo {DepotId=d.GetProperty("id").GetInt32(),ManifestId=d.GetProperty("manifest").GetString()??""});
   foreach(var d in data.GetProperty("dlc").EnumerateArray()) actual.DlcAppIds.Add(d.GetInt32());
   var privateFolder=Path.Combine(Path.GetTempPath(),"FluentSourceActual-"+Guid.NewGuid());
   Directory.CreateDirectory(privateFolder);
   if(!OperatingSystem.IsWindows()) File.SetUnixFileMode(privateFolder,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
   try {
    var path=await new OriginalGenerator(realKeys,new DepotBoundary(new(){[872410]=actual}),privateFolder).Run(false);
    Check(path!=null,"H source generator must return result on actual local data");
    var lua=File.ReadAllText(path!);
    bool cacheHas415=realKeys.ContainsKey("872415");
    bool outputHas415=lua.Contains("addappid(872415, 1,");
    Check(cacheHas415==outputHas415,"H local missing/present depot behavior");
    Console.WriteLine($"PASS H: real local cache + metadata -> original generator returned Lua; cache has 872415={cacheHas415}; output has keyed 872415={outputHas415}; private output deleted");
   } finally {Directory.Delete(privateFolder,true);}
  }
  Console.WriteLine("BOUNDARY: unchanged source bodies; A-G use synthetic I/O and Steam replies; H uses real local caches; no real Steam key acquisition, download, or game launch proven");
 }
}
'''
program = (prefix + keys + wrappers + build + '\n}\n'
           + 'class OriginalExtractionAssembly {\n' + record
           + assembly_wrapper.split('class OriginalExtractionAssembly {\n', 1)[1]
           + assembly + '\nreturn sb.ToString();\n' + main)
(out / 'Program.cs').write_text(program)
(out / 'Repro.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
revision=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
proof={'revision':revision,'mode':'unaltered source bodies; A-G synthetic boundaries; H real local caches','snippets':{n:hashlib.sha256(t.encode()).hexdigest() for n,t in [('BuildLuaCoreAsync',build),('GetDepotKeysAsync_and_FetchOneKeyAsync',keys),('Extraction_phases_3_to_6',assembly)]}}
(out/'source-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
result=subprocess.run([str(root/'work/dotnet/dotnet'),'run','--project',str(out/'Repro.csproj'),'--',str(out/'artifacts')],text=True,capture_output=True)
(out/'run.log').write_text(result.stdout+result.stderr)
print(result.stdout+result.stderr)
raise SystemExit(result.returncode)

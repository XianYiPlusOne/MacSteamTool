using System.Reflection;
using System.Runtime.InteropServices;
Environment.SetEnvironmentVariable("SteamAppId","4348910");
Environment.SetEnvironmentVariable("SteamGameId","4348910");
var asm=Assembly.LoadFrom(args[0]);
var dll=NativeLibrary.Load(args[1]);
NativeLibrary.SetDllImportResolver(asm,(name,a,path)=>name=="steam_api64"?dll:IntPtr.Zero);
var api=asm.GetType("Steamworks.SteamAPI")!;
object?[] output={null};
var report = new Dictionary<string, object?> { ["started"] = true, ["writes"] = false };
try {
 var result=api.GetMethod("InitEx")!.Invoke(null,output);
 report["result"] = result?.ToString(); report["error"] = output[0]?.ToString();
 var context=asm.GetType("Steamworks.CSteamAPIContext")!;
 foreach(var field in context.GetFields(BindingFlags.NonPublic|BindingFlags.Static))
  report[field.Name] = field.GetValue(null) is IntPtr p && p!=IntPtr.Zero;
} catch(Exception e) { report["exception"] = e.ToString(); Environment.ExitCode=1; }
finally { Marshal.GetDelegateForFunctionPointer<Shutdown>(NativeLibrary.GetExport(dll,"SteamAPI_Shutdown"))(); File.WriteAllText(args[2], System.Text.Json.JsonSerializer.Serialize(report)); }
[UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Shutdown();

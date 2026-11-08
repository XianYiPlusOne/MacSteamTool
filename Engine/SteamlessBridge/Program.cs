using System.Reflection;
using System.Runtime.Loader;
using System.Text.Json;

// Separate x86 process: official Steamless DLLs are x86 .NET Framework assemblies.
// They are loaded unchanged from the user's downloaded official release.
if (args.Length != 2) return 2;
try {
    var request = JsonSerializer.Deserialize<Request>(File.ReadAllText(args[0]), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new Exception("Invalid request");
    var directory = Path.GetFullPath(request.Plugins);
    AssemblyLoadContext.Default.Resolving += (context, name) => {
        var path = Path.Combine(directory, name.Name + ".dll");
        return File.Exists(path) ? context.LoadFromAssemblyPath(path) : null;
    };
    var api = AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.Combine(directory, "Steamless.API.dll"));
    var log = Activator.CreateInstance(api.GetType("Steamless.API.Services.LoggingService", true)!);
    var options = Activator.CreateInstance(api.GetType("Steamless.API.Model.SteamlessOptions", true)!);
    var plugins = new List<(object instance, Type type, string name)>();
    foreach (var file in Directory.GetFiles(directory, "Steamless.Unpacker.*.dll").Order()) {
        var type = AssemblyLoadContext.Default.LoadFromAssemblyPath(file).GetTypes().Single(t => t.Name == "Main");
        var plugin = Activator.CreateInstance(type)!;
        if (!(bool)type.GetMethod("Initialize")!.Invoke(plugin, [log])!) throw new Exception("Plugin initialization failed: " + type.FullName);
        plugins.Add((plugin, type, type.GetProperty("Name")!.GetValue(plugin)?.ToString() ?? type.FullName!));
    }
    if (plugins.Count == 0) throw new Exception("No Steamless unpackers found");
    if (request.Operation == "inspect") { Write(new { ok = true, plugins = plugins.Select(p => p.name).ToArray(), platform = "Windows x86 / NotProton" }); return 0; }
    if (request.Operation != "unpack" || !Path.IsPathFullyQualified(request.File) || !File.Exists(request.File)) throw new Exception("Invalid unpack input");
    var output = request.File + ".unpacked.exe";
    if (File.Exists(output)) throw new Exception("Unpacked output already exists");
    foreach (var plugin in plugins) {
        if (!(bool)plugin.type.GetMethod("CanProcessFile")!.Invoke(plugin.instance, [request.File])!) continue;
        if (!(bool)plugin.type.GetMethod("ProcessFile")!.Invoke(plugin.instance, [request.File, options])! || !File.Exists(output)) throw new Exception("Steamless could not unpack this executable");
        using var stream = File.OpenRead(output);
        if (stream.Length < 64 || stream.ReadByte() != 'M' || stream.ReadByte() != 'Z') throw new Exception("Unpacker output failed PE validation");
        Write(new { ok = true, path = output, plugin = plugin.name }); return 0;
    }
    throw new Exception("No supported SteamStub variant found. The file may already be unpacked or use another DRM.");
} catch (Exception ex) { Write(new { ok = false, error = (ex is TargetInvocationException ? ex.InnerException : ex)?.Message ?? ex.Message }); return 1; }
void Write(object response) {
    var temp = args[1] + ".new"; File.WriteAllText(temp, JsonSerializer.Serialize(response)); File.Move(temp, args[1], true);
}
record Request(string Operation, string Plugins, string File = "");

// Read-only process/module inventory inside the explicitly selected Wine server.
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

internal static class Program
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct ProcessEntry {
        public uint size, usage, pid; public UIntPtr heap; public uint module, threads, parent; public int priority; public uint flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string executable;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct ModuleEntry {
        public uint size, moduleID, pid, globalUsage, processUsage; public IntPtr address; public uint bytes; public IntPtr handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string path;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct FileInfo {
        public uint attributes; public long created, accessed, written; public uint volume, highSize, lowSize, links, highIndex, lowIndex;
    }
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Module32FirstW(IntPtr snapshot, ref ModuleEntry entry);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Module32NextW(IntPtr snapshot, ref ModuleEntry entry);
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref uint length);
    [DllImport("kernel32", SetLastError = true)] static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32", SetLastError = true)] static extern bool GetFileInformationByHandle(IntPtr file, out FileInfo info);
    static bool Invalid(IntPtr handle) => handle == new IntPtr(-1);
    static string Identity(string path) {
        var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (Invalid(handle)) throw new Exception("Cannot identify a module file: " + Marshal.GetLastWin32Error());
        try {
            if (!GetFileInformationByHandle(handle, out var info)) throw new Exception("File identity unavailable");
            if (info.highIndex == 0 && info.lowIndex == 0) throw new Exception("File identity is not reliable");
            return $"{info.volume:X8}:{info.highIndex:X8}:{info.lowIndex:X8}";
        } finally { CloseHandle(handle); }
    }
    static string Image(IntPtr process) {
        var text = new StringBuilder(32768); uint length = (uint)text.Capacity;
        if (!QueryFullProcessImageNameW(process, 0, text, ref length)) throw new Exception("Process image unavailable");
        return text.ToString();
    }
    static object Inventory(JsonElement request) {
        if (!Environment.Is64BitProcess || !OperatingSystem.IsWindows()) throw new Exception("Windows x64 helper required");
        var nonce = request.GetProperty("nonce").GetString();
        var executable = request.GetProperty("executable").GetString()!;
        var modules = request.GetProperty("modules").EnumerateArray().Select(x => x.GetString()!).ToArray();
        if (Guid.TryParse(nonce, out _) == false || !Path.IsPathFullyQualified(executable) || modules.Length > 512 || modules.Any(x => !Path.IsPathFullyQualified(x))) throw new Exception("Invalid inventory scope");
        var gameID = Identity(executable); var expected = modules.Select(Identity).ToArray();
        var matches = new List<object>(); int unreadable = 0;
        var processes = CreateToolhelp32Snapshot(2, 0);
        if (Invalid(processes)) throw new Exception("Process inventory unavailable");
        try {
            var entry = new ProcessEntry { size = (uint)Marshal.SizeOf<ProcessEntry>() };
            bool next = Process32FirstW(processes, ref entry);
            if (!next && Marshal.GetLastWin32Error() != 18) throw new Exception("Incomplete process inventory");
            while (next) {
                var handle = OpenProcess(0x1000, false, entry.pid);
                if (handle == IntPtr.Zero) { unreadable++; }
                else try {
                    string image;
                    try { image = Image(handle); if (Identity(image) != gameID) { next = Process32NextW(processes, ref entry); continue; } }
                    catch { if (string.Equals(Path.GetFileName(entry.executable), Path.GetFileName(executable), StringComparison.OrdinalIgnoreCase)) throw new Exception("Cannot identify a matching game process"); unreadable++; next = Process32NextW(processes, ref entry); continue; }
                    if (!GetProcessTimes(handle, out var created, out _, out _, out _)) throw new Exception("Cannot bind process creation time");
                    var snapshot = CreateToolhelp32Snapshot(0x18, entry.pid);
                    if (Invalid(snapshot)) throw new Exception("Module inventory unavailable: " + Marshal.GetLastWin32Error());
                    var found = new HashSet<string>();
                    try {
                        var module = new ModuleEntry { size = (uint)Marshal.SizeOf<ModuleEntry>() };
                        bool more = Module32FirstW(snapshot, ref module);
                        if (!more) throw new Exception("Empty or inaccessible module inventory");
                        int count = 0;
                        while (more) {
                            if (++count > 4096 || module.path.Length >= 259) throw new Exception("Module inventory exceeds limits");
                            // Full file identity distinguishes identical basenames and C:/Z: aliases.
                            if (modules.Any(x => string.Equals(Path.GetFileName(x), Path.GetFileName(module.path), StringComparison.OrdinalIgnoreCase))) found.Add(Identity(module.path));
                            more = Module32NextW(snapshot, ref module);
                        }
                        if (Marshal.GetLastWin32Error() != 18) throw new Exception("Incomplete module inventory");
                    } finally { CloseHandle(snapshot); }
                    if (Identity(Image(handle)) != gameID || !GetProcessTimes(handle, out var after, out var exited, out _, out _) || after != created || exited != 0) throw new Exception("Game exited or changed during inventory");
                    matches.Add(new { pid = entry.pid, created = created.ToString(), loaded = expected.Select(id => found.Contains(id)).ToArray() });
                } finally { CloseHandle(handle); }
                next = Process32NextW(processes, ref entry);
            }
            if (Marshal.GetLastWin32Error() != 18) throw new Exception("Incomplete process inventory");
        } finally { CloseHandle(processes); }
        return new { ok = true, complete = true, nonce, processes = matches, unreadable };
    }
    static int Main(string[] args) {
        if (args.Length != 2 || !Path.IsPathFullyQualified(args[0]) || !Path.IsPathFullyQualified(args[1])) return 2;
        object result; int code = 0;
        try {
            if (new System.IO.FileInfo(args[0]).Length > 1024 * 1024) throw new Exception("Request exceeds size limit");
            using var document = JsonDocument.Parse(File.ReadAllBytes(args[0])); result = Inventory(document.RootElement);
        } catch (Exception error) { result = new { ok = false, complete = false, error = error.Message }; code = 1; }
        File.WriteAllText(args[1], JsonSerializer.Serialize(result)); return code;
    }
}

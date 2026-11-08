using SharpCompress.Archives;
using SharpCompress.Common;
using SharpCompress.Readers;
using System.Text;

internal static class PatchArchive
{
    public static async Task<object> Extract(Request r, CancellationToken ct)
    {
        var library = r.Operation == "library-import";
        var entryLimit = library ? 64L * 1024 * 1024 : 256L * 1024 * 1024;
        var totalLimit = library ? 256L * 1024 * 1024 : 512L * 1024 * 1024;
        bool Selected(IEntry entry) => !library || new[] { ".lua", ".manifest", ".bin" }.Contains(Path.GetExtension(entry.Key ?? ""), StringComparer.OrdinalIgnoreCase);
        if (!Path.IsPathFullyQualified(r.Archive) || !Path.IsPathFullyQualified(r.Destination) || Directory.Exists(r.Destination) || File.Exists(r.Destination)) throw new Exception("Extraction requires an existing archive and a new absolute destination");
        if (new FileInfo(r.Archive).Length > 2L * 1024 * 1024 * 1024) throw new Exception("Archive exceeds 2 GiB");
        var stage = r.Destination + ".extract-" + Guid.NewGuid().ToString("N");
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(stage);
        else Directory.CreateDirectory(stage, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try
        {
            using var archive = ArchiveFactory.OpenArchive(r.Archive, new ReaderOptions { Password = r.Password });
            var entries = archive.Entries.ToArray();
            if (entries.Length == 0 || entries.Length > (library ? 4096 : 10000)) throw new Exception("Archive entry count is out of range");
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var files = new List<string>(); long total = 0;
            foreach (var entry in entries)
            {
                var name = (entry.Key ?? "").Replace('\\', '/').TrimEnd('/');
                var parts = name.Split('/'); var attrs = entry is SharpCompress.Common.Tar.TarEntry tar ? (int)tar.Mode : entry.Attrib ?? 0;
                if (name.Length is 0 or > 1024 || name.StartsWith('/') || name.Contains(':') || name.Contains('\0') || parts.Any(x => x is "" or "." or ".." || x.EndsWith(' ') || x.EndsWith('.')) || !string.IsNullOrEmpty(entry.LinkTarget) || (attrs & 0xf000) == 0xa000 || ((attrs >> 16) & 0xf000) == 0xa000 || !seen.Add(name.Normalize(NormalizationForm.FormC))) throw new Exception("Unsafe or duplicate archive entry: " + name);
                if (entry.Size < 0 || entry.Size > entryLimit) throw new Exception("Archive entry exceeds size limit");
                total += entry.Size; if (total > totalLimit) throw new Exception("Expanded archive exceeds size limit");
            }
            total = 0;
            var metadata = entries.ToDictionary(e => e.Key!, StringComparer.Ordinal);
            // A solid 7z/RAR stream must be read once in archive order.
            // Opening each entry independently repeatedly decompresses the same block.
            async Task WriteEntry(IEntry entry, Func<Stream> open)
            {
                ct.ThrowIfCancellationRequested();
                if (entry.Key == null || !metadata.TryGetValue(entry.Key, out var expected)) throw new Exception("Archive entry changed during extraction");
                var name = entry.Key.Replace('\\', '/').TrimEnd('/'); var target = Path.Combine(stage, name);
                if (entry.IsDirectory) { if (!library) Directory.CreateDirectory(target); return; }
                if (!Selected(entry)) return;
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                await using var input = open();
                await using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write);
                var buffer = new byte[65536]; long done = 0; uint crc = 0xffffffff; int count;
                while ((count = await input.ReadAsync(buffer, ct)) > 0)
                {
                    done += count; total += count;
                    if (done > entryLimit || total > totalLimit) throw new Exception("Expanded patch exceeds size limit");
                    for (int i = 0; i < count; i++) crc = CrcTable[(crc ^ buffer[i]) & 255] ^ (crc >> 8);
                    await output.WriteAsync(buffer.AsMemory(0, count), ct);
                }
                if (done != expected.Size || (archive.Type == ArchiveType.Zip || archive.Type == ArchiveType.Rar && expected.Crc != 0) && ~crc != (uint)expected.Crc) throw new Exception("Archive size or checksum mismatch: " + name);
                files.Add(name);
            }
            if (archive.IsSolid || archive.Type == ArchiveType.SevenZip) {
                using var reader = archive.ExtractAllEntries();
                while (reader.MoveToNextEntry()) await WriteEntry(reader.Entry, () => reader.OpenEntryStream());
            } else {
                foreach (var entry in entries) await WriteEntry(entry, () => entry.OpenEntryStream());
            }
            if (files.Count == 0) throw new Exception("Archive contains no files");
            Directory.Move(stage, r.Destination);
            return new { ok = true, path = r.Destination, patchFiles = files };
        }
        finally { if (Directory.Exists(stage)) Directory.Delete(stage, true); }
    }
    static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n => { uint value = (uint)n; for (int i = 0; i < 8; i++) value = (value & 1) != 0 ? 0xedb88320 ^ (value >> 1) : value >> 1; return value; }).ToArray();
}

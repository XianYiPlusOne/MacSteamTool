import Foundation

public enum WineOverrides {
    public static func edit(_ data: Data, executable: String, libraries: [String]) throws -> Data {
        guard var text = String(data: data, encoding: .utf8), text.hasPrefix("WINE REGISTRY Version 2"), executable.lowercased().hasSuffix(".exe"),
              !executable.isEmpty, executable == URL(fileURLWithPath: executable).lastPathComponent,
              !executable.contains(where: { "\\\"[]\n\r\0".contains($0) }) else { throw AppFailure("Wine 注册表或游戏执行文件名无效 / Invalid Wine registry or game executable name") }
        let names = Array(Set(libraries.map { $0.lowercased() })).sorted()
        guard !names.isEmpty, names.count <= 64, names.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 } }) else { throw AppFailure("DLL 名称只能包含字母、数字、下划线或连字符，不带 .dll / DLL names allow letters, digits, underscores and hyphens; omit .dll") }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        let header = "[Software\\\\Wine\\\\AppDefaults\\\\\(executable)\\\\DllOverrides]"
        let matches = lines.indices.filter { lines[$0].lowercased().hasPrefix(header.lowercased()) }
        guard matches.count <= 1 else { throw AppFailure("Wine DLL 配置段重复 / Duplicate Wine DLL configuration sections") }
        if let begin = matches.first {
            let end = lines.indices.dropFirst(begin + 1).first { lines[$0].hasPrefix("[") } ?? lines.count
            var body = Array(lines[(begin + 1)..<end])
            for name in names {
                let key = "\"\(name)\"="
                let values = body.indices.filter { body[$0].lowercased().hasPrefix(key) }
                guard values.count <= 1, values.allSatisfy({ body[$0].dropFirst(key.count).hasPrefix("\"") && body[$0].hasSuffix("\"") }) else { throw AppFailure("DLL 覆盖项不是单一字符串 / DLL override must be a single string：\(name)") }
                if let index = values.first { body[index] = key + "\"native,builtin\"" }
                else { body.insert(key + "\"native,builtin\"", at: 0) }
            }
            lines.replaceSubrange((begin + 1)..<end, with: body)
        } else {
            lines += [header + " \(Int(Date().timeIntervalSince1970))"] + names.map { "\"\($0)\"=\"native,builtin\"" } + [""]
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
    public static func suggested(_ plan: PatchPlan) -> [String] {
        let shims: Set<String> = ["d3d9", "d3d11", "d3d12", "dxgi", "version", "winmm", "winhttp", "wininet", "dsound", "dinput8", "xinput1_3", "xinput1_4", "xinput9_1_0"]
        return Array(Set(plan.entries.compactMap { entry -> String? in
            let url = URL(fileURLWithPath: entry.relative)
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            return url.pathExtension.lowercased() == "dll" && shims.contains(base) ? base : nil
        })).sorted()
    }
    public static func executable(_ url: URL, inside root: URL) throws -> String {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        guard normalized.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), url.pathExtension.lowercased() == "exe" else { throw AppFailure("请选择目标游戏目录中的 Windows .exe / Select a Windows .exe inside the target game directory") }
        let handle = try FileHandle(forReadingFrom: normalized); defer { try? handle.close() }
        let header = try handle.read(upToCount: 64) ?? Data()
        guard header.count == 64, header[0] == 0x4d, header[1] == 0x5a else { throw AppFailure("选择的文件不是 Windows PE 程序 / Selected file is not a Windows PE executable") }
        let offset = header[60..<64].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        guard offset >= 64, offset <= 16 * 1024 * 1024 else { throw AppFailure("Windows PE 头偏移无效 / Invalid Windows PE header offset") }
        try handle.seek(toOffset: offset)
        guard try handle.read(upToCount: 4) == Data([0x50,0x45,0,0]) else { throw AppFailure("Windows PE 签名无效 / Invalid Windows PE signature") }
        return normalized.lastPathComponent
    }
}

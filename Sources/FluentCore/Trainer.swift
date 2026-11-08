import Foundation

public struct TrainerOption: Identifiable, Sendable {
    public var id: String { key + "\n" + description }
    public var key: String
    public var description: String
}

public enum TrainerConfiguration {
    /// Read strings without loading or executing the Windows PE file.
    public static func options(in executable: URL) throws -> [TrainerOption] {
        guard (try executable.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 100 * 1024 * 1024 else { throw AppFailure("修改器超过 100 MiB，无法自动读取功能列表；可手动填写快捷键 / Trainer exceeds 100 MiB; enter hotkeys manually instead of automatic inspection") }
        let data = try FileStore.read(executable)
        var strings = Set<String>()
        for offset in [0, 1] {
            var units: [UInt16] = []
            func flush() { if units.count >= 6 { strings.insert(String(decoding: units, as: UTF16.self)) }; units.removeAll(keepingCapacity: true) }
            var i = offset
            while i + 1 < data.count {
                let cp = UInt16(data[i]) | UInt16(data[i + 1]) << 8
                if (0x20...0x7e).contains(cp) || (0x3000...0x303f).contains(cp) || (0x3400...0x9fff).contains(cp) || (0xff00...0xffef).contains(cp) { units.append(cp); if units.count > 2048 { flush() } }
                else { flush() }
                i += 2
            }
            flush()
        }
        let pattern = #"^((?:(?:Ctrl|Alt|Shift)\+)*)((?:数字键|Num)\s*[0-9+*/.\-]|F\s*\d{1,2})\s*-\s*(.+)$"#
        let operators = ["+": "Add", "-": "Subtract", "*": "Multiply", "/": "Divide", ".": "Decimal"]
        var options: [String: TrainerOption] = [:]
        for text in strings.sorted() {
            guard let match = TextUtil.matches(pattern, text).first else { continue }
            var key = match[2].replacingOccurrences(of: "数字键", with: "Num").replacingOccurrences(of: " ", with: "")
            if key.hasPrefix("Num"), let op = operators[String(key.dropFirst(3))] { key = "Num" + op }
            key = match[1] + key
            guard (try? shortcuts(key)) != nil else { continue }
            var description = match[3].components(separatedBy: " --").first ?? match[3]
            description = description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { continue }
            options[key + "\n" + description] = TrainerOption(key: key, description: description)
        }
        return options.values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
    public static func windowsPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw AppFailure("请选择有效的本地绝对路径 / Select a valid absolute local path") }
        return "Z:" + URL(fileURLWithPath: path).resolvingSymlinksInPath().path.replacingOccurrences(of: "/", with: "\\")
    }
    public static func shortcuts(_ text: String) throws -> [String] {
        let values = text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard values.count <= 30 else { throw AppFailure("最多设置 30 个快捷键 / At most 30 hotkeys are allowed") }
        let named: Set<String> = ["CTRL", "CONTROL", "SHIFT", "ALT", "INSERT", "DELETE", "HOME", "END", "PAGEUP", "PAGEDOWN", "NUMMULTIPLY", "NUMADD", "NUMSUBTRACT", "NUMDECIMAL", "NUMDIVIDE"]
        for value in values {
            let parts = value.uppercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard (1...4).contains(parts.count), Set(parts).count == parts.count else { throw AppFailure("无效快捷键 / Invalid hotkey：\(value)") }
            for part in parts {
                let valid = named.contains(part) || (part.count == 1 && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }) || (part.hasPrefix("F") && Int(part.dropFirst()).map { (1...24).contains($0) } == true) || (part.hasPrefix("NUM") && part.count == 4 && Int(part.dropFirst(3)).map { (0...9).contains($0) } == true)
                guard valid else { throw AppFailure("不支持的快捷键 / Unsupported hotkey：\(value)。示例：F1、Ctrl+Num1、Alt+F2 / Examples: F1, Ctrl+Num1, Alt+F2") }
            }
        }
        return values
    }
    public static func validate(_ binding: TrainerBinding) throws {
        guard UInt32(exactly: binding.appID) != nil, binding.appID > 0 else { throw AppFailure("无效 AppID / Invalid AppID") }
        guard let game = binding.gameExecutable, !game.isEmpty else { throw AppFailure("请先选择要监控的游戏 .exe / Select the game executable to monitor first") }
        for path in [game, binding.executable] {
            _ = try windowsPath(path)
            guard path.lowercased().hasSuffix(".exe"), FileManager.default.fileExists(atPath: path), (try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw AppFailure("找不到可执行文件 / Executable not found：\(path)") }
        }
        guard try windowsPath(game).lowercased() != windowsPath(binding.executable).lowercased() else { throw AppFailure("游戏与修改器不能选择同一文件 / Game and trainer must use different executables") }
        _ = try shortcuts((binding.autoKeys ?? []).joined(separator: ","))
        guard (1...120).contains(binding.keyDelay ?? 5) else { throw AppFailure("快捷键延迟必须为 1–120 秒 / Hotkey delay must be 1–120 seconds") }
    }
}

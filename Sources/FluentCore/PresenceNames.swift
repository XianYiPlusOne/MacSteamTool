import Foundation

/// Keep the native automatic-presence title source in the application's language.
/// Only Apps comments change; all IDs, keys, settings and other bytes are retained.
public enum PresenceNames {
    public static func edit(_ bytes: Data, names: [Int: String]) throws -> Data {
        guard bytes.count <= 8 * 1024 * 1024, let text = String(data: bytes, encoding: .utf8) else { throw AppFailure("广播名称配置无效 / Invalid presence name configuration") }
        let config = try MacSteamConfig.parse(text)
        let baseApps = Set(config.topLevel)
        var section = ""
        let lines = text.components(separatedBy: "\n").map { original -> String in
            let ending = original.hasSuffix("\r") ? "\r" : ""
            let line = ending.isEmpty ? original : String(original.dropLast())
            if let first = line.first, !first.isWhitespace, first != "#" { section = line.trimmingCharacters(in: .whitespaces) }
            guard section == "Apps:",
                  let match = TextUtil.matches(#"^  -\s+(\d+)(?:\s*#.*)?$"#, line).first,
                  let id = TextUtil.validID(match[1]), baseApps.contains(id), let value = names[id] else { return original }
            let name = TextUtil.cleanLine(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 512, !value.contains("\0"),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  TextUtil.matches(#"@\d+"#, name).isEmpty, name != config.names[id] else { return original }
            return "  - \(id)  # \(name)" + ending
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
    @discardableResult public static func synchronize(paths: AppPaths, metadata: [Int: GameMetadata]) throws -> Bool {
        let runtime = try RuntimeFeatures.load(paths: paths)
        guard runtime.presence == .automatic || runtime.presence == .selected,
              FileStore.fm.fileExists(atPath: paths.config.path) else { return false }
        let before = try FileStore.read(paths.config)
        let names = metadata.filter { $0.key == $0.value.id && (runtime.presence == .automatic || runtime.presenceApps[String($0.key)] != nil) }.mapValues(\.name)
        let after = try edit(before, names: names)
        guard before != after else { return false }
        try FileTransaction(backupRoot: paths.backups).apply([(paths.config, after)], reason: "同步游戏广播名称 / Localize game presence names", expectations: [paths.config: FileStore.hash(before)])
        return true
    }
}

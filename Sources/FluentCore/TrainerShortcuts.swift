import Foundation

public enum TrainerShortcuts {
    public static func bindingID(_ url: URL) -> UUID? {
        guard url.scheme == "fluentsteam", url.host == "trainer", url.pathComponents.count == 2, url.query == nil, url.fragment == nil else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
    public static func create(_ binding: TrainerBinding, directory: URL) throws -> URL {
        let clean = binding.name.replacingOccurrences(of: #"[/\\:\x00-\x1F]"#, with: "_", options: .regularExpression)
        let file = directory.appendingPathComponent(String(clean.prefix(80)) + "-" + binding.id.uuidString.prefix(8) + ".webloc")
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": "fluentsteam://trainer/\(binding.id.uuidString)"], format: .xml, options: 0)
        if FileStore.fm.fileExists(atPath: file.path) {
            guard try FileStore.read(file) == data else { throw AppFailure("快捷方式同名文件已存在 / A different file occupies this shortcut name") }
        } else { try FileStore.write(data, to: file) }
        return file
    }
}

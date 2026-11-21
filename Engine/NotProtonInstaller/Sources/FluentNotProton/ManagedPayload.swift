import Foundation

enum ManagedPayload {
    struct Receipt: Codable {
        let provider: String
        let version: String
        let files: [String: String]
    }
    static func validate(_ request: InstallRequest, provider: String) throws {
        guard let path = request.managedRoot, let version = request.managedVersion else { throw StepFailure(step: "Components", detail: "Managed component metadata missing") }
        let root = URL(filePath: path).standardizedFileURL
        let allowed = URL(filePath: request.data).appending(path: "Components/\(provider)").standardizedFileURL
        guard root.path.hasPrefix(allowed.path + "/"), root.resolvingSymlinksInPath().path == root.path else { throw StepFailure(step: "Components", detail: "Managed component is outside this installation") }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: root.appending(path: "component.json")))
        guard receipt.provider == provider, receipt.version == version, !receipt.files.isEmpty else { throw StepFailure(step: "Components", detail: "Managed component identity mismatch") }
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { throw StepFailure(step: "Components", detail: "Managed directory missing") }
        var actual = Set<String>()
        for case let relative as String in walk {
            let file = root.appending(path: relative)
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw StepFailure(step: "Components", detail: "Managed payload contains a symlink") }
            if info.isRegularFile == true, relative != "component.json" { actual.insert(relative) }
        }
        guard actual == Set(receipt.files.keys) else { throw StepFailure(step: "Components", detail: "Managed payload inventory changed") }
        for (relative, hash) in receipt.files {
            let file = root.appending(path: relative)
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  Digest.sha256IfPresent(file) == hash else { throw StepFailure(step: "Components", detail: "Managed component integrity mismatch: \(relative)") }
        }
        let required = provider == "macsteam" ? "Resources/macsteam.dylib" : "NotProtonRuntime.bundle/Contents/Resources/payload/notproton.dylib"
        guard receipt.files[required] != nil else { throw StepFailure(step: "Components", detail: "Managed kernel missing from receipt") }
    }
}

import Foundation

extension ToolPackage {
    /// Keep the receipt and payload layout used by existing installations.
    public static func download(provider: String, to destination: URL, mirror: String?, cached: ToolPackage?) async throws -> String? {
        guard provider == "goldberg" else { throw AppFailure("Unknown tool provider") }
        let asset: ReleaseAsset
        var warning: String?
        let repository = "Detanup01/gbe_fork", name = "emu-win-release-vs22.7z"
        do {
            asset = try await ReleaseAssets.resolve(repository: repository) { _ in name }
        } catch {
            try Task.checkCancellation()
            let previous = cached?.provider == provider ? cached : nil
            let tag = previous?.version ?? "release-2026_09_27"
            let url = "https://github.com/\(repository)/releases/download/\(tag)/\(name)"
            asset = try ReleaseAsset(repository: repository, tag: tag, name: name, url: previous?.source ?? url,
                digest: "sha256:" + (previous?.archiveSHA256 ?? "300186c34f49a9ea75b33ce2af299267cc1dad0225cf45e81a229578d4e11c85"))
            warning = "无法查询最新版本，使用已校验版本 \(tag) / Using verified version \(tag)"
        }
        try await store(asset, provider: provider, version: asset.tag, to: destination, mirror: mirror) { url, output in
            try await ReleaseAssets.download(url, sha256: asset.sha256, to: output)
        }
        return warning
    }

    static func store(_ asset: ReleaseAsset, provider: String, version: String, to destination: URL, mirror: String?,
                      download: (URL, URL) async throws -> Void) async throws {
        guard !FileStore.fm.fileExists(atPath: destination.path) else { throw AppFailure("Tool package destination already exists") }
        let parent = destination.deletingLastPathComponent()
        try FileStore.mkdir(parent)
        let stage = parent.appendingPathComponent(".tool-" + UUID().uuidString)
        try FileStore.fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileStore.fm.removeItem(at: stage) }
        let archive = stage.appendingPathComponent(asset.name)
        var seen = Set<URL>()
        let mirrors = [mirror ?? "direct"] + DownloadSources.mirrors
        let candidates = mirrors.flatMap { DownloadSources.candidates(asset.url, preferred: $0) }.filter { seen.insert($0).inserted }
        var lastError: Error?
        for candidate in candidates {
            do {
                try Task.checkCancellation()
                try await download(candidate, archive)
                lastError = nil
                break
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        if let lastError { throw lastError }
        let files = try NativeArchive.extract(archive, to: stage.appendingPathComponent("payload"))
        let receipt = ToolPackage(provider: provider, version: version, source: asset.url.absoluteString, archiveSHA256: asset.sha256, files: files)
        try FileStore.json(receipt, to: stage.appendingPathComponent("tool.json"))
        try Task.checkCancellation()
        try FileStore.fm.moveItem(at: stage, to: destination)
    }
}

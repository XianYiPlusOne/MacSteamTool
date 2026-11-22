import Foundation
import ZIPFoundation

public struct OfficialRuntimeRelease: Codable, Sendable, Equatable {
    public var provider: String
    public var tag: String
    public var version: String
    public var assetName: String
    public var url: String
    public var sha256: String
    public var notes: String? = nil
    public var releaseURL: String
    public var appName: String { provider == "macsteam" ? "macSteam Config.app" : "NotProton.app" }
    public func validate() throws {
        let repository: String
        switch provider { case "macsteam": repository = "crghofficial/macsteam"; case "notproton": repository = "NotProtonNot/NotProton"; default: throw AppFailure("未知运行器 / Unknown runtime") }
        guard tag.range(of: #"^v?[0-9]+(?:\.[0-9]+){1,3}$"#, options: .regularExpression) != nil,
              version == (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag),
              assetName == (provider == "macsteam" ? "macSteam-\(version).dmg" : "NotProton.zip"),
              url == "https://github.com/\(repository)/releases/download/\(tag)/\(assetName)",
              releaseURL == "https://github.com/\(repository)/releases/tag/\(tag)",
              sha256.count == 64, sha256.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else { throw AppFailure("官方运行器元数据不匹配 / Official runtime metadata mismatch") }
    }
}
public struct PreparedRuntime: Sendable {
    public let application: URL
    public let release: OfficialRuntimeRelease
    public let supportedSteamBuilds: [String]
}
public enum OfficialRuntimeUpdates {
    public static func check(_ provider: String, tag: String? = nil) async throws -> OfficialRuntimeRelease {
        let repository: String
        switch provider {
        case "macsteam": repository = "crghofficial/macsteam"
        case "notproton": repository = "NotProtonNot/NotProton"
        default: throw AppFailure("Unknown runtime provider")
        }
        let asset = try await ReleaseAssets.resolve(repository: repository, tag: tag) { tag in
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return provider == "macsteam" ? "macSteam-\(version).dmg" : "NotProton.zip"
        }
        let version = asset.tag.hasPrefix("v") ? String(asset.tag.dropFirst()) : asset.tag
        let release = OfficialRuntimeRelease(provider: provider, tag: asset.tag, version: version, assetName: asset.name,
            url: asset.url.absoluteString, sha256: asset.sha256, notes: asset.notes,
            releaseURL: "https://github.com/\(repository)/releases/tag/\(asset.tag)")
        try release.validate()
        return release
    }
    public static func prepare(_ release: OfficialRuntimeRelease, cache: URL) async throws -> PreparedRuntime {
        try release.validate()
        let folder = cache.appendingPathComponent(UUID().uuidString)
        try FileStore.fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let archive = folder.appendingPathComponent(release.assetName)
            try await ReleaseAssets.download(URL(string: release.url)!, sha256: release.sha256, to: archive,
                hosts: ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"])
            let extracted = folder.appendingPathComponent("payload")
            try FileStore.mkdir(extracted)
            if release.assetName.hasSuffix(".zip") { try extractZIP(archive, into: extracted, appName: release.appName) }
            else { try await extractDMG(archive, into: extracted, appName: release.appName) }
            let app = extracted.appendingPathComponent(release.appName)
            let builds = try await validate(app, release: release)
            try FileStore.json(release, to: folder.appendingPathComponent("release.json"))
            try FileStore.fm.removeItem(at: archive)
            return PreparedRuntime(application: app, release: release, supportedSteamBuilds: builds)
        } catch { try? FileStore.fm.removeItem(at: folder); throw error }
    }
    /// Permit the relative framework links used by official macOS apps, while
    /// forbidding writes through links and validating their final destinations.
    static func extractZIP(_ url: URL, into folder: URL, appName: String) throws {
        let archive = try Archive(url: url, accessMode: .read), entries = Array(archive)
        guard !entries.isEmpty, entries.count <= 30000 else { throw AppFailure("运行器 ZIP 条目过多 / Runtime ZIP entry limit") }
        var seen = Set<String>(), links = Set<String>(); var total: UInt64 = 0
        for entry in entries {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, path.count <= 1024, !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  parts.first == Substring(appName) || parts.first == "__MACOSX",
                  seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw AppFailure("运行器 ZIP 路径不安全或重复 / Unsafe or duplicate runtime ZIP path") }
            total += UInt64(entry.uncompressedSize)
            guard total <= 1024 * 1024 * 1024, entry.uncompressedSize <= 256 * 1024 * 1024 else { throw AppFailure("运行器解压超过限制 / Runtime extraction limit") }
            if entry.type == .symlink { links.insert(path.precomposedStringWithCanonicalMapping.lowercased()) }
        }
        for entry in entries {
            let parts = entry.path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            for count in 1..<parts.count where links.contains(parts.prefix(count).joined(separator: "/")) { throw AppFailure("ZIP 条目穿过符号链接 / ZIP entry traverses a symlink") }
        }
        let selected = entries.filter { !$0.path.hasPrefix("__MACOSX/") && !$0.path.split(separator: "/").contains(where: { $0.hasPrefix("._") }) }
        for entry in selected.sorted(by: { ($0.type == .symlink ? 1 : 0) < ($1.type == .symlink ? 1 : 0) }) {
            try Task.checkCancellation()
            let target = folder.appendingPathComponent(entry.path)
            if entry.type == .symlink {
                var data = Data()
                let crc = try archive.extract(entry) { bytes in guard data.count + bytes.count <= 4096 else { throw AppFailure("符号链接过长 / Symlink too long") }; data.append(bytes) }
                guard crc == entry.checksum, let value = String(data: data, encoding: .utf8), !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0"), !value.contains("\\") else { throw AppFailure("无效的框架符号链接 / Invalid framework symlink") }
                let destination = target.deletingLastPathComponent().appendingPathComponent(value).standardizedFileURL
                guard destination.path.hasPrefix(folder.appendingPathComponent(appName).standardizedFileURL.path + "/") else { throw AppFailure("框架链接越出应用 / Framework link escapes application") }
                try FileStore.mkdir(target.deletingLastPathComponent()); try FileStore.fm.createSymbolicLink(atPath: target.path, withDestinationPath: value)
            } else {
                let crc = try archive.extract(entry, to: target)
                guard crc == entry.checksum else { throw AppFailure("运行器 ZIP 校验失败 / Runtime ZIP CRC mismatch") }
                let mode = ((try FileStore.fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0o644
                try FileStore.fm.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: target.path)
            }
        }
        try validateLinks(folder.appendingPathComponent(appName))
    }
    private static func extractDMG(_ archive: URL, into folder: URL, appName: String) async throws {
        let mount = folder.deletingLastPathComponent().appendingPathComponent("mount")
        try FileStore.mkdir(mount)
        let (code, message) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, archive.path])
        guard code == 0 else { throw AppFailure("无法挂载官方运行器 / Cannot mount official runtime: \(message.suffix(1000))") }
        var failure: Error?
        do {
            let source = mount.appendingPathComponent(appName)
            guard (try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
                  source.resolvingSymlinksInPath() == source.standardizedFileURL else { throw AppFailure("DMG 中缺少官方应用 / Official app missing in DMG") }
            try FileStore.fm.copyItem(at: source, to: folder.appendingPathComponent(appName))
        } catch { failure = error }
        // Finish unmounting even if the caller cancels during validation/copy.
        let (detach, detail) = try await Task.detached { try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path]) }.value
        guard detach == 0 else { throw AppFailure("运行器镜像未能卸载 / Runtime image detach failed: \(detail.suffix(1000))") }
        if let failure { throw failure }
    }
    static func validateLinks(_ app: URL) throws {
        let root = app.resolvingSymlinksInPath().path + "/"
        guard let iterator = FileStore.fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw AppFailure("应用目录不存在 / Application folder missing") }
        for case let url as URL in iterator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root), resolved != url.standardizedFileURL, FileStore.fm.fileExists(atPath: resolved.path) else { throw AppFailure("应用包含外部或无效链接 / Application contains an external or invalid link") }
            }
        }
    }
    public static func validate(_ app: URL, release: OfficialRuntimeRelease) async throws -> [String] {
        try release.validate()
        return try await validateApplication(app, provider: release.provider, version: release.version)
    }
    public static func validateApplication(_ app: URL, provider: String, version: String) async throws -> [String] {
        guard ["macsteam", "notproton"].contains(provider) else { throw AppFailure("Unknown runtime provider") }
        try validateLinks(app)
        let info = try PropertyListSerialization.propertyList(from: FileStore.read(app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
        let executable = provider == "macsteam" ? "MacsteamApp" : "NotProtonApp"
        guard info["CFBundleIdentifier"] as? String == (provider == "macsteam" ? "com.macsteam.app" : "com.notproton.NotProton"),
              info["CFBundleShortVersionString"] as? String == version, info["CFBundleExecutable"] as? String == executable else { throw AppFailure("官方应用标识或版本不符 / Official application identity or version mismatch") }
        let (code, detail) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path])
        guard code == 0 else { throw AppFailure("运行器代码签名校验失败 / Runtime code signature failed: \(detail.suffix(1000))") }
        let (arch, text) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", app.appendingPathComponent("Contents/MacOS/\(executable)").path])
        guard arch == 0, text.split(whereSeparator: \.isWhitespace).contains("arm64") else { throw AppFailure("运行器不支持 ARM64 / Runtime does not contain ARM64") }
        let payload = app.appendingPathComponent(provider == "macsteam" ? "Contents/Resources" : "Contents/Resources/NotProtonApp_NotProtonApp.bundle/Contents/Resources/payload")
        let required = provider == "macsteam" ? ["macsteam.dylib", "macsteam.dylib.version"] : ["notproton.dylib", "overlay-shim.dylib", "iconmaker", "appinfo", "run", "build-time"]
        guard required.allSatisfy({ FileStore.fm.fileExists(atPath: payload.appendingPathComponent($0).path) }) else { throw AppFailure("运行器缺少内核资源 / Runtime payload incomplete") }
        let builds = FileStore.files(payload.appendingPathComponent("signatures/macos.arm64")).filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.sorted()
        guard !builds.isEmpty else { throw AppFailure("运行器缺少 Steam 兼容数据 / Runtime Steam profiles missing") }; return builds
    }
}

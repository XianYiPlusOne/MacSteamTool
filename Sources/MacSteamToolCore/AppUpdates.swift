import Foundation
import CryptoKit
import ZIPFoundation
import Darwin

public struct UpdateRelease: Codable, Sendable, Equatable {
    public var version: String
    public var build: Int
    public var minimumOS: Int
    public var architecture: String
    public var url: String
    public var sha256: String
    public var size: Int
    public var notes: String
    public init(version: String, build: Int, minimumOS: Int = 14, architecture: String = "arm64", url: String, sha256: String, size: Int, notes: String = "") {
        self.version = version; self.build = build; self.minimumOS = minimumOS; self.architecture = architecture
        self.url = url; self.sha256 = sha256; self.size = size; self.notes = notes
    }
}
public struct SignedUpdate: Codable, Sendable {
    public var payload: Data
    public var signature: Data
    public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }
    public func verified(publicKey: Data) throws -> UpdateRelease {
        guard payload.count <= 64 * 1024, try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: payload) else { throw AppFailure("更新签名无效 / Invalid update signature") }
        let release = try JSONDecoder().decode(UpdateRelease.self, from: payload)
        guard release.build > 0, release.size > 0, release.size <= 256 * 1024 * 1024, release.sha256.count == 64, release.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }), !release.version.isEmpty, release.version.count < 50, release.notes.count < 16000 else { throw AppFailure("更新元数据无效 / Invalid update metadata") }
        return release
    }
}
public struct PreparedUpdate: Sendable {
    public let folder: URL
    public let application: URL
    public let release: UpdateRelease
}
public struct UpdateInstallPlan: Codable, Sendable {
    public let source: URL
    public let target: URL
    public let expectedSource: String
    public let expectedTarget: String
    public let parentPID: Int32
    public let build: Int
    public init(source: URL, target: URL, expectedSource: String, expectedTarget: String, parentPID: Int32, build: Int) {
        self.source = source; self.target = target; self.expectedSource = expectedSource; self.expectedTarget = expectedTarget; self.parentPID = parentPID; self.build = build
    }
}
public enum AppUpdates {
    public static let bundleID = "dev.macsteamtool.app"
    private static let updateBundles = ["MacSteamTool.app": "MacSteamTool", "Fluent Steam Mac.app": "FluentSteam"]
    public static func publicKey(bundle: Bundle = .main) throws -> Data {
        guard let path = bundle.url(forResource: "UpdatePublicKey", withExtension: "txt"), let key = Data(base64Encoded: try FileStore.text(path).trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else { throw AppFailure("缺少更新公钥 / Update public key missing") }; return key
    }
    public static func check(feed: URL, publicKey: Data, currentBuild: Int, allowFile: Bool = false) async throws -> (SignedUpdate, UpdateRelease)? {
        let data: Data
        if feed.isFileURL && allowFile { data = try FileStore.read(feed) } else {
            guard feed.scheme == "https", feed.user == nil, feed.password == nil else { throw AppFailure("更新源需要 HTTPS / Update feed requires HTTPS") }
            data = try await HTTP.get(feed, limit: 100 * 1024)
        }
        guard data.count <= 100 * 1024 else { throw AppFailure("更新元数据过大 / Update metadata too large") }
        let envelope = try JSONDecoder().decode(SignedUpdate.self, from: data), release = try envelope.verified(publicKey: publicKey)
        guard release.architecture == "arm64", release.minimumOS <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion else { throw AppFailure("更新不兼容此 Mac / Update does not support this Mac") }
        return release.build > currentBuild ? (envelope, release) : nil
    }
    public static func prepare(_ envelope: SignedUpdate, publicKey: Data, archive supplied: URL? = nil, staging: URL, currentBuild: Int, mirror: String? = nil) async throws -> PreparedUpdate {
        let release = try envelope.verified(publicKey: publicKey)
        guard release.build > currentBuild, release.architecture == "arm64", release.minimumOS <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion else { throw AppFailure("更新版本过旧或不兼容 / Update is older or incompatible") }
        let bytes: Data
        if let supplied { bytes = try FileStore.read(supplied) }
        else { guard let url = URL(string: release.url), url.scheme == "https" else { throw AppFailure("更新包需要 HTTPS / Update archive requires HTTPS") }; var downloaded: Data?, lastError: Error = AppFailure("下载失败 / Download failed")
            for candidate in DownloadSources.candidates(url, preferred: mirror) {
                do {
                    let data = try await HTTP.get(candidate, limit: 256 * 1024 * 1024, timeout: 120)
                    guard data.count == release.size, FileStore.hash(data) == release.sha256.lowercased() else { throw AppFailure("更新包摘要不符 / Update digest mismatch") }
                    downloaded = data; break
                } catch { if Task.isCancelled { throw CancellationError() }; lastError = error }
            }
            guard let downloaded else { throw lastError }; bytes = downloaded }
        guard bytes.count == release.size, FileStore.hash(bytes) == release.sha256.lowercased() else { throw AppFailure("更新包摘要或大小不符 / Update archive digest or size mismatch") }
        let folder = staging.appendingPathComponent(UUID().uuidString)
        try FileStore.fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let archive = try Archive(data: bytes, accessMode: .read); var seen = Set<String>(); var total: UInt64 = 0
            let entries = Array(archive)
            var bundleName: String?
            for e in entries {
                let components = e.path.split(separator: "/", omittingEmptySubsequences: false)
                guard e.type != .symlink, !e.path.hasPrefix("/"), !e.path.contains("\\"), !e.path.contains("\0"), !components.contains(".."), !components.contains("."), !components.dropLast().contains(""), seen.insert(e.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw AppFailure("更新 ZIP 路径不安全或重复 / Unsafe or duplicate update ZIP path") }
                total += UInt64(e.uncompressedSize)
                guard total <= 1024 * 1024 * 1024, entries.count <= 30000 else { throw AppFailure("更新解压超过限制 / Update extraction limit exceeded") }
                let top = String(components.first ?? "")
                if top == "__MACOSX" { continue }
                guard updateBundles[top] != nil, bundleName == nil || bundleName == top else { throw AppFailure("更新包只能包含一个 MacSteamTool 应用 / Unexpected update archive root") }
                bundleName = top
            }
            guard let bundleName, let executable = updateBundles[bundleName] else { throw AppFailure("更新包缺少应用 / Application missing from update archive") }
            for e in entries where !e.path.hasPrefix("__MACOSX/") && !e.path.split(separator: "/").contains(where: { $0.hasPrefix("._") }) {
                try Task.checkCancellation()
                let crc = try archive.extract(e, to: folder.appendingPathComponent(e.path))
                guard crc == e.checksum else { throw AppFailure("更新 CRC 不匹配 / Update CRC mismatch") }
            }
            let app = folder.appendingPathComponent(bundleName)
            try await validate(app, build: release.build, version: release.version, expectedExecutable: executable)
            try FileStore.json(envelope, to: folder.appendingPathComponent("release.json"))
            return PreparedUpdate(folder: folder, application: app, release: release)
        } catch { try? FileStore.fm.removeItem(at: folder); throw error }
    }
    public static func validate(_ app: URL, build: Int? = nil, version: String? = nil, expectedExecutable: String? = nil) async throws {
        let info = try PropertyListSerialization.propertyList(from: FileStore.read(app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
        let identifier = info["CFBundleIdentifier"] as? String
        guard let executable = info["CFBundleExecutable"] as? String, updateBundles.values.contains(executable),
              (identifier == bundleID && executable == "MacSteamTool") || identifier == "dev.fluentsteam.mac",
              expectedExecutable == nil || expectedExecutable == executable,
              let n = Int(info["CFBundleVersion"] as? String ?? ""), build == nil || n == build,
              version == nil || info["CFBundleShortVersionString"] as? String == version else { throw AppFailure("应用标识或版本不匹配 / Application identity or version mismatch") }
        let (code, diagnostic) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", "--verbose=4", app.path])
        guard code == 0 else { throw AppFailure("应用代码签名校验失败 / Application code signature verification failed: \(diagnostic.suffix(1500))") }
        let (arch, result) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path])
        guard arch == 0, result.split(whereSeparator: \.isWhitespace).contains("arm64") else { throw AppFailure("更新没有 ARM64 可执行文件 / Update has no ARM64 executable") }
    }
    public static func treeHash(_ folder: URL) throws -> String {
        let root = folder.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else { throw AppFailure("更新路径包含符号链接 / Update path contains a symlink") }
        var hash = SHA256()
        func visit(_ directory: URL, relative: String) throws {
            for name in try FileStore.fm.contentsOfDirectory(atPath: directory.path).sorted() {
                let file = directory.appendingPathComponent(name), path = relative + "/" + name
                let attrs = try FileStore.fm.attributesOfItem(atPath: file.path), type = attrs[.type] as? FileAttributeType
                if type == .typeDirectory { try visit(file, relative: path) }
                else if type == .typeRegular {
                    hash.update(data: Data(path.utf8)); hash.update(data: Data([0]))
                    hash.update(data: Data("\((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0):".utf8))
                    hash.update(data: SHA256.hash(data: try FileStore.read(file)).withUnsafeBytes { Data($0) })
                } else { throw AppFailure("更新应用内包含链接或特殊文件 / Update contains links or special files") }
            }
        }
        try visit(root, relative: "")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Run by a copied helper after the GUI exits. Rollback stays next to the application.
    public static func install(_ plan: UpdateInstallPlan) async throws -> URL {
        let target = plan.target.standardizedFileURL, parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", target != plan.source.standardizedFileURL, FileStore.fm.isWritableFile(atPath: parent.path), plan.parentPID >= 0 else { throw AppFailure("更新目标不可写 / Update target is not writable") }
        let lock = parent.appendingPathComponent(".fluent-update.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppFailure("无法锁定更新目录 / Cannot lock update folder") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure("另一更新正在进行 / Another update is active") }
        for _ in 0..<120 where plan.parentPID > 0 && kill(plan.parentPID, 0) == 0 { try await Task.sleep(for: .milliseconds(500)) }
        guard plan.parentPID == 0 || kill(plan.parentPID, 0) != 0 else { throw AppFailure("应用仍在运行，未替换 / Application is still running; replacement cancelled") }
        guard try treeHash(target) == plan.expectedTarget, try treeHash(plan.source) == plan.expectedSource else { throw AppFailure("更新文件已变更，未替换 / Update files changed; replacement cancelled") }
        try await validate(target); try await validate(plan.source, build: plan.build)
        let token = UUID().uuidString, candidate = parent.appendingPathComponent(".fluent-update-\(token).app"), backup = parent.appendingPathComponent("MacSteamTool.before-\(token).app")
        var keepCandidate = false
        defer { if !keepCandidate { try? FileStore.fm.removeItem(at: candidate) } }
        try FileStore.fm.copyItem(at: plan.source, to: candidate)
        guard try treeHash(candidate) == plan.expectedSource else { throw AppFailure("更新复制校验失败 / Update copy verification failed") }
        // Atomic exchange keeps the installed app present even if the helper crashes.
        guard renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try await validate(target, build: plan.build); try FileStore.fm.moveItem(at: candidate, to: backup) }
        catch {
            guard renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0 else { keepCandidate = true; throw AppFailure("更新回滚失败，原应用保留在 \(candidate.path) / Rollback failed; original app retained") }
            throw error
        }
        return backup
    }
}

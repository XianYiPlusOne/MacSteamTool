import Foundation
import CryptoKit
import ZIPFoundation
import Darwin

public enum UpdateEdition: String, Codable, Sendable {
    case local, standard
    fileprivate var bundles: [String: String] {
        switch self {
        case .local: return ["MacSteamTool Local.app": "MacSteamToolLocal"]
        case .standard: return ["MacSteamTool.app": "MacSteamTool", "Fluent Steam Mac.app": "FluentSteam"]
        }
    }
}
public struct UpdateRelease: Codable, Sendable, Equatable {
    public var version: String
    public var build: Int
    public var minimumOS: Int
    public var edition: UpdateEdition?
    public var architecture: String
    public var url: String
    public var sha256: String
    public var size: Int
    public var notes: String
    public init(version: String, build: Int, minimumOS: Int = 14, architecture: String = AppUpdates.architecture, edition: UpdateEdition? = nil, url: String, sha256: String, size: Int, notes: String = "") {
        self.version = version; self.build = build; self.minimumOS = minimumOS; self.architecture = architecture; self.edition = edition
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
    public let edition: UpdateEdition?
    public let parentPID: Int32
    public let build: Int
    public init(source: URL, target: URL, expectedSource: String, expectedTarget: String, parentPID: Int32, build: Int, edition: UpdateEdition? = nil) {
        self.source = source; self.target = target; self.expectedSource = expectedSource; self.expectedTarget = expectedTarget; self.parentPID = parentPID; self.build = build; self.edition = edition
    }
}
public enum AppUpdates {
    public static let bundleID = "dev.macsteamtool.app"
    #if arch(x86_64)
    public static let architecture = "x86_64"
    #elseif arch(arm64)
    public static let architecture = "arm64"
    #else
    #error("Unsupported macOS architecture")
    #endif
    public static func feedURL(_ setting: String) -> URL? {
        let text = setting.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{arch}", with: architecture)
        guard let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    private static func compatible(_ release: UpdateRelease, edition: UpdateEdition) -> Bool {
        (release.edition ?? .standard) == edition && release.architecture == architecture
            && release.minimumOS <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
    public static func publicKey(bundle: Bundle = .main) throws -> Data {
        guard let path = bundle.url(forResource: "UpdatePublicKey", withExtension: "txt"), let key = Data(base64Encoded: try FileStore.text(path).trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else { throw AppFailure("缺少更新公钥 / Update public key missing") }; return key
    }
    public static func check(feed: URL, publicKey: Data, currentBuild: Int, allowFile: Bool = false, edition: UpdateEdition = .standard) async throws -> (SignedUpdate, UpdateRelease)? {
        let data: Data
        if feed.isFileURL && allowFile { data = try FileStore.read(feed) } else {
            guard feed.scheme == "https", feed.user == nil, feed.password == nil else { throw AppFailure("更新源需要 HTTPS / Update feed requires HTTPS") }
            data = try await HTTP.get(feed, limit: 100 * 1024)
        }
        guard data.count <= 100 * 1024 else { throw AppFailure("更新元数据过大 / Update metadata too large") }
        let envelope = try JSONDecoder().decode(SignedUpdate.self, from: data), release = try envelope.verified(publicKey: publicKey)
        guard compatible(release, edition: edition) else { throw AppFailure("更新不兼容此 Mac / Update does not support this Mac") }
        return release.build > currentBuild ? (envelope, release) : nil
    }
    public static func prepare(_ envelope: SignedUpdate, publicKey: Data, archive supplied: URL? = nil, staging: URL, currentBuild: Int, mirror: String? = nil, edition: UpdateEdition = .standard) async throws -> PreparedUpdate {
        let release = try envelope.verified(publicKey: publicKey)
        guard release.build > currentBuild, compatible(release, edition: edition) else { throw AppFailure("更新版本过旧或不兼容 / Update is older or incompatible") }
        let bytes: Data
        if let supplied { bytes = try FileStore.read(supplied) }
        else { guard let url = URL(string: release.url), url.scheme == "https" else { throw AppFailure("更新包需要 HTTPS / Update archive requires HTTPS") }; var downloaded: Data?, lastError: Error = AppFailure("下载失败 / Download failed")
            for candidate in DownloadMirrors.candidates(url, preferred: mirror) {
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
                guard edition.bundles[top] != nil, bundleName == nil || bundleName == top else { throw AppFailure("更新包只能包含一个 MacSteamTool 应用 / Unexpected update archive root") }
                bundleName = top
            }
            guard let bundleName, let executable = edition.bundles[bundleName] else { throw AppFailure("更新包缺少应用 / Application missing from update archive") }
            for e in entries where !e.path.hasPrefix("__MACOSX/") && !e.path.split(separator: "/").contains(where: { $0.hasPrefix("._") }) {
                try Task.checkCancellation()
                let crc = try archive.extract(e, to: folder.appendingPathComponent(e.path))
                guard crc == e.checksum else { throw AppFailure("更新 CRC 不匹配 / Update CRC mismatch") }
            }
            let app = folder.appendingPathComponent(bundleName)
            try await validate(app, build: release.build, version: release.version, expectedExecutable: executable, edition: edition)
            try FileStore.json(envelope, to: folder.appendingPathComponent("release.json"))
            return PreparedUpdate(folder: folder, application: app, release: release)
        } catch { try? FileStore.fm.removeItem(at: folder); throw error }
    }
    public static func validate(_ app: URL, build: Int? = nil, version: String? = nil, expectedExecutable: String? = nil, edition: UpdateEdition = .standard) async throws {
        let info = try PropertyListSerialization.propertyList(from: FileStore.read(app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
        let identifier = info["CFBundleIdentifier"] as? String
        guard let executable = info["CFBundleExecutable"] as? String, edition.bundles.values.contains(executable),
              (edition == .local ? identifier == "dev.macsteamtool.local" :
                ((identifier == bundleID && executable == "MacSteamTool") || identifier == "dev.fluentsteam.mac")),
              expectedExecutable == nil || expectedExecutable == executable,
              let n = Int(info["CFBundleVersion"] as? String ?? ""), build == nil || n == build,
              version == nil || info["CFBundleShortVersionString"] as? String == version else { throw AppFailure("应用标识或版本不匹配 / Application identity or version mismatch") }
        let (code, diagnostic) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", "--verbose=4", app.path])
        guard code == 0 else { throw AppFailure("应用代码签名校验失败 / Application code signature verification failed: \(diagnostic.suffix(1500))") }
        let macOS = app.appendingPathComponent("Contents/MacOS")
        var binaries = [executable]
        for helper in ["MacSteamToolUpdater", "MacSteamToolWorker", "MacSteamToolRuntime"] {
            if FileStore.fm.fileExists(atPath: macOS.appendingPathComponent(helper).path) || (edition == .local && helper == "MacSteamToolUpdater") {
                binaries.append(helper)
            }
        }
        for binary in binaries {
            let file = macOS.appendingPathComponent(binary)
            guard try containsNativeSlice(file) else {
                throw AppFailure("更新组件缺少 \(architecture) 架构 / Missing \(architecture) slice: \(binary)")
            }
        }
    }
    // Read the Mach-O header directly so checking an update needs no developer tools.
    private static func containsNativeSlice(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = Array(try handle.read(upToCount: 4096) ?? Data())
        guard bytes.count >= 8 else { return false }
        func word(_ offset: Int, littleEndian: Bool) -> UInt32 {
            let slice = bytes[offset..<(offset + 4)]
            return (littleEndian ? Array(slice.reversed()) : Array(slice)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let cpu = UInt32(architecture == "arm64" ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64)
        let magic = word(0, littleEndian: false)
        switch magic {
        case MH_MAGIC_64, MH_CIGAM_64:
            return word(4, littleEndian: magic == MH_CIGAM_64) == cpu
        case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
            let little = magic == FAT_CIGAM || magic == FAT_CIGAM_64
            let stride = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) ? 32 : 20
            let count = Int(word(4, littleEndian: little))
            guard count <= (bytes.count - 8) / stride else { return false }
            return (0..<count).contains { word(8 + $0 * stride, littleEndian: little) == cpu }
        default:
            return false
        }
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
        let edition = plan.edition ?? .standard
        try await validate(target, edition: edition); try await validate(plan.source, build: plan.build, edition: edition)
        let token = UUID().uuidString, candidate = parent.appendingPathComponent(".fluent-update-\(token).app"), backup = parent.appendingPathComponent("MacSteamTool.before-\(token).app")
        var keepCandidate = false
        defer { if !keepCandidate { try? FileStore.fm.removeItem(at: candidate) } }
        try FileStore.fm.copyItem(at: plan.source, to: candidate)
        guard try treeHash(candidate) == plan.expectedSource else { throw AppFailure("更新复制校验失败 / Update copy verification failed") }
        // Atomic exchange keeps the installed app present even if the helper crashes.
        guard renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try await validate(target, build: plan.build, edition: edition); try FileStore.fm.moveItem(at: candidate, to: backup) }
        catch {
            guard renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0 else { keepCandidate = true; throw AppFailure("更新回滚失败，原应用保留在 \(candidate.path) / Rollback failed; original app retained") }
            throw error
        }
        return backup
    }
}

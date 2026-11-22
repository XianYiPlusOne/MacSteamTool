import Foundation
import CryptoKit
import Darwin

public struct AppFailure: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum TextUtil {
    public static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
    public static func cleanLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\0", with: "")
    }
    public static func validID(_ value: String) -> Int? {
        guard let id = UInt32(value), id > 0 else { return nil }; return Int(id)
    }
    public static func validKey(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

public enum FileStore {
    public static let fm = FileManager.default
    public static func mkdir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    public static func read(_ url: URL) throws -> Data {
        // fstat avoids Foundation's extended-attribute enumeration, which can block on
        // File Provider / privacy-mediated locations. Read the same verified descriptor.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AppFailure("只能读取普通文件 / Only regular files can be read：\(url.lastPathComponent)") }
        let limit = 256 * 1024 * 1024
        guard info.st_size <= limit else { throw AppFailure("文件过大 / File exceeds the size limit：\(url.lastPathComponent)") }
        var data = Data()
        while let part = try handle.read(upToCount: 1_048_576), !part.isEmpty {
            guard data.count + part.count <= limit else { throw AppFailure("文件读取超过大小限制 / Read exceeded the file size limit") }; data.append(part)
        }
        return data
    }
    public static func fingerprint(_ url: URL) -> String {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return "\(url.path):missing" }
        return "\(url.path):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }
    public static func text(_ url: URL) throws -> String {
        guard let text = String(data: try read(url), encoding: .utf8) else { throw AppFailure("文件不是 UTF-8 / File is not UTF-8：\(url.lastPathComponent)") }; return text
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func write(_ data: Data, to url: URL) throws {
        try mkdir(url.deletingLastPathComponent())
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw AppFailure("拒绝覆盖符号链接 / Refusing to overwrite a symbolic link：\(url.lastPathComponent)") }
        try data.write(to: url, options: .atomic)
    }
    public static func json<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try write(encoder.encode(value), to: url)
    }
    public static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T { try JSONDecoder().decode(type, from: read(url)) }
    public static func files(_ dir: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    }
}

public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) async throws -> (Int32, String) {
        try await Task.detached {
            let process = Process(); process.executableURL = executable; process.arguments = arguments
            if let environment { process.environment = environment }
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data.suffix(1_000_000), as: UTF8.self))
        }.value
    }
}

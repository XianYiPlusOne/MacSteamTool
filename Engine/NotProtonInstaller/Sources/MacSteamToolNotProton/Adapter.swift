import Foundation
extension Bundle {
    static var module: Bundle { Bundle(path: ProcessInfo.processInfo.environment["FLUENT_NOTPROTON_RESOURCES"] ?? "") ?? .main }
}
enum AppVersion { static var bundled: String { ProcessInfo.processInfo.environment["FLUENT_NOTPROTON_VERSION"] ?? "unknown" } }
enum AppLog { static func note(_ message: String) { FileHandle.standardError.write(Data((message+"\n").utf8)) } }

import Foundation
extension Bundle {
    static var module: Bundle { Bundle(path: ProcessInfo.processInfo.environment["FLUENT_NOTPROTON_RESOURCES"] ?? "") ?? .main }
}
enum AppVersion { static var bundled: String { ProcessInfo.processInfo.environment["FLUENT_NOTPROTON_VERSION"] ?? "unknown" } }
enum AppLog { static func note(_ message: String) { FileHandle.standardError.write(Data((message+"\n").utf8)) } }
enum RebuildPrefixCommand {
    static func recordExecutable(_ url: URL,in directory: URL) throws {
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        guard !readOnly, !url.pathComponents.contains("AppTranslocation") else { throw StepFailure(step: "Record companion", detail: "Move NotProton to a permanent writable location") }
        // Keep the official companion as the prefix rebuild handler.
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories:true)
        try Data(url.path.utf8).write(to:directory.appending(path:"app-executable"),options:.atomic)
    }
}

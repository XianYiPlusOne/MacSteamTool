import Foundation
import AppKit

/// Builds and signs a replacement bundle before swapping it into place.
/// Each operation retains the entire original bundle, including signatures.
public enum KernelDeployment {
    // Installed filenames are part of existing Steam configurations.
    static let bundledExtensions = [
        (installed: "cloud_redirect.dylib", folder: "Cloud", file: "cloud_redirect.dylib"),
        (installed: "fluent_manifest.dylib", folder: "Manifest", file: "manifest.dylib")
    ]
    public static let names = ["macsteam.dylib", "notproton.dylib"] + bundledExtensions.map(\.installed)
    public static func mergedPlist(_ data: Data, library: String, install: Bool) throws -> Data {
        guard library.hasPrefix("/"), !library.contains(":"), !library.contains("\0"), names.contains(URL(fileURLWithPath: library).lastPathComponent),
              var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "com.valvesoftware.steam" else { throw AppFailure("Steam bundle 或内核路径无效 / Invalid Steam bundle or kernel path") }
        var env = plist["LSEnvironment"] as? [String: Any] ?? [:]
        var libraries = (env["DYLD_INSERT_LIBRARIES"] as? String ?? "").split(separator: ":").map(String.init)
        libraries.removeAll { URL(fileURLWithPath: $0).lastPathComponent == URL(fileURLWithPath: library).lastPathComponent }
        if install { libraries.append(library) }
        if libraries.isEmpty { env.removeValue(forKey: "DYLD_INSERT_LIBRARIES") } else { env["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":") }
        if env.isEmpty { plist.removeValue(forKey: "LSEnvironment") } else { plist["LSEnvironment"] = env }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
    public static func deploy(name: String, source: URL?, paths: AppPaths) async throws -> URL {
        try await RuntimeInstaller.run(paths: paths, kernel: name, source: source, remove: source == nil)
    }
}

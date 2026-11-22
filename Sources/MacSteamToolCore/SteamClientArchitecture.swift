import AppKit
import CoreFoundation

public enum SteamClientArchitecture: String, CaseIterable, Sendable {
    case arm64, x86_64

    init?(cpuType: Int) {
        switch cpuType {
        case Int(CPU_TYPE_ARM64): self = .arm64
        case Int(CPU_TYPE_X86_64): self = .x86_64
        default: return nil
        }
    }

    static func slices(of executable: URL) -> [Self] {
        let numbers = CFBundleCopyExecutableArchitecturesForURL(executable as CFURL) as? [NSNumber] ?? []
        let found = Set(numbers.compactMap { Self(cpuType: $0.intValue) })
        return allCases.filter(found.contains)
    }

    func hasProfile(for build: String, in directory: URL) -> Bool {
        let file = directory.appendingPathComponent("signatures/macos.\(rawValue)/\(build).json")
        return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func installed(in paths: AppPaths, pids: [Int32]) -> (slices: [Self], running: Self?) {
        let launcher = paths.steamApp.appendingPathComponent("Contents/MacOS/steam_osx")
        let client = paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
        let executable = FileManager.default.fileExists(atPath: client.path) ? client : launcher
        let slices = slices(of: executable)
        let selectedPath = executable.resolvingSymlinksInPath().standardizedFileURL.path
        let running = Set(pids.compactMap { pid -> Self? in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == selectedPath else { return nil }
            return Self(cpuType: app.executableArchitecture)
        })
        return (slices, running.count == 1 ? running.first : nil)
    }
}

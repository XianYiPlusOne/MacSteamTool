import CoreFoundation
import Darwin
import Foundation

enum InstallerArchitecture {
    static let supported: Set<String> = ["arm64", "x86_64"]

    // Hardware capability, including when the helper runs under Rosetta.
    static var appleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func slices(of executable: URL) -> Set<String> {
        let types = CFBundleCopyExecutableArchitecturesForURL(executable as CFURL) as? [NSNumber] ?? []
        return Set(types.compactMap {
            switch $0.int32Value {
            case CPU_TYPE_ARM64: return "arm64"
            case CPU_TYPE_X86_64: return "x86_64"
            default: return nil
            }
        })
    }

    static func validateLibrary(_ library: URL, steamExecutable: URL) throws {
        let required = slices(of: steamExecutable)
        let available = slices(of: library)
        guard !required.isEmpty, required.isSubset(of: available) else {
            throw StepFailure(step: "Install kernel", detail:
                "\(library.lastPathComponent) must support Steam architectures: \(required.sorted().joined(separator: ", ")); found: \(available.sorted().joined(separator: ", "))")
        }
    }
}

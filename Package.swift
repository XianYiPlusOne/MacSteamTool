// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacSteamTool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacSteamTool", targets: ["MacSteamTool"]),
        .executable(name: "MacSteamToolUpdater", targets: ["MacSteamToolUpdater"]),
        .executable(name: "MacSteamToolRuntime", targets: ["MacSteamToolRuntime"]),
        .executable(name: "MacSteamToolInspect", targets: ["MacSteamToolInspect"]),
        .executable(name: "MacSteamToolWorker", targets: ["MacSteamToolWorker"]),
        .library(name: "MacSteamToolCore", targets: ["MacSteamToolCore"])
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .systemLibrary(name: "CArchive"),
        .systemLibrary(name: "CMultiplayer"),
        .target(name: "MacSteamToolShared", dependencies: ["ZIPFoundation", "SwiftCompatibilityShim"]),
        .target(name: "MacSteamToolCore", dependencies: ["MacSteamToolShared", "ZIPFoundation", "CArchive"]),
        .executableTarget(name: "MacSteamTool", dependencies: ["MacSteamToolCore", "CMultiplayer"]),
        .executableTarget(name: "MacSteamToolUpdater", dependencies: ["MacSteamToolShared"]),
        .executableTarget(name: "MacSteamToolRuntime", dependencies: ["MacSteamToolCore"]),
        .executableTarget(name: "MacSteamToolInspect", dependencies: ["MacSteamToolCore"]),
        .target(name: "NativeSteam", publicHeadersPath: "include"),
        // The Command Line Tools currently ship the Swift 5.6 compatibility
        // archive only as arm64/arm64e. ZIPFoundation asks the linker to load
        // that archive even when no compatibility entry point is used. Keep a
        // tiny x86_64-only definition so an Intel build remains linkable on a
        // host toolchain with the incomplete SDK; newer full Xcode toolchains
        // simply resolve the real archive instead.
        .target(name: "SwiftCompatibilityShim", path: "Sources/SwiftCompatibilityShim", publicHeadersPath: "include"),
        .executableTarget(name: "MacSteamToolWorker", dependencies: ["MacSteamToolCore", "NativeSteam"]),
        .testTarget(name: "MacSteamToolAppTests", dependencies: ["MacSteamTool", "MacSteamToolCore"]),
        .testTarget(name: "MacSteamToolCoreTests", dependencies: ["MacSteamToolCore", "ZIPFoundation"])
    ]
)

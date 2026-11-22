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
        .target(name: "MacSteamToolCore", dependencies: ["ZIPFoundation", "CArchive"]),
        .executableTarget(name: "MacSteamTool", dependencies: ["MacSteamToolCore", "CMultiplayer"]),
        .executableTarget(name: "MacSteamToolUpdater", dependencies: ["MacSteamToolCore"]),
        .executableTarget(name: "MacSteamToolRuntime", dependencies: ["MacSteamToolCore"]),
        .executableTarget(name: "MacSteamToolInspect", dependencies: ["MacSteamToolCore"]),
        .target(name: "NativeSteam", publicHeadersPath: "include"),
        .executableTarget(name: "MacSteamToolWorker", dependencies: ["MacSteamToolCore", "NativeSteam"]),
        .testTarget(name: "MacSteamToolAppTests", dependencies: ["MacSteamTool", "MacSteamToolCore"]),
        .testTarget(name: "MacSteamToolCoreTests", dependencies: ["MacSteamToolCore", "ZIPFoundation"])
    ]
)

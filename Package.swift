// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FluentSteamMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FluentSteam", targets: ["FluentSteam"]),
        .executable(name: "FluentUpdater", targets: ["FluentUpdater"]),
        .executable(name: "FluentRuntime", targets: ["FluentRuntime"]),
        .executable(name: "FluentInspect", targets: ["FluentInspect"]),
        .executable(name: "FluentSteamWorker", targets: ["FluentSteamWorker"]),
        .library(name: "FluentCore", targets: ["FluentCore"])
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "FluentCore", dependencies: ["ZIPFoundation"]),
        .executableTarget(name: "FluentSteam", dependencies: ["FluentCore"]),
        .executableTarget(name: "FluentUpdater", dependencies: ["FluentCore"]),
        .executableTarget(name: "FluentRuntime", dependencies: ["FluentCore"]),
        .executableTarget(name: "FluentInspect", dependencies: ["FluentCore"]),
        .target(name: "NativeSteam", publicHeadersPath: "include"),
        .executableTarget(name: "FluentSteamWorker", dependencies: ["FluentCore", "NativeSteam"]),
        .testTarget(name: "FluentAppTests", dependencies: ["FluentSteam", "FluentCore"]),
        .testTarget(name: "FluentCoreTests", dependencies: ["FluentCore", "ZIPFoundation"])
    ]
)

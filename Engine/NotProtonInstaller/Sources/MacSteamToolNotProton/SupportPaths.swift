// Adapted from NotProton; GPL-3.0. See PROVENANCE.md.
// Path construction for the NotProton support directory and Steam

import Foundation

enum SupportPaths {

    static let supportDirName = "notproton"
    static let dylibName = "notproton.dylib"

    static var home: URL {
        URL(filePath: NSHomeDirectory())
    }

    static var applicationSupport: URL {
        URL(filePath: ProcessInfo.processInfo.environment["FLUENT_INSTALL_SUPPORT"] ?? home.appending(path: "Library/Application Support").path)
    }

    // ~/Library/Application Support/notproton
    static var support: URL {
        URL(filePath: ProcessInfo.processInfo.environment["FLUENT_NOTPROTON_SUPPORT"] ?? applicationSupport.appending(path: supportDirName).path)
    }

    static var bridge: URL { support.appending(path: "bridge") }
    static var runners: URL { support.appending(path: "runners") }
    static var backups: URL { support.appending(path: "backups") }
    static var launchers: URL { support.appending(path: "launchers") }

    static var signatures: URL {
        support.appending(path: "signatures/macos.arm64")
    }

    static var fonts: URL { support.appending(path: "fonts") }
    static var overlayShim: URL { support.appending(path: "overlay-shim.dylib") }
    static var iconmaker: URL { support.appending(path: "iconmaker") }
    static var appinfo: URL { support.appending(path: "appinfo") }

    static var packageDownloads: URL {
        URL(filePath: ProcessInfo.processInfo.environment["FLUENT_NOTPROTON_DOWNLOADS"] ?? home.appending(path: "Library/Caches/\(supportDirName)/valve-packages").path)
    }

    static var winetricksDownloads: URL {
        home.appending(path: "Library/Caches/\(supportDirName)/winetricks")
    }

    static var deployedVersion: URL { support.appending(path: "dylib.version") }

    // Read by the dylib at Steam launch, in np_compat_load_tool_list.
    static var toolList: URL { support.appending(path: "tools") }

    static func runnerRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runners.appending(path: "crossover-\(build)")
    }

    static func crossOverRoot(inBundle bundle: URL) -> URL {
        bundle.appending(path: "Contents/SharedSupport/CrossOver")
    }

    static func clonedRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runnerRoot(forBuild: build, runners: runners).appending(path: "CrossOver")
    }

    static func prefixTemplates(forBuild build: String, in library: SteamLibrary) -> [URL] {
        CompatTool.Flavor.allCases.map { prefixTemplate(forBuild: build, flavor: $0, in: library) }
    }

    static func prefixTemplate(forBuild build: String, flavor: CompatTool.Flavor, in library: SteamLibrary) -> URL {
        library.compatdata.appending(path: prefixTemplateFolder).appending(path: "crossover-\(build)-\(flavor.unixDir)")
    }

    static let prefixTemplateFolder = "notproton-template"
    static let bridgeCacheFolder = "bridge"

    enum Steam {
        static let defaultApp = URL(filePath: "/Applications/Steam.app")
        static let appPathKey = "steamAppPath"

        static var app: URL {
            URL(filePath: ProcessInfo.processInfo.environment["FLUENT_STEAM_APP"] ?? defaultApp.path)
        }
        static func isUnreachable(_ bundle: URL = app) -> Bool {
            !FileManager.default.fileExists(atPath: bundle.deletingLastPathComponent().path(percentEncoded: false))
        }
        static var infoPlist: URL { infoPlist(inBundle: app) }
        static var executable: URL { app.appending(path: "Contents/MacOS/steam_osx") }
        static var deployedDylib: URL { deployedDylib(inBundle: app) }

        static func infoPlist(inBundle bundle: URL) -> URL {
            bundle.appending(path: "Contents/Info.plist")
        }

        static func deployedDylib(inBundle bundle: URL) -> URL {
            bundle.appending(path: "Contents/MacOS/\(dylibName)")
        }

        static var userData: URL {
            URL(filePath: ProcessInfo.processInfo.environment["FLUENT_STEAM_DATA"] ?? SupportPaths.applicationSupport.appending(path: "Steam").path)
        }

        static var configFile: URL { userData.appending(path: "steam.cfg") }

        static var innerApp: URL { userData.appending(path: "Steam.AppBundle/Steam") }
        static var innerInfoPlist: URL { innerApp.appending(path: "Contents/Info.plist") }

        static var innerClient: URL { innerApp.appending(path: "Contents/MacOS") }

        static var innerConfigFile: URL { innerClient.appending(path: "steam.cfg") }
        static var legacyCompat: URL { innerClient.appending(path: "legacycompat") }

        static var compatTools: URL { userData.appending(path: "compatibilitytools.d") }

        static func notprotonTools(in directory: URL = compatTools) -> [URL] {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            return entries.filter { $0.lastPathComponent.hasPrefix("notproton") }
        }

        static var libraryFoldersVDF: URL { userData.appending(path: "steamapps/libraryfolders.vdf") }
    }
}

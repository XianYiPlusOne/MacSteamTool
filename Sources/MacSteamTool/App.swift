import SwiftUI
import AppKit
import MacSteamToolCore

@main
struct MacSteamToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("MacSteamTool", id: "main") {
            RootView().modifier(AppWindowAppearance()).environmentObject(model)
                .frame(minWidth: 1060, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 810)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsItem(title: model.tr("设置…", "Settings…"))
            }
            CommandGroup(replacing: .newItem) {
                Button(model.tr("导入 Lua / ZIP…", "Import Lua / ZIP…")) { model.chooseImport() }.keyboardShortcut("o")
                Button(model.tr("刷新游戏库", "Refresh library")) { model.refresh() }.keyboardShortcut("r")
            }
        }
        Window(model.tr("设置", "Settings"), id: "settings") {
            SettingsPage(standalone: true).presentSteamWebLinks().frame(minWidth: 660, minHeight: 460)
                .modifier(AppWindowAppearance()).environmentObject(model)
                .task { await model.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 780, height: 650)
        Window("存档管理 · Save manager", id: "save-manager") {
            SaveManagerWindow().modifier(AppWindowAppearance()).environmentObject(model)
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1040, height: 720)
        MenuBarExtra("MacSteamTool", systemImage: "gamecontroller") { TrayMenu().environmentObject(model) }
    }
}

private struct OpenSettingsItem: View {
    @Environment(\.openWindow) private var openWindow
    let title: String

    var body: some View {
        Button(title) { openWindow(id: "settings") }.keyboardShortcut(",")
    }
}

struct TrayMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("MacSteamTool")
        Button(model.tr("打开主窗口", "Open main window")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(model.tr("导入 Lua / ZIP…", "Import Lua / ZIP…")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); model.chooseImport() }
        Divider()
        Button(model.tr("启动 Steam", "Launch Steam")) { model.launchSteam() }
        Button(model.tr("刷新游戏库", "Refresh library")) { model.refresh() }
        if model.monitorRunning || model.hubMonitorRunning { Button(model.tr("停止 Manifest 监听", "Stop manifest monitoring")) { model.stopManifestMonitor() } }
        else { Button(model.tr("启动 Manifest 监听", "Start manifest monitoring")) { model.startManifestMonitor() } }
        Divider()
        Button(model.tr("退出", "Quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
}

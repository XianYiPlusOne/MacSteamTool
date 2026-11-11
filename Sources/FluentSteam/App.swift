import SwiftUI
import AppKit
import FluentCore

@main
struct FluentSteamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Fluent Steam · Mac", id: "main") {
            RootView().environmentObject(model)
                .preferredColorScheme(model.preferences.theme == "dark" ? .dark : model.preferences.theme == "light" ? .light : nil)
                .frame(minWidth: 1060, minHeight: 700)
        }
        .defaultSize(width: 1240, height: 810)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.tr("导入 Lua / ZIP…", "Import Lua / ZIP…")) { model.chooseImport() }.keyboardShortcut("o")
                Button(model.tr("刷新游戏库", "Refresh library")) { model.refresh() }.keyboardShortcut("r")
            }
        }
        Settings { SettingsPage().environmentObject(model).frame(width: 780, height: 650) }
        Window("存档管理 · Save manager", id: "save-manager") {
            SaveManagerWindow().environmentObject(model)
                .preferredColorScheme(model.preferences.theme == "dark" ? .dark : model.preferences.theme == "light" ? .light : nil)
        }.defaultSize(width: 1040, height: 720)
        MenuBarExtra("Fluent Steam", systemImage: "gamecontroller") { TrayMenu().environmentObject(model) }
    }
}
struct TrayMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Fluent Steam Mac")
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

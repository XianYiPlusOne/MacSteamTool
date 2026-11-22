import SwiftUI
import MacSteamToolCore

// The standalone macOS 27 SDK exposes a new State macro without shipping its
// plugin. A type alias explicitly selects the backwards-compatible wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Palette {
    static let accent = Color(red: 0.31, green: 0.40, blue: 0.91)
    static let green = Color(red: 0.13, green: 0.61, blue: 0.44)
    static let amber = Color(red: 0.78, green: 0.48, blue: 0.11)
}

struct AppWindowAppearance: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let translucent = model.preferences.materialBackground == true
        content
            .scrollContentBackground(translucent && !reduceTransparency ? .hidden : .automatic)
            .transformEnvironment(\.backgroundStyle) { style in
                if translucent && !reduceTransparency {
                    style = AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                }
            }
            .background {
                if translucent {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                    } else {
                        DesktopMaterial().ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .preferredColorScheme(model.preferences.theme == "dark" ? .dark : model.preferences.theme == "light" ? .light : nil)
    }
}

private struct DesktopMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
}
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 28, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(); actions
        }.padding(.bottom, 12)
    }
}
struct Pill: View {
    var text: String
    var color: Color = Palette.accent
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(color).background(color.opacity(0.10), in: Capsule())
    }
}
struct EmptyMessage: View {
    var icon: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(Palette.accent).padding(24).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.frame(maxWidth: .infinity).padding(.vertical, 55)
    }
}
struct Cover: View {
    @EnvironmentObject var model: AppModel
    var id: Int
    var name: String
    var height: CGFloat = 135
    var imageURL: String? = nil
    var retainForSaves = false
    @ViewState<NSImage?> private var image = nil
    @ViewState<Bool> private var failed = false
    @ViewState<Bool> private var loading = false
    @ViewState<Int> private var retry = 0
    private struct Request: Hashable { let app: Int; let reference: String?; let steam: String; let retry: Int }
    var body: some View {
        let request = Request(app: id, reference: imageURL ?? model.metadata[id]?.image, steam: model.paths.steam.path, retry: retry)
        ZStack(alignment: .bottomTrailing) {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else {
                ZStack {
                    LinearGradient(colors: [Palette.accent.opacity(0.25), Color.indigo.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "gamecontroller.fill").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.accent.opacity(0.55))
                }
                if loading { ProgressView().controlSize(.small).padding(8) }
                else if failed {
                    Button { retry += 1 } label: { Image(systemName: "arrow.clockwise").padding(7) }.buttonStyle(.plain)
                        .help(model.tr("重新加载封面", "Reload cover")).accessibilityLabel(model.tr("重新加载封面", "Reload cover"))
                }
            }
        }.frame(height: height).clipped().accessibilityLabel(name)
        .contextMenu { Button(model.tr("重新加载封面", "Reload cover")) { retry += 1 } }
        .task(id: request) {
            loading = true; failed = false
            let cached = await model.covers.cachedImage(appID: request.app, steam: URL(fileURLWithPath: request.steam))
            guard !Task.isCancelled else { return }
            image = cached.flatMap(NSImage.init(data:))
            do {
                let bytes = try await model.covers.load(appID: request.app, reference: request.reference, steam: URL(fileURLWithPath: request.steam), force: request.retry > 0)
                guard !Task.isCancelled else { return }
                image = NSImage(data: bytes); failed = image == nil
                if retainForSaves { try? await model.covers.retain(bytes, appID: request.app) }
                guard !Task.isCancelled else { return }
            } catch { guard !Task.isCancelled else { return }; failed = image == nil }
            loading = false
        }
    }
}
struct InfoLine: View {
    var title: String
    var value: String
    var body: some View {
        HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(minLength: 22); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            .font(.system(size: 12)).padding(.vertical, 5)
    }
}

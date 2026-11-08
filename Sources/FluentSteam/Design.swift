import SwiftUI
import FluentCore

// The standalone macOS 27 SDK exposes a new State macro without shipping its
// plugin. A type alias explicitly selects the backwards-compatible wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Palette {
    static let accent = Color(red: 0.31, green: 0.40, blue: 0.91)
    static let green = Color(red: 0.13, green: 0.61, blue: 0.44)
    static let amber = Color(red: 0.78, green: 0.48, blue: 0.11)
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
    var id: Int
    var name: String
    var height: CGFloat = 135
    var body: some View {
        AsyncImage(url: URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/header.jpg")) { phase in
            if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
            else {
                ZStack {
                    LinearGradient(colors: [Palette.accent.opacity(0.25), Color.indigo.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "gamecontroller.fill").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.accent.opacity(0.55))
                }
            }
        }.frame(height: height).clipped().accessibilityLabel(name)
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

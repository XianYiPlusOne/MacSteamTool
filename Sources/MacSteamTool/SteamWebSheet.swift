import SwiftUI
import WebKit

struct GameStoreLink: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let appID: Int

    var body: some View {
        let url = URL(string: "https://store.steampowered.com/app/\(appID)/")!
            .appending(queryItems: [URLQueryItem(name: "l", value: model.language)])
        Link(title, destination: url)
    }
}

extension View {
    func presentSteamWebLinks() -> some View { modifier(SteamWebPresentation()) }
}

private struct SteamWebPresentation: ViewModifier {
    private struct Page: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @ViewState<Page?> private var page = nil

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return .systemAction }
                page = Page(url: url)
                return .handled
            })
            .sheet(item: $page) { page in SteamWebSheet(url: page.url) }
    }
}

private struct SteamWebSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = SteamWebBrowser()
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(onClose: { dismiss() }) {
                Button { browser.webView.goBack() } label: {
                    Label(model.tr("后退", "Back"), systemImage: "chevron.backward")
                }
                .labelStyle(.iconOnly)
                .disabled(!browser.canGoBack)
                VStack(alignment: .leading, spacing: 2) {
                    Text(browser.title ?? model.tr("网页", "Web page")).font(.headline).lineLimit(1)
                    Text(browser.location?.host ?? url.host ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if browser.loading { ProgressView().controlSize(.small) }
            }.padding(12)
            Divider()
            SteamWebView(webView: browser.webView)
                .overlay {
                    if browser.failed {
                        VStack(spacing: 12) {
                            Text(model.tr("无法加载网页", "Couldn’t load the page"))
                            Button(model.tr("重新打开", "Reopen"), action: openPage)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                    }
                }
        }
        .frame(minWidth: 640, idealWidth: 980, minHeight: 400, idealHeight: 600)
        .onAppear(perform: openPage)
        .onExitCommand { dismiss() }
        .onDisappear { browser.webView.stopLoading() }
    }

    private func openPage() {
        browser.webView.load(URLRequest(url: url))
    }
}

private struct SteamWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor private final class SteamWebBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView = WKWebView()
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var title: String?
    @Published private(set) var location: URL?
    @Published private(set) var failed = false

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.publisher(for: \.isLoading).assign(to: &$loading)
        webView.publisher(for: \.canGoBack).assign(to: &$canGoBack)
        webView.publisher(for: \.title).assign(to: &$title)
        webView.publisher(for: \.url).assign(to: &$location)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame != false {
            guard let scheme = action.request.url?.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failed = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    private func handleFailure(_ error: Error) {
        if (error as? URLError)?.code != .cancelled { failed = true }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true }
}

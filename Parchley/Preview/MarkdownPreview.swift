import SwiftUI
import AppKit
import WebKit
import ParchleyMarkdown

public struct MarkdownPreview: NSViewRepresentable {
    public let markdown: String
    @Environment(\.colorScheme) private var colorScheme

    public init(markdown: String) { self.markdown = markdown }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        applyAppearance(to: view)
        view.setAccessibilityLabel("Markdown preview")
        return view
    }
    public func updateNSView(_ view: WKWebView, context: Context) {
        applyAppearance(to: view)
        guard context.coordinator.lastMarkdown != markdown else { return }
        context.coordinator.lastMarkdown = markdown
        context.coordinator.renderTask?.cancel()
        context.coordinator.generation &+= 1
        let generation = context.coordinator.generation
        guard markdown.utf8.count <= Self.largeDocumentLimit else {
            view.loadHTMLString(Self.documentHTML(body: "<p>Preview is disabled for documents over 200,000 bytes. Use Source to review this document.</p>"), baseURL: nil)
            context.coordinator.renderTask = nil
            return
        }
        let source = markdown
        context.coordinator.renderTask = Task { @concurrent in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let body = MarkdownHTMLRenderer.render(source)
            let html = Self.documentHTML(body: body)
            await MainActor.run {
                guard context.coordinator.generation == generation else { return }
                view.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    private func applyAppearance(to view: WKWebView) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.underPageBackgroundColor = colorScheme == .dark ? .windowBackgroundColor : .textBackgroundColor
    }

    private static let largeDocumentLimit = 200_000
    nonisolated private static func documentHTML(body: String) -> String {
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; base-uri 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; img-src 'none'; media-src 'none'; font-src 'none'; connect-src 'none'; script-src 'none'; style-src 'unsafe-inline'; form-action 'none'; sandbox\"><style>:root{color-scheme:light dark}html,body{background:canvas;color:canvastext}body{font:-apple-system-body;margin:24px;line-height:1.5}a{color:linktext}pre,code{background:rgba(127,127,127,.16)}pre{white-space:pre-wrap;padding:12px;border-radius:6px}code{padding:2px 4px;border-radius:4px}table{border-collapse:collapse}th,td{border:1px solid rgba(127,127,127,.45);padding:6px 10px;text-align:start}</style></head><body>\(body)</body></html>"
    }
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        fileprivate var generation: UInt = 0
        fileprivate var renderTask: Task<Void, Never>?
        fileprivate var lastMarkdown: String?

        deinit {
            renderTask?.cancel()
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType != .linkActivated {
                let isInitialDocument = navigationAction.request.url == nil || navigationAction.request.url?.absoluteString == "about:blank"
                decisionHandler(isInitialDocument ? .allow : .cancel)
                return
            }
            guard let url = navigationAction.request.url,
                  Self.isSafeExternalURL(url) else { decisionHandler(.cancel); return }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            let url = navigationResponse.response.url
            decisionHandler(url == nil || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }

        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        private static func isSafeExternalURL(_ url: URL) -> Bool {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = components.host,
                  !host.isEmpty,
                  components.user == nil,
                  components.password == nil,
                  components.fragment == nil || !components.fragment!.contains("\n") else {
                return false
            }
            return !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }
}

import SwiftUI
import AppKit
import WebKit
import ParchleyMarkdown

public struct MarkdownPreview: NSViewRepresentable {
    public let markdown: String
    public init(markdown: String) { self.markdown = markdown }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .white
        view.setAccessibilityLabel("Markdown preview")
        return view
    }
    public func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.renderTask?.cancel()
        context.coordinator.generation &+= 1
        let generation = context.coordinator.generation
        guard markdown.utf8.count <= Self.largeDocumentLimit else {
            view.loadHTMLString(Self.documentHTML(body: "<p>Preview is disabled for documents over 200,000 bytes. Use Source to review this document.</p>"), baseURL: nil)
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
    private static let largeDocumentLimit = 200_000
    nonisolated private static func documentHTML(body: String) -> String {
        "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'\"><style>:root{color-scheme:light}html,body{background:#ffffff;color:#202124}body{font:-apple-system-body;margin:24px;line-height:1.5}a{color:#0969da}pre{white-space:pre-wrap;background:#f6f8fa;padding:12px;border-radius:6px}code{background:#f6f8fa;padding:2px 4px;border-radius:4px}table{border-collapse:collapse}th,td{border:1px solid #c8ccd1;padding:6px 10px;text-align:left}</style>\(body)"
    }
    public final class Coordinator: NSObject, WKNavigationDelegate {
        fileprivate var generation: UInt = 0
        fileprivate var renderTask: Task<Void, Never>?
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType != .linkActivated {
                let isInitialDocument = navigationAction.request.url == nil || navigationAction.request.url?.absoluteString == "about:blank"
                decisionHandler(isInitialDocument ? .allow : .cancel)
                return
            }
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { decisionHandler(.cancel); return }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

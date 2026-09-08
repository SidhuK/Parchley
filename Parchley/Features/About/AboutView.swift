import SwiftUI

struct AboutView: View {
    @State private var notices = "Loading acknowledgements…"
    var body: some View {
        ScrollView {
          VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).accessibilityHidden(true)
            Text("Parchley").font(.title).bold()
            Text("Local PDF to Markdown review").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown"))")
            Divider()
            Text("Acknowledgements").font(.headline)
            Text("Parchley uses swift-markdown, pdf-inspector, PDFium, ONNX Runtime, and PP-OCRv6 Small.")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(notices).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(28)
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 520,
               minHeight: 260, idealHeight: 480)
        .task {
            let loadedNotices = await Self.loadNotices()
            guard !Task.isCancelled else { return }
            notices = loadedNotices
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("About Parchley")
    }

    private nonisolated static func loadNotices() async -> String {
        await Task.detached(priority: .utility) {
            let names = ["Parchley-acknowledgements.txt", "ACKNOWLEDGEMENTS.txt", "PDFium-LICENSE", "ONNXRuntime-LICENSE", "ONNXRuntime-ThirdPartyNotices.txt"]
            return names.compactMap { name in
                guard let url = Bundle.main.url(forResource: name.replacingOccurrences(of: ".txt", with: ""), withExtension: name.hasSuffix(".txt") ? "txt" : nil), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return "--- \(name) ---\n\(text)"
            }.joined(separator: "\n\n")
        }.value
    }
}

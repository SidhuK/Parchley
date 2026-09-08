import SwiftUI
import AppKit

struct LicensesView: View {
    @State private var selection: LicenseDocument.ID? = LicenseDocument.documents.first?.id

    var body: some View {
        HSplitView {
            List(LicenseDocument.documents, selection: $selection) { document in
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.name)
                    Text(document.license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(document.id)
            }
            .frame(minWidth: 180, idealWidth: 190, maxWidth: 220)

            if let document = selectedDocument {
                LicenseDetail(document: document)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Select a component",
                    systemImage: "doc.text",
                    description: Text("Choose a component to read its license and attribution.")
                )
            }
        }
    }

    private var selectedDocument: LicenseDocument? {
        LicenseDocument.documents.first { $0.id == selection }
    }
}

private struct LicenseDetail: View {
    let document: LicenseDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(document.name)
                    .font(.title2.weight(.semibold))
                Text(document.license)
                    .foregroundStyle(.secondary)

                if let sourceURL = document.sourceURL {
                    Link("View project website", destination: sourceURL)
                }

                Divider()

                LicenseTextView(text: document.text)
                    .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
            }
            .padding(20)
        }
    }
}

private struct LicenseTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .secondaryLabelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}

private struct LicenseDocument: Identifiable {
    let id: String
    let name: String
    let license: String
    let resource: String?
    let fallback: String
    let sourceURL: URL?

    var text: String {
        guard let resource,
              let url = Bundle.main.url(forResource: resource, withExtension: nil),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return fallback
        }
        return contents
    }

    static let documents: [LicenseDocument] = [
        LicenseDocument(
            id: "ocr-model",
            name: "PP-OCRv6 Small",
            license: "Apache License 2.0",
            resource: "ACKNOWLEDGEMENTS.txt",
            fallback: "PP-OCRv6 Small is distributed under the Apache License 2.0.",
            sourceURL: URL(string: "https://huggingface.co/monkt/paddleocr-onnx")
        ),
        LicenseDocument(
            id: "rust-engine",
            name: "Rust conversion engine",
            license: "Open-source acknowledgements",
            resource: "Parchley-acknowledgements.txt",
            fallback: "The conversion engine uses the Rust crates listed in the bundled acknowledgements.",
            sourceURL: nil
        ),
        LicenseDocument(
            id: "pdf-inspector",
            name: "pdf-inspector 1.17.0",
            license: "MIT License",
            resource: "ACKNOWLEDGEMENTS.txt",
            fallback: "pdf-inspector is distributed under the MIT License.",
            sourceURL: URL(string: "https://github.com/krelinga/pdf-inspector")
        ),
        LicenseDocument(
            id: "pdfium",
            name: "PDFium native-v7988",
            license: "BSD 3-Clause License",
            resource: "PDFium-LICENSE",
            fallback: "The PDFium license file is unavailable.",
            sourceURL: URL(string: "https://pdfium.googlesource.com/pdfium/")
        ),
        LicenseDocument(
            id: "onnx-runtime",
            name: "ONNX Runtime 1.27.0",
            license: "MIT License",
            resource: "ONNXRuntime-LICENSE",
            fallback: "The ONNX Runtime license file is unavailable.",
            sourceURL: URL(string: "https://github.com/microsoft/onnxruntime")
        ),
        LicenseDocument(
            id: "onnx-notices",
            name: "ONNX Runtime dependencies",
            license: "Third-party notices",
            resource: "ONNXRuntime-ThirdPartyNotices.txt",
            fallback: "The ONNX Runtime third-party notice file is unavailable.",
            sourceURL: nil
        ),
        LicenseDocument(
            id: "swift-markdown",
            name: "Swift Markdown 0.4.0",
            license: "Apache License 2.0",
            resource: "ACKNOWLEDGEMENTS.txt",
            fallback: "Swift Markdown is distributed under the Apache License 2.0.",
            sourceURL: URL(string: "https://github.com/swiftlang/swift-markdown")
        ),
        LicenseDocument(
            id: "swift-cmark",
            name: "swift-cmark 0.8.0",
            license: "BSD 2-Clause License",
            resource: nil,
            fallback: "swift-cmark is distributed under the BSD 2-Clause License. Its distribution includes cmark-gfm and the applicable third-party notices.",
            sourceURL: URL(string: "https://github.com/swiftlang/swift-cmark")
        )
    ]
}

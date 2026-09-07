import SwiftUI
import PDFKit

public struct PDFPreview: NSViewRepresentable {
    public let url: URL?
    public let page: Int

    public init(url: URL?, page: Int = 1) { self.url = url; self.page = page }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.setAccessibilityLabel("PDF document preview")
        return view
    }
    public func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            context.coordinator.lastRequestedPage = nil
            context.coordinator.document = url.flatMap { PDFDocument(url: $0) }
            view.document = context.coordinator.document
        }
        guard let document = context.coordinator.document, page > 0, page <= document.pageCount,
              let target = document.page(at: page - 1) else { return }
        if context.coordinator.lastRequestedPage != page {
            context.coordinator.lastRequestedPage = page
            view.go(to: target)
        }
    }
    public final class Coordinator {
        fileprivate var url: URL?
        fileprivate var document: PDFDocument?
        fileprivate var lastRequestedPage: Int?
    }
}

import Foundation
import PDFKit
import SwiftUI

public struct PDFPreview: NSViewRepresentable {
    public let url: URL?
    public let page: Int
    public let password: String

    public init(url: URL?, page: Int = 1, password: String = "") {
        self.url = url
        self.page = page
        self.password = password
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayBox = .mediaBox
        view.acceptsDraggedFiles = false
        view.delegate = context.coordinator
        view.setAccessibilityLabel("PDF document preview")
        return view
    }

    public func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.url != url || context.coordinator.password != password {
            context.coordinator.url = url
            context.coordinator.password = password
            context.coordinator.lastRequestedPage = nil
            context.coordinator.document = url.flatMap { Self.validatedDocument(for: $0, password: password) }
            view.document = context.coordinator.document
        }

        guard let document = context.coordinator.document,
              !document.isLocked,
              page > 0,
              page <= document.pageCount,
              let target = document.page(at: page - 1) else {
            return
        }
        if context.coordinator.lastRequestedPage != page {
            context.coordinator.lastRequestedPage = page
            view.go(to: target)
        }
    }

    /// Loads a bounded, local copy of the PDF. The source security scope is
    /// held only for this read and never retained by the preview.
    internal static func validatedDocument(for url: URL, password: String = "") -> PDFDocument? {
        guard url.isFileURL, isRegularFile(url), !isSymbolicLink(url) else {
            return nil
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              values.fileSize.map(Int64.init).map({ $0 <= maximumBytes }) ?? true,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 5), header == Data("%PDF-".utf8) else {
            return nil
        }
        var data = header
        data.reserveCapacity(min(values.fileSize ?? 1024 * 1024, Int(maximumBytes)))
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty {
                break
            }
            if Int64(data.count) > maximumBytes - Int64(chunk.count) {
                return nil
            }
            data.append(chunk)
        }

        guard let document = PDFDocument(data: data) else { return nil }
        if document.isLocked, !password.isEmpty {
            _ = document.unlock(withPassword: password)
        }
        guard !document.isLocked,
              document.pageCount > 0,
              document.pageCount <= maximumPageCount else {
            return nil
        }

        sanitize(document)
        return document
    }

    private static let maximumBytes: Int64 = 250 * 1024 * 1024
    private static let maximumPageCount = 10_000

    private static func sanitize(_ document: PDFDocument) {
        document.outlineRoot = nil
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.action != nil || annotation.type == "Link" || annotation.type == "Widget" {
                page.removeAnnotation(annotation)
            }
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    public final class Coordinator: NSObject, PDFViewDelegate {
        fileprivate var url: URL?
        fileprivate var document: PDFDocument?
        fileprivate var password = ""
        fileprivate var lastRequestedPage: Int?

        // PDFKit's default delegate opens URLs in the user's browser. The
        // preview is read-only, so links and remote document actions stay inert.
        public func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

        public func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}
    }
}

import SwiftUI
import AppKit

public struct MarkdownEditor: NSViewRepresentable {
    @Binding public var text: String
    public let documentID: UUID

    public init(text: Binding<String>, documentID: UUID) { _text = text; self.documentID = documentID }
    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = NSTextView()
        editor.isRichText = false
        editor.setAccessibilityLabel("Markdown source editor")
        editor.allowsUndo = true
        editor.usesFindPanel = true
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.string = text
        editor.delegate = context.coordinator
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if context.coordinator.documentID != documentID {
            context.coordinator.documentID = documentID
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
        guard editor.string != text else { return }
        let selection = editor.selectedRanges
        editor.string = text
        let maxLocation = (text as NSString).length
        editor.selectedRanges = selection.map { value in
            let original = value.rangeValue
            let location = min(original.location, maxLocation)
            let length = min(original.length, maxLocation - location)
            return NSValue(range: NSRange(location: location, length: length))
        }
    }
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var documentID: UUID
        init(parent: MarkdownEditor) { self.parent = parent; self.documentID = parent.documentID }
        public func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

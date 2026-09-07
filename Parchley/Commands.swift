import SwiftUI
import AppKit

private struct ParchleyModelFocusedKey: FocusedValueKey {
    typealias Value = ParchleyAppModel
}

extension FocusedValues {
    var parchleyModel: ParchleyAppModel? {
        get { self[ParchleyModelFocusedKey.self] }
        set { self[ParchleyModelFocusedKey.self] = newValue }
    }
}

struct ParchleyCommands: Commands {
    @FocusedValue(\.parchleyModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Parchley") { openWindow(id: "about") }
        }
        CommandGroup(after: .newItem) {
            Button("Add PDFs…") { model?.choosePDFs() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(after: .saveItem) {
            Button("Save") { model?.isSavePanelPresented = true }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model?.markdown.isEmpty ?? true)
            Button("Save As…") { model?.isSavePanelPresented = true }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model?.markdown.isEmpty ?? true)
            Divider()
            Button("Export…") { model?.isSavePanelPresented = true }
                .disabled(model?.markdown.isEmpty ?? true)
            Button("Export All…") { model?.isBatchExportPresented = true }
                .disabled(!(model?.documents.contains { $0.resultRevision != nil } ?? false))
            Divider()
            Button("Clear Document List…", role: .destructive) { model?.requestClearList() }
                .disabled(!(model?.hasDocuments ?? false))
        }
        CommandMenu("Document") {
            Button(convertTitle, systemImage: "play.fill") { model?.convertSelected() }
                .disabled(!(model?.canConvert ?? false))
            Button("Convert All", systemImage: "arrow.triangle.2.circlepath") { model?.convertAll() }
                .disabled(!(model?.canConvertAll ?? false))
            Button("Cancel Conversion", systemImage: "xmark") { cancelSelected() }
                .disabled(!canCancelSelected)
            Divider()
            Button("Move Earlier", systemImage: "arrow.up") {
                if let id = model?.selectedDocument?.id { model?.moveEarlier(id) }
            }
            .disabled(!canMoveSelectedEarlier)
            Button("Remove Selected Document", systemImage: "trash", role: .destructive) {
                if let id = model?.selectedDocument?.id { model?.requestRemove(id) }
            }
            .disabled(!(model?.selectedDocument != nil))
        }
        CommandGroup(after: .textEditing) {
            Button("Copy Markdown") { model?.copyMarkdown() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model?.markdown.isEmpty ?? true)
            Button("Find") {
                let item = NSMenuItem(title: "Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                NSApp.keyWindow?.firstResponder?.tryFind(item)
            }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button(model?.showInspector == true ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
                model?.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model == nil)
        }
    }

    private var convertTitle: String {
        guard let status = model?.selectedDocument?.status else { return "Convert" }
        return [.failed, .interrupted, .cancelled].contains(status) ? "Retry" : "Convert"
    }

    private var canCancelSelected: Bool {
        guard let status = model?.selectedDocument?.status else { return false }
        return [.preparing, .converting].contains(status)
    }

    private var canMoveSelectedEarlier: Bool {
        guard let model,
              let selected = model.selectedDocument,
              selected.status == .queued,
              let index = model.documents.firstIndex(where: { $0.id == selected.id }) else { return false }
        return index > 0
    }

    private func cancelSelected() {
        guard let id = model?.selectedDocument?.id else { return }
        model?.cancel(id)
    }
}

private extension NSResponder {
    func tryFind(_ item: NSMenuItem) {
        if tryPerform(#selector(NSTextView.performFindPanelAction(_:)), with: item) { return }
        nextResponder?.tryFind(item)
    }
    @discardableResult func tryPerform(_ action: Selector, with object: Any?) -> Bool {
        guard responds(to: action) else { return false }
        _ = perform(action, with: object)
        return true
    }
}

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
            Button("Open PDFs…") { model?.choosePDFs() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Export…") { model?.isSavePanelPresented = true }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model?.markdown.isEmpty ?? true)
            Button("Export All…") { model?.isBatchExportPresented = true }
                .disabled(!(model?.canExportAll ?? false))
            Divider()
            Button("Clear Document List…", role: .destructive) { model?.requestClearList() }
                .disabled(!(model?.hasDocuments ?? false) || model?.isClearingList == true)
        }
        CommandMenu("Document") {
            Button("Cancel Conversion", systemImage: "xmark") { cancelSelected() }
                .disabled(!(model?.canCancelSelected ?? false))
            Divider()
            Button("Move Earlier", systemImage: "arrow.up") {
                if let id = model?.selectedDocument?.id { model?.moveEarlier(id) }
            }
            .disabled(!(model?.canMoveSelectedEarlier ?? false))
            Button("Remove Selected Document", systemImage: "trash", role: .destructive) {
                if let id = model?.selectedDocument?.id { model?.requestRemove(id) }
            }
            .disabled(!(model?.selectedDocument != nil))
        }
        CommandGroup(after: .textEditing) {
            Button("Copy Markdown") { model?.copyMarkdown() }
                .disabled(model?.markdown.isEmpty ?? true)
            Button("Find") {
                let item = NSMenuItem(title: "Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                NSApp.keyWindow?.firstResponder?.tryFind(item)
            }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button(inspectorTitle, systemImage: "sidebar.right") {
                model?.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model == nil)
        }
    }

    private var inspectorTitle: LocalizedStringResource {
        model?.showInspector == true ? "Hide Inspector" : "Show Inspector"
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

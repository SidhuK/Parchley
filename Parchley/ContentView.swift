import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import ParchleyEngine

@MainActor @Observable
final class ParchleyAppModel {
    private struct DraftSnapshot: Sendable {
        let markdown: String
        let revision: Int
    }

    var documents: [DocumentRecord] = []
    var selection: UUID?
    var markdown = ""
    var password = ""
    var isImportPanelPresented = false
    var isSavePanelPresented = false
    var isBatchExportPresented = false
    var showInspector = false
    var selectedPage = 1
    var selectedResult: EngineResult?
    var alertMessage: String?
    var pendingRemoval: UUID?
    var pendingReconversion: UUID?
    var isClearListConfirmationPresented = false
    private(set) var stagedURLs: [UUID: URL] = [:]
    private var draftTask: Task<Void, Never>?
    private var pendingDrafts: [UUID: DraftSnapshot] = [:]
    private var loadGeneration = 0
    private var observationTask: Task<Void, Never>?
    private var conversionTask: Task<Void, Never>?
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var reconversionDrafts: [UUID: DraftSnapshot] = [:]
    let store: WorkspaceStore?
    let fileAccess = FileAccessService()
    let coordinator: ConversionCoordinator?
    private let coordinatorUnavailableMessage: String?
    let ocrManager: OCRModelManager?
    let ocrManifest: ModelManifest

    init() {
        let workspace = try? WorkspaceStore()
        store = workspace
        ocrManifest = ModelManifest(revision: "oar-ocr-v0.7.0", artifacts: [ModelArtifact(name: "pp-ocrv6_small_det.onnx", url: URL(string: "https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/pp-ocrv6_small_det.onnx")!, byteCount: 9880512, sha256: "d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e"), ModelArtifact(name: "pp-ocrv6_small_rec.onnx", url: URL(string: "https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/pp-ocrv6_small_rec.onnx")!, byteCount: 21159378, sha256: "5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634"), ModelArtifact(name: "ppocrv6_dict.txt", url: URL(string: "https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/ppocrv6_dict.txt")!, byteCount: 74947, sha256: "b5f2bfe2bdd9448429e3e82b51c789775d9b42f2403d082b00662eb77e401c5d")])
        ocrManager = workspace.flatMap { try? OCRModelManager(root: $0.root.appendingPathComponent("Models")) }
        if let workspace {
            do {
                let rust = try RustEngine()
                coordinator = ConversionCoordinator(engine: RustConversionEngine(engine: rust), store: workspace)
                coordinatorUnavailableMessage = nil
            } catch {
                coordinator = nil
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                NSLog("Parchley engine initialization failed: %@", detail)
                coordinatorUnavailableMessage = "The bundled conversion engine could not be loaded. \(detail)"
            }
        } else {
            coordinator = nil
            coordinatorUnavailableMessage = "Parchley could not open its workspace."
        }
        UserDefaults.standard.register(defaults: ["ocrEnabled": true])
        Task { if let manager = ocrManager { _ = await manager.discover(ocrManifest) }; await reload(); observationTask = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)); guard let self, let store = self.store else { continue }; let latest = await store.documents(); await MainActor.run { self.updateObserved(latest) } } } }
    }
    var selectedDocument: DocumentRecord? { documents.first { $0.id == selection } }
    var canConvert: Bool { selectedDocument.map { [.queued, .failed, .interrupted, .cancelled, .completed, .needsReview].contains($0.status) } ?? false }
    var canConvertAll: Bool { documents.contains { $0.status == .queued } }
    var hasDocuments: Bool { !documents.isEmpty }
    func reload() async {
        guard let store else { return }
        let latest = await store.documents()
        documents = latest
        let ids = Set(latest.map(\.id))
        stagedURLs = stagedURLs.filter { ids.contains($0.key) }
        for document in latest {
            let staged = store.root.appendingPathComponent("Caches/Jobs/\(document.id.uuidString)/input.pdf")
            if FileManager.default.fileExists(atPath: staged.path) {
                stagedURLs[document.id] = staged
            }
        }
        if selection == nil || !ids.contains(selection!) {
            selection = latest.first?.id
        }
        await loadDraft()
    }

    func choosePDFs() {
        isImportPanelPresented = true
    }

    private func updateObserved(_ latest: [DocumentRecord]) {
        let oldResultRevision = selectedDocument?.resultRevision
        documents = latest
        if selectedDocument?.resultRevision != oldResultRevision {
            Task { await loadDraft() }
        }
    }

    func importFiles(_ urls: [URL]) {
        guard let store else { return }
        let sources = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        if sources.count != urls.count {
            alertMessage = "Only PDF files can be imported."
        }
        for source in sources {
            let id = UUID()
            let record = DocumentRecord(id: id,
                                        sourceName: source.deletingPathExtension().lastPathComponent,
                                        status: .preparing,
                                        stage: "Preparing document")
            documents.append(record)
            selection = id
            let task = Task { @concurrent [weak self] in
                do {
                    try await store.upsert(record)
                    let folder = try await store.jobDirectory(for: id)
                    let staged = try FileAccessService().stage(source, documentID: id, directory: folder)
                    try Task.checkCancellation()
                    var ready = record
                    ready.status = .queued
                    ready.stage = nil
                    ready.updatedAt = Date()
                    try await store.upsert(ready)
                    await MainActor.run {
                        guard let self, self.documents.contains(where: { $0.id == id }) else { return }
                        self.importTasks[id] = nil
                        self.stagedURLs[id] = staged.url
                        self.replace(ready)
                    }
                } catch {
                    let cancelled: Bool
                    if Task.isCancelled {
                        cancelled = true
                    } else if case DocumentServiceError.cancelled = error {
                        cancelled = true
                    } else {
                        cancelled = false
                    }
                    var final = record
                    final.status = cancelled ? .cancelled : .failed
                    final.stage = nil
                    final.errorMessage = cancelled ? DocumentServiceError.cancelled.localizedDescription : error.localizedDescription
                    final.updatedAt = Date()
                    try? await store.upsert(final)
                    await MainActor.run {
                        guard let self, self.documents.contains(where: { $0.id == id }) else { return }
                        self.importTasks[id] = nil
                        self.replace(final)
                    }
                }
            }
            importTasks[id] = task
        }
    }
    func convertSelected(ocrMode overrideMode: String? = nil) {
        guard let record = selectedDocument else {
            alertMessage = "Select a document before converting."
            return
        }
        guard let input = stagedURLs[record.id] else {
            alertMessage = "This document is still being prepared. Please wait a moment and try again."
            return
        }
        guard let coordinator else {
            alertMessage = coordinatorUnavailableMessage ?? "The conversion engine is unavailable."
            return
        }
        let id = record.id
        Task {
            if [.completed, .needsReview].contains(record.status),
               let draft = await draftNeedingDecision(for: record) {
                reconversionDrafts[id] = draft
                pendingReconversion = id
                return
            }
            await startConversion(record: record, input: input, coordinator: coordinator,
                                  overrideMode: overrideMode, draft: nil, keepDraft: false)
        }
    }

    private func startConversion(record: DocumentRecord, input: URL,
                                  coordinator: ConversionCoordinator,
                                  overrideMode: String?, draft: DraftSnapshot?, keepDraft: Bool) async {
        var leased = false
        do {
            let mode = overrideMode ?? (UserDefaults.standard.bool(forKey: "ocrEnabled") ? "auto" : "off")
            let modelURL = mode == "off" ? nil : try await modelDirectoryIfNeeded()
            leased = modelURL != nil
            let options = ConversionOptions(ocrMode: mode,
                                            password: password.isEmpty ? nil : password,
                                            modelDirectory: modelURL)
            if [.completed, .needsReview].contains(record.status) {
                try await coordinator.retry(documentID: record.id, stagedInput: input, options: options)
            } else {
                try await coordinator.enqueue(document: record, stagedInput: input, options: options)
            }
            await reload()
            await coordinator.waitUntilIdle()
            await reload()

            guard let finished = documents.first(where: { $0.id == record.id }),
                  [.completed, .needsReview].contains(finished.status) else { return }
            if let draft {
                if keepDraft {
                    pendingDrafts[record.id] = DraftSnapshot(markdown: draft.markdown, revision: finished.revision)
                    if selection == record.id { markdown = draft.markdown }
                    try await store?.saveDraft(draft.markdown, for: record.id, revision: finished.revision)
                } else {
                    pendingDrafts[record.id] = nil
                    try await store?.discardDraft(for: record.id)
                }
                await reload()
            }
        } catch {
            alertMessage = error.localizedDescription
        }
        if leased { await ocrManager?.releaseLease() }
    }

    private func draftNeedingDecision(for record: DocumentRecord) async -> DraftSnapshot? {
        guard let store, let resultRevision = record.resultRevision else { return nil }
        let result = try? await store.result(for: record.id, revision: resultRevision)
        let draft: DraftSnapshot?
        if let pending = pendingDrafts[record.id] {
            draft = pending
        } else if let saved = try? await store.draft(for: record.id) {
            draft = DraftSnapshot(markdown: saved.markdown, revision: saved.revision)
        } else {
            draft = nil
        }
        guard let draft, draft.markdown != result?.markdown else { return nil }
        return draft
    }
    func convertAll() {
        conversionTask?.cancel()
        let queued = documents.filter { $0.status == .queued }
        guard !queued.isEmpty else {
            alertMessage = "There are no waiting documents to convert."
            return
        }
        guard let coordinator else {
            alertMessage = coordinatorUnavailableMessage ?? "The conversion engine is unavailable."
            return
        }
        conversionTask = Task { [weak self] in
            guard let self else { return }
            var leased = false
            do {
                let modelURL = try await modelDirectoryIfNeeded()
                leased = modelURL != nil
                let options = ConversionOptions(ocrMode: UserDefaults.standard.bool(forKey: "ocrEnabled") ? "auto" : "off", modelDirectory: modelURL)
                for record in queued {
                    guard !Task.isCancelled else { break }
                    guard let input = stagedURLs[record.id] else {
                        alertMessage = "\(record.sourceName): the staged PDF is not ready yet."
                        continue
                    }
                    do { try await coordinator.enqueue(document: record, stagedInput: input, options: options) }
                    catch { alertMessage = "\(record.sourceName): \(error.localizedDescription)" }
                }
                await coordinator.waitUntilIdle()
            } catch { alertMessage = error.localizedDescription }
            if leased { await ocrManager?.releaseLease() }
            await reload()
        }
    }

    func requestClearList() {
        guard !documents.isEmpty else { return }
        isClearListConfirmationPresented = true
    }

    func clearList() {
        guard let store else {
            alertMessage = "Parchley could not open its workspace."
            return
        }
        isClearListConfirmationPresented = false
        conversionTask?.cancel()
        let ids = documents.map(\.id)
        let importing = importTasks
        Task { [weak self] in
            for id in ids {
                do {
                    if let task = importing[id] {
                        task.cancel()
                        await task.value
                        try await store.remove(documentID: id)
                    } else if let coordinator = self?.coordinator {
                        try await coordinator.remove(documentID: id)
                    } else {
                        try await store.remove(documentID: id)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.alertMessage = "Could not remove all documents: \(error.localizedDescription)"
                    }
                }
            }
            await self?.coordinator?.waitUntilIdle()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.documents.removeAll()
                self.stagedURLs.removeAll()
                self.importTasks.removeAll()
                self.pendingDrafts.removeAll()
                self.reconversionDrafts.removeAll()
                self.pendingRemoval = nil
                self.pendingReconversion = nil
                self.selection = nil
                self.markdown = ""
                self.selectedResult = nil
            }
            await self?.reload()
        }
    }

    func cancel(_ id: UUID) {
        if let task = importTasks[id] {
            task.cancel()
            if let index = documents.firstIndex(where: { $0.id == id }) {
                documents[index].status = .cancelling
                documents[index].stage = "Stopping import"
                documents[index].errorMessage = nil
            }
            return
        }
        Task {
            do {
                try await coordinator?.cancel(documentID: id)
                await reload()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
    func moveEarlier(_ id: UUID) { Task { do { try await coordinator?.moveEarlier(documentID: id); if let index = documents.firstIndex(where: { $0.id == id }), index > 0 { documents.swapAt(index, index - 1) } } catch { alertMessage = error.localizedDescription } } }
    func retry(_ id: UUID) { guard let input = stagedURLs[id], let coordinator else { alertMessage = "The staged PDF is no longer available. Import it again."; return }; Task { var leased = false; do { let modelURL = try await modelDirectoryIfNeeded(); leased = modelURL != nil; try await coordinator.retry(documentID: id, stagedInput: input, options: ConversionOptions(ocrMode: UserDefaults.standard.bool(forKey: "ocrEnabled") ? "auto" : "off", password: password.isEmpty ? nil : password, modelDirectory: modelURL)); await coordinator.waitUntilIdle(); await reload() } catch { alertMessage = error.localizedDescription }; if leased { await ocrManager?.releaseLease() } } }
    func requestRemove(_ id: UUID) { pendingRemoval = id }
    func confirmRemove() {
        guard let id = pendingRemoval else { return }
        pendingRemoval = nil
        let importing = importTasks[id]
        importing?.cancel()
        Task {
            do {
                if let importing {
                    await importing.value
                    try await store?.remove(documentID: id)
                } else {
                    try await coordinator?.remove(documentID: id)
                }
                stagedURLs[id] = nil
                documents.removeAll { $0.id == id }
                pendingDrafts[id] = nil
                reconversionDrafts[id] = nil
                if selection == id {
                    selection = documents.first?.id
                    markdown = ""
                    selectedResult = nil
                }
                await reload()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
    func updateMarkdown(_ value: String) { markdown = value; guard let id = selection, let record = selectedDocument else { return }; pendingDrafts[id] = DraftSnapshot(markdown: value, revision: record.revision); scheduleDraftSave() }
    private func scheduleDraftSave() { draftTask?.cancel(); draftTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(350)); guard !Task.isCancelled else { return }; await self?.flushDrafts() } }
    func loadDraft() async { guard let id = selection, let store else { return }; let generation = loadGeneration; guard let record = documents.first(where: { $0.id == id }) else { return }; var result: EngineResult? = nil; if let revision = record.resultRevision { result = try? await store.result(for: id, revision: revision) }; let persistedDraft = try? await store.draft(for: id); guard selection == id, loadGeneration == generation else { return }; selectedResult = result; if let pending = pendingDrafts[id] { markdown = pending.markdown } else if let draft = persistedDraft { markdown = draft.markdown } else { markdown = result?.markdown ?? "" } }
    func copyMarkdown() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(markdown, forType: .string); alertMessage = "Markdown copied to the clipboard." }
    func resolveReconversion(replaceDraft: Bool) {
        guard let id = pendingReconversion,
              let record = documents.first(where: { $0.id == id }),
              let input = stagedURLs[id],
              let coordinator else { return }
        pendingReconversion = nil
        let draft = reconversionDrafts.removeValue(forKey: id)
        Task {
            await startConversion(record: record, input: input, coordinator: coordinator,
                                  overrideMode: nil, draft: draft, keepDraft: !replaceDraft)
        }
    }
    func exportBatch(to folder: URL) { guard let store else { return }; let service = ExportService(); Task { var report: [String] = []; for record in documents { guard let revision = record.resultRevision else { continue }; let text: String; if record.id == selection { text = markdown } else if let pending = pendingDrafts[record.id]?.markdown { text = pending } else if let draft = try? await store.draft(for: record.id) { text = draft.markdown } else { text = (try? await store.result(for: record.id, revision: revision))?.markdown ?? "" }; do { _ = try service.export(ExportItem(documentID: record.id, filename: record.sourceName, markdown: text), to: folder); report.append("\(record.sourceName): exported") } catch { report.append("\(record.sourceName): \(error.localizedDescription)") } }; alertMessage = report.joined(separator: "\n") } }
    func installOCRAndConvert() { guard let manager = ocrManager else { alertMessage = "OCR model support is unavailable."; return }; Task { do { _ = try await manager.install(ocrManifest); convertSelected() } catch { alertMessage = error.localizedDescription } } }
    private func markdownFor(record: DocumentRecord, url: URL) -> String { if record.id == selection { return markdown }; return (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private func replace(_ record: DocumentRecord) { if let i = documents.firstIndex(where: { $0.id == record.id }) { documents[i] = record } }
    private func modelDirectoryIfNeeded() async throws -> URL? { guard UserDefaults.standard.bool(forKey: "ocrEnabled"), let manager = ocrManager else { return nil }; return try await manager.acquireLease() }
    func flushDraft() async { await flushDrafts() }
    func flushDrafts() async { draftTask?.cancel(); guard let store else { return }; let drafts = pendingDrafts; for (id, draft) in drafts { do { try await store.saveDraft(draft.markdown, for: id, revision: draft.revision); if pendingDrafts[id]?.markdown == draft.markdown { pendingDrafts[id] = nil } } catch { alertMessage = error.localizedDescription } } }
    var hasPendingDrafts: Bool { !pendingDrafts.isEmpty }
    func selectDocument(_ id: UUID?) { Task { await flushDrafts(); await MainActor.run { self.loadGeneration += 1; self.selection = id; self.selectedPage = 1 }; guard let id else { markdown = ""; selectedResult = nil; return }; let generation = loadGeneration; await loadDraft(); if self.selection != id || self.loadGeneration != generation { return } } }
}

struct ContentView: View {
    let model: ParchleyAppModel
    @State private var viewMode = ReviewMode.pdf
    @State private var isDropTargeted = false
    enum ReviewMode: String, CaseIterable, Hashable { case pdf = "PDF", source = "Source", preview = "Preview" }
    var body: some View {
        @Bindable var model = model
        NavigationSplitView { Sidebar(model: model) } detail: { if let document = model.selectedDocument { ReviewWorkspace(document: document, model: model, viewMode: $viewMode) } else { EmptyWorkspace { model.choosePDFs() } } }
            .navigationSplitViewStyle(.balanced)
            .inspector(isPresented: $model.showInspector) { if let result = model.selectedResult { WarningInspector(engineVersion: result.engineVersion, modelVersion: result.modelVersion, pages: result.pages, warnings: result.warnings, selectedPage: $model.selectedPage) } else { Text("No conversion result yet.").foregroundStyle(.secondary).padding() } }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { model.choosePDFs() } label: {
                        Label("Add PDFs", systemImage: "plus")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Add one or more PDF files")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.convertSelected() } label: {
                        Label("Convert", systemImage: "play.fill")
                    }
                    .disabled(!model.canConvert)
                    .help("Convert the selected PDF to Markdown")

                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Convert All", systemImage: "arrow.triangle.2.circlepath") { model.convertAll() }
                            .disabled(!model.canConvertAll)

                        if let selected = model.selectedDocument,
                           [.preparing, .converting, .cancelling].contains(selected.status) {
                            Button(selected.status == .cancelling ? "Stopping…" : "Cancel", systemImage: "xmark") {
                                model.cancel(selected.id)
                            }
                            .disabled(selected.status == .cancelling)
                        }

                        Divider()

                        Button { model.copyMarkdown() } label: {
                            Label("Copy Markdown", systemImage: "doc.on.doc")
                        }
                        .disabled(model.markdown.isEmpty)

                        Button("Export…", systemImage: "square.and.arrow.down") { model.isSavePanelPresented = true }
                            .disabled(model.markdown.isEmpty)
                        Button("Export All…", systemImage: "square.and.arrow.down.on.square") { model.isBatchExportPresented = true }
                            .disabled(model.documents.allSatisfy { $0.resultRevision == nil })

                        Divider()

                        Button("Clear List", systemImage: "trash", role: .destructive) { model.requestClearList() }
                            .disabled(!model.hasDocuments)
                    }
                    .help("More document actions")
                }

                ToolbarItem(placement: .secondaryAction) {
                    Button { model.showInspector.toggle() } label: {
                        Label(model.showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                    }
                    .help(model.showInspector ? "Hide conversion details" : "Show conversion details")
                }
            }
            .overlay { if isDropTargeted { DropOverlay() } }
            .fileImporter(isPresented: $model.isImportPanelPresented,
                          allowedContentTypes: [.pdf],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    model.importFiles(urls)
                case .failure(let error):
                    let nsError = error as NSError
                    guard nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError else { return }
                    model.alertMessage = error.localizedDescription
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in Task { model.importFiles(await loadURLs(from: providers)) }; return true }
            .fileImporter(isPresented: $model.isBatchExportPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { if case .success(let urls) = $0, let folder = urls.first { model.exportBatch(to: folder) } }
            .fileExporter(isPresented: $model.isSavePanelPresented, document: MarkdownFileDocument(text: model.markdown), contentType: .plainText, defaultFilename: ((model.selectedDocument?.sourceName ?? "Untitled") + ".md")) { if case .failure(let error) = $0 { model.alertMessage = error.localizedDescription } }
            .onReceive(NotificationCenter.default.publisher(for: .parchleyImport)) { _ in model.choosePDFs() }
            .onReceive(NotificationCenter.default.publisher(for: .parchleyCopy)) { _ in model.copyMarkdown() }
            .onReceive(NotificationCenter.default.publisher(for: .parchleySave)) { _ in model.isSavePanelPresented = true }
            .alert("Parchley", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) { Button("OK") { model.alertMessage = nil } } message: { Text(model.alertMessage ?? "") }
            .confirmationDialog("Remove this document?", isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })) { Button("Remove", role: .destructive) { model.confirmRemove() }; Button("Cancel", role: .cancel) {} }
            .confirmationDialog("Clear document list?", isPresented: $model.isClearListConfirmationPresented) { Button("Clear List", role: .destructive) { model.clearList() }; Button("Cancel", role: .cancel) {} } message: { Text("This removes all imported PDFs, conversion results, and drafts from Parchley.") }
            .confirmationDialog("Replace edited Markdown?", isPresented: Binding(get: { model.pendingReconversion != nil }, set: { if !$0 { model.pendingReconversion = nil } })) { Button("Replace draft", role: .destructive) { model.resolveReconversion(replaceDraft: true) }; Button("Keep draft") { model.resolveReconversion(replaceDraft: false) }; Button("Cancel", role: .cancel) {} } message: { Text("A newer conversion will create a new generated revision. Replace draft discards the saved edits after the conversion succeeds. Keep draft restores them on top of the new result.") }
    }
}
private struct Sidebar: View {
    let model: ParchleyAppModel
    @State private var searchText = ""

    private var visibleDocuments: [DocumentRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.documents }
        return model.documents.filter { $0.sourceName.localizedStandardContains(query) }
    }

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.selectDocument($0) })) {
            Section("Documents") {
                if model.documents.isEmpty {
                    SidebarEmptyState { model.choosePDFs() }
                } else if visibleDocuments.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(visibleDocuments) { document in
                        DocumentRow(document: document)
                            .tag(document.id)
                            .contextMenu {
                                if document.status == .queued,
                                   let index = model.documents.firstIndex(where: { $0.id == document.id }),
                                   index > 0 {
                                    Button("Move Earlier", systemImage: "arrow.up") {
                                        model.moveEarlier(document.id)
                                    }
                                }

                                if [.failed, .interrupted, .cancelled].contains(document.status) {
                                    Button("Retry", systemImage: "arrow.clockwise") {
                                        model.retry(document.id)
                                    }
                                }

                                if [.preparing, .converting].contains(document.status) {
                                    Button("Cancel", systemImage: "xmark") {
                                        model.cancel(document.id)
                                    }
                                }

                                if document.status == .queued ||
                                    [.failed, .interrupted, .cancelled, .preparing, .converting].contains(document.status) {
                                    Divider()
                                }

                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    model.requestRemove(document.id)
                                }
                            }
                    }
                    .onDelete { offsets in
                        offsets.map { visibleDocuments[$0].id }.forEach(model.requestRemove)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search PDFs")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .navigationTitle("Parchley")
        .safeAreaInset(edge: .bottom) {
            Text("Drop PDFs here or choose Add PDFs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}

private struct DocumentRow: View {
    let document: DocumentRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.sourceName)
                    .lineLimit(1)
                Text(detailLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if [.preparing, .converting, .cancelling].contains(document.status),
                   let total = document.pagesTotal, total > 0,
                   let completed = document.pagesCompleted {
                    ProgressView(value: Double(completed), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel("\(detailLabel) progress")
                        .accessibilityValue("\(completed) of \(total) pages")
                } else if [.preparing, .converting, .cancelling].contains(document.status) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(detailLabel)
                }
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.sourceName)
        .accessibilityValue(detailLabel)
        .accessibilityHint("Select to review this PDF")
    }

    private var detailLabel: String {
        if let error = document.errorMessage, document.status == .failed { return error }
        if let stage = document.stage, !stage.isEmpty { return stage }
        switch document.status {
        case .needsReview: return "Needs review"
        case .passwordRequired: return "Password required"
        case .modelRequired: return "OCR model required"
        case .interrupted: return "Interrupted"
        case .cancelled: return "Cancelled"
        case .preparing: return "Preparing document"
        case .converting: return "Converting"
        case .cancelling: return "Stopping after the current operation"
        case .queued: return "Waiting"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var icon: String {
        switch document.status {
        case .completed: "checkmark.circle.fill"
        case .needsReview: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "pause.circle.fill"
        case .cancelled: "nosign"
        default: "doc.text"
        }
    }

    private var color: Color {
        switch document.status {
        case .completed: .green
        case .needsReview: .orange
        case .failed: .red
        case .cancelling: .orange
        default: .secondary
        }
    }
}
private struct ReviewWorkspace: View {
    let document: DocumentRecord
    let model: ParchleyAppModel
    @Binding var viewMode: ContentView.ReviewMode

    var body: some View {
        VStack(spacing: 0) {
            if [.preparing, .converting, .cancelling].contains(document.status) {
                HStack {
                    if let total = document.pagesTotal, total > 0,
                       let completed = document.pagesCompleted {
                        ProgressView(value: Double(completed), total: Double(total)) {
                            Text(document.stage ?? "Converting")
                        } currentValueLabel: {
                            Text("\(completed) of \(total) pages")
                                .monospacedDigit()
                        }
                        .progressViewStyle(.linear)
                        .accessibilityLabel("\(document.stage ?? "Converting") progress")
                    } else {
                        ProgressView(document.stage ?? "Working…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            if document.status == .passwordRequired {
                HStack {
                    SecureField("PDF password", text: Bindable(model).password)
                    Button("Unlock") { model.convertSelected() }
                        .disabled(model.password.isEmpty)
                }
                .padding(.horizontal)
            }

            if document.status == .modelRequired {
                HStack {
                    Text("OCR model required")
                    Button("Download and continue") { model.installOCRAndConvert() }
                    Button("Skip OCR") { model.convertSelected(ocrMode: "off") }
                }
                .padding(.horizontal)
            }

            TabView(selection: $viewMode) {
                Tab("PDF", systemImage: "doc.richtext", value: .pdf) {
                    if let url = model.stagedURLs[document.id] {
                        PDFPreview(url: url, page: model.selectedPage)
                    } else {
                        ContentUnavailableView("PDF is not ready", systemImage: "doc.badge.ellipsis", description: Text("The document is still being prepared."))
                    }
                }

                Tab("Source", systemImage: "curlybraces", value: .source) {
                    if model.markdown.isEmpty && document.resultRevision == nil {
                        ContentUnavailableView("Markdown is not ready", systemImage: "curlybraces", description: Text("Convert this PDF to create editable Markdown."))
                    } else {
                        MarkdownEditor(
                            text: Binding(get: { model.markdown }, set: { value in model.updateMarkdown(value) }),
                            documentID: document.id
                        )
                    }
                }

                Tab("Preview", systemImage: "doc.text.magnifyingglass", value: .preview) {
                    if model.markdown.isEmpty {
                        ContentUnavailableView("Preview is not ready", systemImage: "doc.text.magnifyingglass", description: Text("Convert this PDF to preview the Markdown."))
                    } else {
                        MarkdownPreview(markdown: model.markdown)
                    }
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle(document.sourceName)
        .toolbarTitleDisplayMode(.inline)
    }
}
private struct SidebarEmptyState: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No PDFs yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                action()
            } label: {
                Label("Add PDFs…", systemImage: "plus.circle")
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

private struct EmptyWorkspace: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView {
                Label("Start with a PDF", systemImage: "doc.badge.plus")
            } description: {
                Text("Add one or more PDFs to review the source and create Markdown.")
            } actions: {
                Button("Add PDFs…", action: action)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("o", modifiers: .command)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("How it works")
                    .font(.headline)

                HStack(alignment: .top, spacing: 24) {
                    WorkflowStep(systemImage: "plus.circle", title: "Add", detail: "Choose or drop a PDF")
                    WorkflowStep(systemImage: "doc.text.magnifyingglass", title: "Review", detail: "Check the source and preview")
                    WorkflowStep(systemImage: "arrow.triangle.2.circlepath", title: "Convert", detail: "Create editable Markdown")
                }

                Text("You can also drag PDF files into the Documents sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 600, alignment: .leading)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkflowStep: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct DropOverlay: View { var body: some View { RoundedRectangle(cornerRadius: 18).stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(24).allowsHitTesting(false) } }
private func loadURLs(from providers: [NSItemProvider]) async -> [URL] { var result: [URL] = []; for provider in providers { let url: URL? = await withCheckedContinuation { continuation in _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) } }; if let url { result.append(url) } }; return result }
struct MarkdownFileDocument: FileDocument { static var readableContentTypes: [UTType] { [.plainText] }; var text: String; init(text: String = "") { self.text = text }; init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }; func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) } }
extension Notification.Name { static let parchleyImport = Notification.Name("Parchley.import"); static let parchleyCopy = Notification.Name("Parchley.copy"); static let parchleySave = Notification.Name("Parchley.save") }

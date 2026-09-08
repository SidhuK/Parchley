import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import ParchleyEngine

@MainActor @Observable
final class ParchleyAppModel {
    private struct DraftSnapshot: Equatable, Sendable {
        let markdown: String
        let revision: Int
    }

    var documents: [DocumentRecord] = []
    var selection: UUID?
    var markdown = ""
    private var passwords: [UUID: String] = [:]
    var password: String {
        get { selection.flatMap { passwords[$0] } ?? "" }
        set {
            guard let selection else { return }
            passwords[selection] = newValue
        }
    }
    var isSavePanelPresented = false
    var isBatchExportPresented = false
    var showInspector = false
    var selectedPage = 1
    var selectedResult: EngineResult?
    var alertMessage: String?
    var pendingRemoval: UUID?
    var pendingReconversion: UUID?
    var isClearListConfirmationPresented = false
    var isClearingList = false
    private(set) var stagedURLs: [UUID: URL] = [:]
    private var draftTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var pendingDrafts: [UUID: DraftSnapshot] = [:]
    private var loadGeneration = 0
    private var reloadRequestID = 0
    private var conversionTask: Task<Void, Never>?
    private var conversionTasks: [UUID: Task<Void, Never>] = [:]
    private var progressTasks: [UUID: Task<Void, Never>] = [:]
    private var ocrOperationTask: Task<Void, Never>?
    private var ocrOperationGeneration = 0
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = 0
    private var exportTask: Task<Void, Never>?
    private var exportGeneration = 0
    private var clearListTask: Task<Void, Never>?
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var activePDFOpenPanel: NSOpenPanel?
    private var reconversionDrafts: [UUID: DraftSnapshot] = [:]
    private var hasStarted = false
    let store: WorkspaceStore?
    let fileAccess: FileAccessService
    let exportService: ExportService
    let coordinator: ConversionCoordinator?
    private let coordinatorUnavailableMessage: String?
    let ocrManager: OCRModelManager?
    let ocrManifest: ModelManifest
    var preferences: AppPreferences
    private let pasteboard: NSPasteboard
    private let now: @Sendable () -> Date
    private let fileExists: @Sendable (URL) -> Bool

    init(dependencies: ParchleyDependencies = .live()) {
        store = dependencies.store
        fileAccess = dependencies.fileAccess
        exportService = dependencies.exportService
        coordinator = dependencies.coordinator
        coordinatorUnavailableMessage = dependencies.initializationMessage
        ocrManager = dependencies.ocrManager
        ocrManifest = dependencies.ocrManifest
        preferences = dependencies.preferences
        pasteboard = dependencies.pasteboard
        now = dependencies.now
        fileExists = dependencies.fileExists
    }
    var selectedDocument: DocumentRecord? { documents.first { $0.id == selection } }
    var hasDocuments: Bool { !documents.isEmpty }
    var canCancelSelected: Bool {
        guard !isClearingList, let status = selectedDocument?.status else { return false }
        return [.preparing, .converting].contains(status)
    }
    var canMoveSelectedEarlier: Bool {
        guard !isClearingList,
              let selected = selectedDocument,
              selected.status == .queued,
              let index = documents.firstIndex(where: { $0.id == selected.id }) else { return false }
        return index > 0
    }
    var canExportAll: Bool { !isClearingList && documents.contains { $0.resultRevision != nil } }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            try await store?.retryPendingArtifactCleanup()
        } catch {
            alertMessage = error.localizedDescription
        }
        if let manager = ocrManager {
            _ = await manager.discover(ocrManifest)
        }
        guard !Task.isCancelled else {
            hasStarted = false
            return
        }
        await reload()
        scheduleAutomaticConversions()
        pruneHistory()
    }

    func reload() async {
        guard let store else { return }
        reloadRequestID &+= 1
        let requestID = reloadRequestID
        let latest: [DocumentRecord]
        do {
            latest = try await store.documents()
        } catch {
            guard requestID == reloadRequestID else { return }
            alertMessage = error.localizedDescription
            return
        }
        guard requestID == reloadRequestID else { return }
        applyDocuments(latest)
        await loadDraft()
    }

    private func applyDocuments(_ latest: [DocumentRecord]) {
        guard let store else { return }
        let latestIDs = Set(latest.map(\.id))
        let optimisticImports = documents.filter {
            importTasks[$0.id] != nil && !latestIDs.contains($0.id)
        }
        let merged = latest + optimisticImports
        let previousSelection = selection
        let previousResultRevision = selectedDocument?.resultRevision

        documents = merged
        let ids = Set(merged.map(\.id))
        stagedURLs = stagedURLs.filter { ids.contains($0.key) }
        for document in merged {
            let staged = store.root.appendingPathComponent("Caches/Jobs/\(document.id.uuidString)/input.pdf")
            if fileExists(staged) {
                stagedURLs[document.id] = staged
            }
        }
        if selection.map({ !ids.contains($0) }) ?? true {
            selection = merged.first?.id
        }

        if previousSelection != selection || previousResultRevision != selectedDocument?.resultRevision {
            loadGeneration &+= 1
            selectedPage = 1
            markdown = ""
            selectedResult = nil
        }
    }

    func choosePDFs() {
        guard activePDFOpenPanel == nil else {
            activePDFOpenPanel?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.title = String(localized: "Add PDFs")
        panel.prompt = String(localized: "Add")
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        activePDFOpenPanel = panel

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self else { return }
            let urls = response == .OK ? panel?.urls ?? [] : []
            self.activePDFOpenPanel = nil
            if !urls.isEmpty {
                self.importFiles(urls)
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func importFiles(_ urls: [URL]) {
        guard let store else {
            alertMessage = coordinatorUnavailableMessage
                ?? String(localized: "Parchley could not open its workspace.")
            return
        }
        let sources = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        if sources.count != urls.count {
            alertMessage = String(localized: "Only PDF files can be imported.")
        }
        for source in sources {
            let id = UUID()
            let fileAccess = fileAccess
            let now = now
            let record = DocumentRecord(id: id,
                                        sourceName: source.deletingPathExtension().lastPathComponent,
                                        status: .preparing,
                                        stage: String(localized: "Preparing document"))
            documents.append(record)
            selectDocument(id)
            let task = Task { @concurrent [weak self] in
                do {
                    try await store.upsert(record)
                    let folder = try await store.jobDirectory(for: id)
                    let staged = try fileAccess.stage(source, documentID: id, directory: folder)
                    try Task.checkCancellation()
                    var ready = record
                    ready.status = .queued
                    ready.stage = nil
                    ready.updatedAt = now()
                    try await store.upsert(ready)
                    await MainActor.run {
                        guard let self, self.documents.contains(where: { $0.id == id }) else { return }
                        self.importTasks[id] = nil
                        self.stagedURLs[id] = staged.url
                        self.replace(ready)
                        self.scheduleAutomaticConversions()
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
                    final.updatedAt = now()
                    do {
                        try await store.upsert(final)
                    } catch {
                        final.errorMessage = "\(final.errorMessage ?? "") \(error.localizedDescription)"
                    }
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
            alertMessage = String(localized: "Select a document before converting.")
            return
        }
        guard let input = stagedURLs[record.id] else {
            alertMessage = String(localized: "This document is still being prepared. Please wait a moment and try again.")
            return
        }
        guard let coordinator else {
            alertMessage = coordinatorUnavailableMessage ?? String(localized: "The conversion engine is unavailable.")
            return
        }
        let id = record.id
        guard conversionTasks[id] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            if [.completed, .needsReview].contains(record.status),
               let draft = await self.draftNeedingDecision(for: record) {
                if !Task.isCancelled {
                    self.reconversionDrafts[id] = draft
                    self.pendingReconversion = id
                }
            } else if !Task.isCancelled {
                await self.startConversion(record: record, input: input, coordinator: coordinator,
                                            overrideMode: overrideMode, draft: nil, keepDraft: false)
            }
            self.conversionTasks[id] = nil
        }
        conversionTasks[id] = task
    }

    private func startConversion(record: DocumentRecord, input: URL,
                                  coordinator: ConversionCoordinator,
                                  overrideMode: String?, draft: DraftSnapshot?, keepDraft: Bool) async {
        await startProgressMonitoring(for: record.id, coordinator: coordinator)
        var leased = false
        let password = passwords[record.id]
        do {
            try Task.checkCancellation()
            let mode = overrideMode ?? (preferences.ocrEnabled ? "auto" : "off")
            let modelURL = mode == "off" ? nil : await modelDirectoryIfAvailable()
            leased = modelURL != nil
            let options = ConversionOptions(ocrMode: mode,
                                            password: password?.isEmpty == false ? password : nil,
                                            modelDirectory: modelURL)
            try Task.checkCancellation()
            if [.completed, .needsReview].contains(record.status) {
                try await coordinator.retry(documentID: record.id, stagedInput: input, options: options)
            } else {
                try await coordinator.enqueue(document: record, stagedInput: input, options: options)
            }
            await reload()
            passwords[record.id] = nil
            await coordinator.waitUntilIdle()
            await reload()

            if !Task.isCancelled,
               let finished = documents.first(where: { $0.id == record.id }),
               [.completed, .needsReview].contains(finished.status),
               let draft {
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
        } catch is CancellationError {
        } catch {
            alertMessage = error.localizedDescription
        }
        stopProgressMonitoring(for: record.id)
        if leased { await ocrManager?.releaseLease() }
    }

    private func draftNeedingDecision(for record: DocumentRecord) async -> DraftSnapshot? {
        guard let store, let resultRevision = record.resultRevision else { return nil }
        do {
            let result = try await store.result(for: record.id, revision: resultRevision)
            guard !Task.isCancelled else { return nil }
            let draft: DraftSnapshot?
            if let pending = pendingDrafts[record.id] {
                draft = pending
            } else if let saved = try await store.draft(for: record.id) {
                draft = DraftSnapshot(markdown: saved.markdown, revision: saved.revision)
            } else {
                draft = nil
            }
            guard !Task.isCancelled else { return nil }
            guard let draft, draft.markdown != result?.markdown else { return nil }
            return draft
        } catch is CancellationError {
            return nil
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }
    private func startProgressMonitoring(for documentID: UUID, coordinator: ConversionCoordinator) async {
        if let existing = progressTasks.removeValue(forKey: documentID) {
            existing.cancel()
            await existing.value
        }
        let stream = await coordinator.progress(for: documentID)
        progressTasks[documentID] = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.apply(update)
                if Self.isTerminal(update.status) { break }
            }
            if let self, self.progressTasks[documentID] != nil {
                self.progressTasks[documentID] = nil
            }
        }
    }

    private func stopProgressMonitoring(for documentID: UUID) {
        progressTasks.removeValue(forKey: documentID)?.cancel()
    }

    private func apply(_ update: ConversionProgress) {
        guard let index = documents.firstIndex(where: { $0.id == update.attempt.documentID }) else { return }
        var record = documents[index]
        if let attemptID = record.attemptID, attemptID != update.attempt.id { return }
        record.attemptID = update.attempt.id
        record.status = update.status
        record.stage = update.stage
        record.pagesCompleted = update.pagesCompleted
        record.pagesTotal = update.pagesTotal
        documents[index] = record
    }

    private static func isTerminal(_ status: DocumentStatus) -> Bool {
        [.completed, .needsReview, .failed, .cancelled, .passwordRequired, .modelRequired].contains(status)
    }

    private func scheduleAutomaticConversions() {
        guard conversionTask == nil, !isClearingList else { return }
        guard documents.contains(where: { $0.status == .queued && stagedURLs[$0.id] != nil }) else { return }
        guard let coordinator else {
            alertMessage = coordinatorUnavailableMessage ?? String(localized: "The conversion engine is unavailable.")
            return
        }
        conversionTask = Task { [weak self] in
            guard let self else { return }
            var leased = false
            var encounteredError = false
            do {
                let modelURL = preferences.ocrEnabled ? await modelDirectoryIfAvailable() : nil
                leased = modelURL != nil
                let options = ConversionOptions(ocrMode: preferences.ocrEnabled ? "auto" : "off", modelDirectory: modelURL)
                while !Task.isCancelled,
                      let record = documents.first(where: { $0.status == .queued && stagedURLs[$0.id] != nil }),
                      let input = stagedURLs[record.id] {
                    await startProgressMonitoring(for: record.id, coordinator: coordinator)
                    do {
                        try await coordinator.enqueue(document: record, stagedInput: input, options: options)
                        await coordinator.waitUntilIdle()
                    } catch {
                        alertMessage = "\(record.sourceName): \(error.localizedDescription)"
                        stopProgressMonitoring(for: record.id)
                        encounteredError = true
                        break
                    }
                    stopProgressMonitoring(for: record.id)
                    await reload()
                }
            } catch is CancellationError {
            } catch {
                alertMessage = error.localizedDescription
                encounteredError = true
            }
            if leased { await ocrManager?.releaseLease() }
            await reload()
            conversionTask = nil
            if !encounteredError { scheduleAutomaticConversions() }
        }
    }

    func requestClearList() {
        guard !documents.isEmpty, !isClearingList else { return }
        isClearListConfirmationPresented = true
    }

    func clearList() {
        guard let store else {
            alertMessage = String(localized: "Parchley could not open its workspace.")
            return
        }
        isClearListConfirmationPresented = false
        guard !isClearingList else { return }
        isClearingList = true
        let batchConversionTask = conversionTask
        let pendingDraftTask = draftTask
        let pendingSelectionTask = selectionTask
        conversionTask?.cancel()
        draftTask?.cancel()
        selectionTask?.cancel()
        exportTask?.cancel()
        exportGeneration &+= 1
        historyTask?.cancel()
        historyGeneration &+= 1
        let runningConversionTasks = Array(conversionTasks.values)
        conversionTasks.removeAll()
        runningConversionTasks.forEach { $0.cancel() }
        let ids = documents.map(\.id)
        let importing = importTasks
        let coordinator = self.coordinator
        clearListTask = Task { [weak self] in
            guard let self else { return }
            await pendingDraftTask?.value
            await pendingSelectionTask?.value
            await batchConversionTask?.value
            for task in runningConversionTasks { await task.value }
            for id in ids {
                do {
                    if let task = importing[id] {
                        task.cancel()
                        await task.value
                        try await store.remove(documentID: id)
                    } else if let coordinator {
                        try await coordinator.remove(documentID: id)
                    } else {
                        try await store.remove(documentID: id)
                    }
                } catch {
                    alertMessage = String(localized: "Could not remove all documents: \(error.localizedDescription)")
                }
            }
            await coordinator?.waitUntilIdle()
            documents.removeAll()
            stagedURLs.removeAll()
            importTasks.removeAll()
            pendingDrafts.removeAll()
            reconversionDrafts.removeAll()
            passwords.removeAll()
            pendingRemoval = nil
            pendingReconversion = nil
            selection = nil
            draftTask = nil
            selectionTask = nil
            loadGeneration &+= 1
            markdown = ""
            selectedResult = nil
            selectedPage = 1
            isClearingList = false
            clearListTask = nil
            await reload()
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
        Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator?.cancel(documentID: id)
                await reload()
            } catch is CancellationError {
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func moveEarlier(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator?.moveEarlier(documentID: id)
                if let index = documents.firstIndex(where: { $0.id == id }), index > 0 {
                    documents.swapAt(index, index - 1)
                }
            } catch is CancellationError {
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func retry(_ id: UUID) {
        guard let record = documents.first(where: { $0.id == id }),
              let input = stagedURLs[id], let coordinator else {
            alertMessage = String(localized: "The staged PDF is no longer available. Import it again.")
            return
        }
        guard conversionTasks[id] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.startConversion(record: record, input: input, coordinator: coordinator,
                                       overrideMode: nil, draft: nil, keepDraft: false)
            self.conversionTasks[id] = nil
        }
        conversionTasks[id] = task
    }

    func requestRemove(_ id: UUID) { pendingRemoval = id }

    func confirmRemove() {
        guard let id = pendingRemoval else { return }
        pendingRemoval = nil
        let importing = importTasks.removeValue(forKey: id)
        importing?.cancel()
        let converting = conversionTasks.removeValue(forKey: id)
        converting?.cancel()
        stopProgressMonitoring(for: id)
        Task { [weak self] in
            guard let self else { return }
            await converting?.value
            await importing?.value
            await flushDrafts()
            do {
                if let coordinator {
                    try await coordinator.remove(documentID: id)
                    await coordinator.waitUntilIdle()
                } else {
                    try await store?.remove(documentID: id)
                }
                stagedURLs[id] = nil
                documents.removeAll { $0.id == id }
                pendingDrafts[id] = nil
                reconversionDrafts[id] = nil
                if selection == id {
                    selection = documents.first?.id
                    loadGeneration &+= 1
                    selectedPage = 1
                    markdown = ""
                    selectedResult = nil
                }
                await reload()
            } catch is CancellationError {
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
    func updateMarkdown(_ value: String, for documentID: UUID) {
        guard selection == documentID,
              let record = documents.first(where: { $0.id == documentID }) else { return }
        markdown = value
        pendingDrafts[documentID] = DraftSnapshot(markdown: value, revision: record.revision)
        scheduleDraftSave()
    }

    private func scheduleDraftSave() {
        draftTask?.cancel()
        draftTask = Task { @concurrent [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledDraftSave()
        }
    }

    private func runScheduledDraftSave() async {
        draftTask = nil
        _ = await persistPendingDrafts()
    }
    func loadDraft() async {
        guard let id = selection else {
            selectedResult = nil
            markdown = ""
            return
        }
        guard let store,
              let record = documents.first(where: { $0.id == id }) else { return }
        let generation = loadGeneration
        do {
            var result: EngineResult?
            if let revision = record.resultRevision {
                result = try await store.result(for: id, revision: revision)
            }
            guard !Task.isCancelled else { return }
            let persistedDraft = try await store.draft(for: id)
            guard !Task.isCancelled, selection == id, loadGeneration == generation else { return }
            selectedResult = result
            if let pending = pendingDrafts[id] {
                markdown = pending.markdown
            } else if let draft = persistedDraft {
                markdown = draft.markdown
            } else {
                markdown = result?.markdown ?? ""
            }
        } catch is CancellationError {
            return
        } catch {
            guard selection == id, loadGeneration == generation else { return }
            alertMessage = error.localizedDescription
        }
    }

    func copyMarkdown() { pasteboard.clearContents(); pasteboard.setString(markdown, forType: .string) }
    func resolveReconversion(replaceDraft: Bool) {
        guard let id = pendingReconversion,
              let record = documents.first(where: { $0.id == id }),
              let input = stagedURLs[id],
              let coordinator else { return }
        pendingReconversion = nil
        let draft = reconversionDrafts.removeValue(forKey: id)
        guard conversionTasks[id] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.startConversion(record: record, input: input, coordinator: coordinator,
                                       overrideMode: nil, draft: draft, keepDraft: !replaceDraft)
            self.conversionTasks[id] = nil
        }
        conversionTasks[id] = task
    }

    func exportBatch(to folder: URL) {
        guard let store else {
            alertMessage = String(localized: "Parchley could not open its workspace.")
            return
        }
        exportTask?.cancel()
        exportGeneration &+= 1
        let generation = exportGeneration
        let records = documents
        let selectedID = selection
        let selectedMarkdown = markdown
        let pendingDrafts = pendingDrafts
        let exportService = exportService
        exportTask = Task { @concurrent [weak self] in
            var report: [String] = []
            for record in records {
                guard !Task.isCancelled, let revision = record.resultRevision else { continue }
                do {
                    let text: String
                    if record.id == selectedID {
                        text = selectedMarkdown
                    } else if let pending = pendingDrafts[record.id]?.markdown {
                        text = pending
                    } else if let draft = try await store.draft(for: record.id) {
                        text = draft.markdown
                    } else {
                        text = try await store.result(for: record.id, revision: revision)?.markdown ?? ""
                    }
                    _ = try exportService.export(
                        ExportItem(documentID: record.id, filename: record.sourceName, markdown: text),
                        to: folder
                    )
                    report.append("\(record.sourceName): exported")
                } catch {
                    report.append("\(record.sourceName): \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    guard let self, self.exportGeneration == generation else { return }
                    self.exportTask = nil
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.exportGeneration == generation else { return }
                if report.contains(where: { !$0.hasSuffix(": exported") }) {
                    self.alertMessage = report.joined(separator: "\n")
                }
                self.exportTask = nil
            }
        }
    }

    func installOCRAndConvert() {
        guard let record = selectedDocument,
              let input = stagedURLs[record.id],
              let coordinator,
              let manager = ocrManager else {
            alertMessage = String(localized: "OCR model support is unavailable.")
            return
        }
        let id = record.id
        guard conversionTasks[id] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await manager.install(self.ocrManifest)
                if !Task.isCancelled {
                    await self.startConversion(record: record, input: input, coordinator: coordinator,
                                               overrideMode: nil, draft: nil, keepDraft: false)
                }
            } catch is CancellationError {
            } catch {
                self.alertMessage = error.localizedDescription
            }
            self.conversionTasks[id] = nil
        }
        conversionTasks[id] = task
    }

    func installOCRModel() {
        guard let manager = ocrManager else {
            alertMessage = String(localized: "OCR model support is unavailable.")
            return
        }
        ocrOperationGeneration &+= 1
        let generation = ocrOperationGeneration
        ocrOperationTask?.cancel()
        ocrOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await manager.install(self.ocrManifest)
            } catch is CancellationError {
            } catch DocumentServiceError.cancelled {
            } catch {
                self.alertMessage = error.localizedDescription
            }
            guard self.ocrOperationGeneration == generation else { return }
            self.ocrOperationTask = nil
        }
    }

    func cancelOCRModelDownload() {
        guard let manager = ocrManager else { return }
        Task { await manager.cancelInstallation() }
    }

    func removeOCRModel() {
        guard let manager = ocrManager else { return }
        ocrOperationGeneration &+= 1
        let generation = ocrOperationGeneration
        ocrOperationTask?.cancel()
        ocrOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.remove()
            } catch is CancellationError {
            } catch DocumentServiceError.cancelled {
            } catch {
                self.alertMessage = error.localizedDescription
            }
            guard self.ocrOperationGeneration == generation else { return }
            self.ocrOperationTask = nil
        }
    }

    func pruneHistory() {
        historyGeneration &+= 1
        let generation = historyGeneration
        historyTask?.cancel()
        guard let store,
              let cutoff = Calendar.current.date(byAdding: .day, value: -preferences.retentionDays, to: currentDate()) else {
            alertMessage = String(localized: "The history retention period could not be calculated.")
            return
        }
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await persistPendingDrafts() else { return }
                try await store.prune(
                    completedBefore: cutoff,
                    protecting: Set(pendingDrafts.keys)
                )
            } catch is CancellationError {
            } catch {
                alertMessage = String(localized: "Could not prune history: \(error.localizedDescription)")
            }
            guard !Task.isCancelled, self.historyGeneration == generation else { return }
            await reload()
            guard self.historyGeneration == generation else { return }
            historyTask = nil
        }
    }

    func clearHistory() {
        historyGeneration &+= 1
        let generation = historyGeneration
        historyTask?.cancel()
        guard let store else { return }
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await persistPendingDrafts() else { return }
                try await store.clearHistory(protecting: Set(pendingDrafts.keys))
                await reload()
            } catch is CancellationError {
                return
            } catch {
                alertMessage = String(localized: "Could not clear history: \(error.localizedDescription)")
            }
            guard self.historyGeneration == generation else { return }
            historyTask = nil
        }
    }

    private func replace(_ record: DocumentRecord) { if let i = documents.firstIndex(where: { $0.id == record.id }) { documents[i] = record } }
    private func modelDirectoryIfAvailable() async -> URL? {
        guard preferences.ocrEnabled, let manager = ocrManager else { return nil }
        return await manager.acquireLeaseIfAvailable()
    }
    func currentDate() -> Date { now() }
    func flushDrafts() async {
        draftTask?.cancel()
        draftTask = nil
        _ = await persistPendingDrafts()
    }

    @discardableResult
    private func persistPendingDrafts() async -> Bool {
        guard let store else { return false }
        let drafts = pendingDrafts
        var succeeded = true
        for (id, draft) in drafts {
            do {
                try await store.saveDraft(draft.markdown, for: id, revision: draft.revision)
                if pendingDrafts[id] == draft {
                    pendingDrafts[id] = nil
                }
            } catch {
                succeeded = false
                alertMessage = error.localizedDescription
            }
        }
        return succeeded
    }

    var hasPendingDrafts: Bool { !pendingDrafts.isEmpty }
    func selectDocument(_ id: UUID?) {
        guard id == nil || documents.contains(where: { $0.id == id }) else { return }
        selectionTask?.cancel()
        loadGeneration &+= 1
        selection = id
        selectedPage = 1
        markdown = ""
        selectedResult = nil
        guard let id else { return }
        let generation = loadGeneration
        selectionTask = Task { [weak self] in
            guard let self else { return }
            await self.flushDrafts()
            guard !Task.isCancelled, self.selection == id, self.loadGeneration == generation else { return }
            await self.loadDraft()
        }
    }
}

struct ContentView: View {
    let model: ParchleyAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewMode = ReviewMode.pdf
    @State private var isDropTargeted = false
    @State private var searchText = ""
    enum ReviewMode: CaseIterable, Hashable { case pdf, source, preview }
    var body: some View {
        @Bindable var model = model
        NavigationSplitView { Sidebar(model: model, selection: $model.selection, searchText: $searchText) } detail: { if let document = model.selectedDocument { ReviewWorkspace(document: document, model: model, viewMode: $viewMode) } else { EmptyWorkspace(isDropTargeted: isDropTargeted) { model.choosePDFs() } } }
            .navigationSplitViewStyle(.balanced)
            .searchable(text: $searchText, prompt: "Search PDFs")
            .inspector(isPresented: $model.showInspector) { if let result = model.selectedResult { WarningInspector(engineVersion: result.engineVersion, modelVersion: result.modelVersion, pages: result.pages, warnings: result.warnings, selectedPage: $model.selectedPage) } else { Text("No conversion result yet.").foregroundStyle(.secondary).padding() } }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { model.choosePDFs() } label: {
                        Label("Add PDFs", systemImage: "plus")
                    }
                    .help("Add one or more PDF files")
                }

                if model.selectedDocument != nil {
                    ToolbarItem(placement: .principal) {
                        Picker("Document view", selection: $viewMode) {
                            Label("PDF", systemImage: "doc.richtext")
                                .tag(ReviewMode.pdf)
                            Label("Source", systemImage: "curlybraces")
                                .tag(ReviewMode.source)
                            Label("Preview", systemImage: "doc.text.magnifyingglass")
                                .tag(ReviewMode.preview)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .help("Switch document view")
                        .accessibilityLabel("Document view")
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Cancel Conversion", systemImage: "xmark") {
                            if let id = model.selectedDocument?.id { model.cancel(id) }
                        }
                        .disabled(!model.canCancelSelected)

                        Divider()

                        Button { model.copyMarkdown() } label: {
                            Label("Copy Markdown", systemImage: "doc.on.doc")
                        }
                        .disabled(model.markdown.isEmpty)

                        Button("Export…", systemImage: "square.and.arrow.down") { model.isSavePanelPresented = true }
                            .disabled(model.markdown.isEmpty)
                        Button("Export All…", systemImage: "square.and.arrow.down.on.square") { model.isBatchExportPresented = true }
                            .disabled(!model.canExportAll)

                        Divider()

                        Button("Clear List…", systemImage: "trash", role: .destructive) { model.requestClearList() }
                            .disabled(!model.hasDocuments || model.isClearingList)
                    }
                    .help("More document actions")

                    if model.selectedResult != nil || model.showInspector {
                        Button { model.showInspector.toggle() } label: {
                            if model.showInspector {
                                Label("Hide Inspector", systemImage: "sidebar.right")
                            } else {
                                Label("Show Inspector", systemImage: "sidebar.right")
                            }
                        }
                        .help(model.showInspector ? "Hide conversion details" : "Show conversion details")
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                Task { @MainActor in model.importFiles(await loadURLs(from: providers)) }
                return true
            }
            .fileImporter(isPresented: $model.isBatchExportPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { if case .success(let urls) = $0, let folder = urls.first { model.exportBatch(to: folder) } }
            .fileExporter(isPresented: $model.isSavePanelPresented, document: MarkdownFileDocument(text: model.markdown), contentType: .plainText, defaultFilename: ((model.selectedDocument?.sourceName ?? "Untitled") + ".md")) { if case .failure(let error) = $0 { model.alertMessage = error.localizedDescription } }
            .alert("Unable to complete action", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) { Button("Close") { model.alertMessage = nil } } message: { Text(model.alertMessage ?? "") }
            .confirmationDialog("Remove this document?", isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })) { Button("Remove", role: .destructive) { model.confirmRemove() }; Button("Cancel", role: .cancel) {} }
            .confirmationDialog("Clear document list?", isPresented: $model.isClearListConfirmationPresented) { Button("Clear List", role: .destructive) { model.clearList() }; Button("Cancel", role: .cancel) {} } message: { Text("This removes all imported PDFs, conversion results, and drafts from Parchley.") }
            .confirmationDialog("Replace edited Markdown?", isPresented: Binding(get: { model.pendingReconversion != nil }, set: { if !$0 { model.pendingReconversion = nil } })) { Button("Replace draft", role: .destructive) { model.resolveReconversion(replaceDraft: true) }; Button("Keep draft") { model.resolveReconversion(replaceDraft: false) }; Button("Cancel", role: .cancel) {} } message: { Text("A newer conversion will create a new generated revision. Replace draft discards the saved edits after the conversion succeeds. Keep draft restores them on top of the new result.") }
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
            .task { await model.start() }
    }
}
private struct Sidebar: View {
    let model: ParchleyAppModel
    @Binding var selection: UUID?
    @Binding var searchText: String

    private var visibleDocuments: [DocumentRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.documents }
        return model.documents.filter { $0.sourceName.localizedStandardContains(query) }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Documents") {
                if !model.documents.isEmpty && visibleDocuments.isEmpty {
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .navigationTitle("Parchley")
        .onChange(of: selection) { _, newSelection in
            model.selectDocument(newSelection)
        }
    }
}

private struct DocumentRow: View {
    let document: DocumentRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.sourceName)
                    .lineLimit(2)
                detailText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if [.preparing, .converting, .cancelling].contains(document.status),
                   let total = document.pagesTotal, total > 0,
                   let completed = document.pagesCompleted {
                    ProgressView(value: Double(completed), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else if [.preparing, .converting, .cancelling].contains(document.status) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.sourceName)
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint("Select to review this PDF")
    }

    private var detailText: Text {
        if let error = document.errorMessage, document.status == .failed { return Text(error) }
        if let stage = document.stage, !stage.isEmpty { return Text(stage) }
        return Text(document.status.localizedLabel)
    }

    private var accessibilityStatus: String {
        if let error = document.errorMessage, document.status == .failed { return error }
        if let stage = document.stage, !stage.isEmpty {
            if let completed = document.pagesCompleted, let total = document.pagesTotal {
                return "\(stage), \(completed) of \(total) pages"
            }
            return stage
        }
        return String(localized: document.status.localizedLabel)
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
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case password }

    var body: some View {
        VStack(spacing: 0) {
            if [.preparing, .converting, .cancelling].contains(document.status) {
                HStack {
                    if let total = document.pagesTotal, total > 0,
                       let completed = document.pagesCompleted {
                        ProgressView(value: Double(completed), total: Double(total)) {
                            if let stage = document.stage {
                                Text(stage)
                            } else {
                                Text("Converting")
                            }
                        } currentValueLabel: {
                            Text("\(completed) of \(total) pages")
                                .monospacedDigit()
                        }
                        .progressViewStyle(.linear)
                        .accessibilityLabel(progressLabel)
                        .accessibilityValue("\(completed) of \(total) pages")
                    } else {
                        Group {
                            if let stage = document.stage {
                                ProgressView(stage)
                            } else {
                                ProgressView("Working…")
                            }
                        }
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
                        .focused($focusedField, equals: .password)
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

            reviewContent
        }
        .navigationTitle(document.sourceName)
        .toolbarTitleDisplayMode(.inline)
        .defaultFocus($focusedField, .password)
        .task(id: "\(document.id.uuidString)-\(document.status.rawValue)") {
            focusedField = document.status == .passwordRequired ? .password : nil
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        switch viewMode {
        case .pdf:
            if let url = model.stagedURLs[document.id] {
                PDFPreview(url: url, page: model.selectedPage, password: model.password)
            } else {
                ContentUnavailableView("PDF is not ready", systemImage: "doc.badge.ellipsis", description: Text("The document is still being prepared."))
            }
        case .source:
            if model.markdown.isEmpty && document.resultRevision == nil {
                ContentUnavailableView("Markdown is not ready", systemImage: "curlybraces", description: Text("Convert this PDF to create editable Markdown."))
            } else {
                MarkdownEditor(
                    text: Binding(get: { model.markdown }, set: { value in model.updateMarkdown(value, for: document.id) }),
                    documentID: document.id
                )
            }
        case .preview:
            if model.markdown.isEmpty {
                ContentUnavailableView("Preview is not ready", systemImage: "doc.text.magnifyingglass", description: Text("Convert this PDF to preview the Markdown."))
            } else {
                MarkdownPreview(markdown: model.markdown)
            }
        }
    }

    private var progressLabel: Text {
        if let stage = document.stage { return Text("\(stage) progress") }
        return Text("Converting progress")
    }
}
private struct EmptyWorkspace: View {
    let isDropTargeted: Bool
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                isDropTargeted ? "Drop to add PDFs" : "Add a PDF",
                systemImage: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus"
            )
        } description: {
            VStack(spacing: 6) {
                Text("Drop one or more PDFs here, or choose files from your Mac.")
                Label("Documents stay on this Mac", systemImage: "lock.shield")
                    .font(.caption)
            }
        } actions: {
            Button("Choose PDFs…", systemImage: "plus", action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHint("Choose one or more PDF files. You can also drop files here.")
    }
}
private func loadURLs(from providers: [NSItemProvider]) async -> [URL] { var result: [URL] = []; for provider in providers { let url: URL? = await withCheckedContinuation { continuation in _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) } }; if let url { result.append(url) } }; return result }

private extension DocumentStatus {
    var localizedLabel: LocalizedStringResource {
        switch self {
        case .needsReview: "Needs review"
        case .passwordRequired: "Password required"
        case .modelRequired: "OCR model required"
        case .interrupted: "Interrupted"
        case .cancelled: "Cancelled"
        case .preparing: "Preparing document"
        case .converting: "Converting"
        case .cancelling: "Stopping after the current operation"
        case .queued: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

struct MarkdownFileDocument: FileDocument { static var readableContentTypes: [UTType] { [.plainText] }; var text: String; init(text: String = "") { self.text = text }; init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }; func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) } }

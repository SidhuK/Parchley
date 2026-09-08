import Foundation
import SwiftData

@ModelActor
public actor WorkspaceStore {
    public nonisolated var root: URL {
        modelContainer.configurations.first?.url.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Parchley", isDirectory: true)
    }

    private let fileManager = FileManager.default
    private var dateProvider = DateProvider()

    /// Opens the workspace at `root`, or at the app's Application Support folder
    /// when no root is supplied.
    public init(root: URL? = nil, dateProvider: DateProvider = DateProvider()) throws {
        let base = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parchley", isDirectory: true)
        let storeURL = base.appendingPathComponent("Parchley.store", isDirectory: false)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for path in ["Caches/Jobs", "Models"] {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }

        let schema = Schema([PersistedDocument.self])
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ParchleyMigrationPlan.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        self.modelContainer = container
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.dateProvider = dateProvider

        let hasDocuments = try context.fetch(FetchDescriptor<PersistedDocument>()).isEmpty == false
        let migrationMarker = base.appendingPathComponent("legacy-migration-complete")
        if !hasDocuments, !FileManager.default.fileExists(atPath: migrationMarker.path) {
            try Self.importLegacyWorkspace(from: base, context: context, now: dateProvider.now)
            try Data().write(to: migrationMarker, options: .atomic)
        }
        try Self.recoverInterruptedDocuments(in: context, root: base, now: dateProvider.now())
    }

    public func documents() throws -> [DocumentRecord] {
        let descriptor = FetchDescriptor<PersistedDocument>(
            sortBy: [SortDescriptor(\.queueOrder)]
        )
        do {
            return try modelContext.fetch(descriptor).map { try $0.record() }
        } catch {
            throw storageError(error, operation: "load documents")
        }
    }

    public func upsert(_ record: DocumentRecord) throws {
        if let entity = try entity(for: record.id) {
            entity.apply(record)
        } else {
            modelContext.insert(PersistedDocument(record: record, queueOrder: try nextQueueOrder()))
        }
        try saveContext()
    }

    /// Adds a document to the end of the persisted queue. A retry uses this
    /// operation so its in-memory and persisted positions agree.
    public func enqueue(_ record: DocumentRecord) throws {
        if let entity = try entity(for: record.id) {
            entity.apply(record)
            entity.queueOrder = try nextQueueOrder()
        } else {
            modelContext.insert(PersistedDocument(record: record, queueOrder: try nextQueueOrder()))
        }
        try saveContext()
    }

    public func record(for id: UUID) throws -> DocumentRecord? {
        try entity(for: id).map { try $0.record() }
    }

    public func moveEarlier(documentID: UUID) throws {
        let descriptor = FetchDescriptor<PersistedDocument>(
            sortBy: [SortDescriptor(\.queueOrder)]
        )
        let entities: [PersistedDocument]
        do {
            entities = try modelContext.fetch(descriptor)
        } catch {
            throw storageError(error, operation: "load queue order")
        }
        var reordered = entities
        guard let index = reordered.firstIndex(where: { $0.id == documentID }), index > 0 else { return }
        reordered.swapAt(index, index - 1)
        let order = reordered[index].queueOrder
        reordered[index].queueOrder = reordered[index - 1].queueOrder
        reordered[index - 1].queueOrder = order
        try saveContext()
    }

    /// Applies a state update only while the same attempt still owns the
    /// document. The check and save happen in one store operation, so a late
    /// progress or completion update cannot resurrect a removed or retried job.
    @discardableResult
    public func update(_ record: DocumentRecord, matching attempt: ConversionAttempt,
                       preservingCancellation: Bool = false) throws -> Bool {
        guard let entity = try entity(for: attempt.documentID),
              entity.attemptID == attempt.id,
              entity.revision == attempt.revision else {
            return false
        }
        if preservingCancellation,
           entity.statusRawValue == DocumentStatus.cancelling.rawValue,
           record.status != .cancelling {
            return false
        }
        let terminalStatuses: Set<String> = [
            DocumentStatus.completed.rawValue, DocumentStatus.needsReview.rawValue,
            DocumentStatus.failed.rawValue, DocumentStatus.cancelled.rawValue,
            DocumentStatus.passwordRequired.rawValue, DocumentStatus.modelRequired.rawValue
        ]
        if terminalStatuses.contains(entity.statusRawValue),
           !terminalStatuses.contains(record.status.rawValue) {
            return false
        }
        entity.apply(record)
        try saveContext()
        return true
    }

    /// Claims a persisted queued record for an attempt. Unlike `upsert`, this
    /// method never creates a missing record, which keeps a remove racing with
    /// queue startup from bringing the document back.
    @discardableResult
    public func start(_ record: DocumentRecord, attempt: ConversionAttempt) throws -> Bool {
        guard let entity = try entity(for: attempt.documentID),
              entity.revision == attempt.revision,
              entity.attemptID == nil,
              entity.statusRawValue == DocumentStatus.queued.rawValue else {
            return false
        }
        entity.apply(record)
        try saveContext()
        return true
    }

    public func remove(documentID: UUID) throws {
        if let entity = try entity(for: documentID) {
            try addCleanupTombstone(documentID)
            modelContext.delete(entity)
            try saveContext()
        }
        try performArtifactCleanup(for: documentID)
    }

    public func saveResult(_ result: EngineResult, for documentID: UUID, revision: Int) throws {
        guard let entity = try entity(for: documentID) else {
            throw DocumentServiceError.missingDocument
        }
        guard entity.revision == revision else {
            throw DocumentServiceError.staleAttempt
        }
        entity.resultData = try JSONEncoder.parchly.encode(result)
        entity.resultRevision = revision
        try saveContext()
    }

    /// Saves a result only if the attempt still owns the current revision.
    public func saveResult(_ result: EngineResult, for attempt: ConversionAttempt) throws {
        guard let entity = try entity(for: attempt.documentID) else {
            throw DocumentServiceError.missingDocument
        }
        guard entity.attemptID == attempt.id, entity.revision == attempt.revision else {
            throw DocumentServiceError.staleAttempt
        }
        guard entity.statusRawValue != DocumentStatus.cancelling.rawValue else {
            throw DocumentServiceError.cancelled
        }
        entity.resultData = try JSONEncoder.parchly.encode(result)
        entity.resultRevision = attempt.revision
        try saveContext()
    }

    @discardableResult
    public func complete(_ result: EngineResult, for attempt: ConversionAttempt,
                         status: DocumentStatus, updatedAt: Date) throws -> Bool {
        guard let entity = try entity(for: attempt.documentID),
              entity.attemptID == attempt.id,
              entity.revision == attempt.revision,
              entity.statusRawValue != DocumentStatus.cancelling.rawValue else {
            return false
        }
        entity.resultData = try JSONEncoder.parchly.encode(result)
        entity.resultRevision = attempt.revision
        entity.statusRawValue = status.rawValue
        entity.stage = nil
        entity.pagesCompleted = result.pages.count
        entity.pagesTotal = result.pages.isEmpty ? nil : result.pages.count
        entity.updatedAt = updatedAt
        entity.errorMessage = nil
        try saveContext()
        return true
    }

    public func saveDraft(_ markdown: String, for documentID: UUID, revision: Int) throws {
        guard let entity = try entity(for: documentID) else {
            throw DocumentServiceError.missingDocument
        }
        guard entity.revision == revision else {
            throw DocumentServiceError.staleAttempt
        }
        entity.draftMarkdown = markdown
        entity.draftRevision = revision
        try saveContext()
    }

    public func draft(for documentID: UUID) throws -> (markdown: String, revision: Int)? {
        guard let entity = try entity(for: documentID), let markdown = entity.draftMarkdown else {
            return nil
        }
        return (markdown, entity.draftRevision ?? 0)
    }

    public func discardDraft(for documentID: UUID) throws {
        if let entity = try entity(for: documentID) {
            entity.draftMarkdown = nil
            entity.draftRevision = nil
            try saveContext()
        }
        try fileManager.removeItemIfExists(
            at: root.appendingPathComponent("Drafts/\(documentID.uuidString)")
        )
    }

    public func result(for documentID: UUID, revision: Int) throws -> EngineResult? {
        guard let entity = try entity(for: documentID),
              entity.resultRevision == revision,
              let data = entity.resultData else {
            return nil
        }
        do {
            return try JSONDecoder.parchly.decode(EngineResult.self, from: data)
        } catch {
            throw storageError(error, operation: "decode the conversion result")
        }
    }

    public func hasDraft(for documentID: UUID) throws -> Bool {
        try entity(for: documentID)?.draftMarkdown != nil
    }

    public func clearHistory(protecting protectedIDs: Set<UUID> = []) throws {
        let descriptor = FetchDescriptor<PersistedDocument>()
        let entities: [PersistedDocument]
        do {
            entities = try modelContext.fetch(descriptor)
        } catch {
            throw storageError(error, operation: "load history")
        }
        let terminalStatuses: Set<String> = [DocumentStatus.completed.rawValue, DocumentStatus.needsReview.rawValue]
        let deleted = entities.filter {
            terminalStatuses.contains($0.statusRawValue)
                && $0.draftMarkdown == nil
                && !protectedIDs.contains($0.id)
        }
        for entity in deleted {
            try addCleanupTombstone(entity.id)
            modelContext.delete(entity)
        }
        try saveContext()
        for entity in deleted {
            try performArtifactCleanup(for: entity.id)
        }
    }

    public func prune(completedBefore cutoff: Date, protecting protectedIDs: Set<UUID> = []) throws {
        let descriptor = FetchDescriptor<PersistedDocument>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let completed: [PersistedDocument]
        do {
            completed = try modelContext.fetch(descriptor).filter {
                [DocumentStatus.completed.rawValue, DocumentStatus.needsReview.rawValue]
                    .contains($0.statusRawValue)
            }
        } catch {
            throw storageError(error, operation: "prune history")
        }
        let deleted = completed.filter { entity in
            entity.updatedAt < cutoff
                && entity.draftMarkdown == nil
                && !protectedIDs.contains(entity.id)
        }
        for entity in deleted {
            try addCleanupTombstone(entity.id)
            modelContext.delete(entity)
        }
        try saveContext()
        for entity in deleted {
            try performArtifactCleanup(for: entity.id)
        }
    }

    public func jobDirectory(for documentID: UUID) throws -> URL {
        let url = root.appendingPathComponent("Caches/Jobs/\(documentID.uuidString)")
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw storageError(error, operation: "create the conversion job directory")
        }
        return url
    }

    private func nextQueueOrder() throws -> Int {
        var descriptor = FetchDescriptor<PersistedDocument>(
            sortBy: [SortDescriptor(\.queueOrder, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        do {
            return (try modelContext.fetch(descriptor).first?.queueOrder ?? -1) + 1
        } catch {
            throw storageError(error, operation: "allocate queue order")
        }
    }

    private func saveContext() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw storageError(error, operation: "save the workspace")
        }
    }

    private func removeArtifacts(for documentID: UUID) throws {
        do {
            try fileManager.removeItemIfExists(
                at: root.appendingPathComponent("Caches/Jobs/\(documentID.uuidString)")
            )
            try fileManager.removeItemIfExists(
                at: root.appendingPathComponent("Results/\(documentID.uuidString)")
            )
            try fileManager.removeItemIfExists(
                at: root.appendingPathComponent("Drafts/\(documentID.uuidString)")
            )
        } catch {
            throw storageError(error, operation: "remove document files")
        }
    }

    private func entity(for id: UUID) throws -> PersistedDocument? {
        let descriptor = FetchDescriptor<PersistedDocument>(
            predicate: #Predicate<PersistedDocument> { document in
                document.id == id
            }
        )
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            throw storageError(error, operation: "load the document")
        }
    }

    private static func importLegacyWorkspace(from base: URL, context: ModelContext, now: @Sendable () -> Date) throws {
        guard let metadata = Self.loadLegacyMetadata(from: base) else { return }
        let recovered = Self.recovered(metadata, now: now)
        guard !recovered.documents.isEmpty else { return }

        var importedIDs = Set<UUID>()
        for (index, record) in recovered.documents.enumerated()
        where importedIDs.insert(record.id).inserted {
            let entity = PersistedDocument(record: record, queueOrder: index)
            if let revision = record.resultRevision {
                let resultURL = base
                    .appendingPathComponent("Results/\(record.id.uuidString)")
                    .appendingPathComponent("revision-\(revision).json")
                if FileManager.default.fileExists(atPath: resultURL.path) {
                    let data = try Data(contentsOf: resultURL)
                    _ = try JSONDecoder.parchly.decode(EngineResult.self, from: data)
                    entity.resultData = data
                } else {
                    entity.resultRevision = nil
                }
            }

            let draftURL = base
                .appendingPathComponent("Drafts/\(record.id.uuidString)")
                .appendingPathComponent("draft.md")
            if FileManager.default.fileExists(atPath: draftURL.path) {
                let data = try Data(contentsOf: draftURL)
                guard let markdown = String(data: data, encoding: .utf8) else {
                    throw DocumentServiceError.diskFailure("A legacy draft is not valid UTF-8.")
                }
                entity.draftMarkdown = markdown
                entity.draftRevision = recovered.draftRevisions[record.id] ?? 0
            }
            context.insert(entity)
        }
        try context.save()
    }

    private static func loadLegacyMetadata(from base: URL) -> WorkspaceMetadata? {
        let decoder = JSONDecoder.parchly
        let urls = [
            base.appendingPathComponent("workspace.json"),
            base.appendingPathComponent("workspace.last-good.json")
        ]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let value = try? decoder.decode(WorkspaceMetadata.self, from: data),
                  value.schemaVersion <= WorkspaceMetadata.currentSchema else {
                continue
            }
            return value
        }
        return nil
    }

    private static func recovered(_ value: WorkspaceMetadata, now: @Sendable () -> Date) -> WorkspaceMetadata {
        var copy = value
        copy.schemaVersion = WorkspaceMetadata.currentSchema
        for index in copy.documents.indices
        where [.preparing, .converting, .cancelling].contains(copy.documents[index].status) {
            copy.documents[index].status = .interrupted
            copy.documents[index].attemptID = nil
            copy.documents[index].stage = nil
            copy.documents[index].pagesCompleted = nil
            copy.documents[index].pagesTotal = nil
            copy.documents[index].errorMessage = "Conversion was interrupted. Retry to continue."
            copy.documents[index].updatedAt = now()
        }
        return copy
    }

    private static func recoverInterruptedDocuments(in context: ModelContext, root: URL, now: Date) throws {
        let transient = [
            DocumentStatus.preparing.rawValue,
            DocumentStatus.converting.rawValue,
            DocumentStatus.cancelling.rawValue
        ]
        let documents = try context.fetch(FetchDescriptor<PersistedDocument>())
        var changed = false
        for document in documents where transient.contains(document.statusRawValue) {
            let input = root.appendingPathComponent("Caches/Jobs/\(document.id.uuidString)/input.pdf")
            let hasInput = FileManager.default.fileExists(atPath: input.path)
            document.statusRawValue = hasInput
                ? DocumentStatus.interrupted.rawValue
                : DocumentStatus.failed.rawValue
            document.attemptID = nil
            document.stage = nil
            document.pagesCompleted = nil
            document.pagesTotal = nil
            document.errorMessage = hasInput
                ? "Conversion was interrupted. Retry to continue."
                : "Import was interrupted before the PDF was staged. Import it again."
            document.updatedAt = now
            changed = true
        }
        if changed {
            try context.save()
        }
    }

    private func storageError(_ error: Error, operation: String) -> DocumentServiceError {
        .diskFailure("Parchley could not " + operation + ". " + error.localizedDescription)
    }

    private var cleanupTombstoneURL: URL {
        root.appendingPathComponent("pending-artifact-cleanup.json")
    }

    private func cleanupTombstones() throws -> Set<UUID> {
        guard fileManager.fileExists(atPath: cleanupTombstoneURL.path) else { return [] }
        return Set(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: cleanupTombstoneURL)))
    }

    private func writeCleanupTombstones(_ ids: Set<UUID>) throws {
        if ids.isEmpty {
            try fileManager.removeItemIfExists(at: cleanupTombstoneURL)
        } else {
            try JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString })
                .write(to: cleanupTombstoneURL, options: .atomic)
        }
    }

    private func addCleanupTombstone(_ id: UUID) throws {
        var ids = try cleanupTombstones()
        ids.insert(id)
        try writeCleanupTombstones(ids)
    }

    private func performArtifactCleanup(for id: UUID) throws {
        try removeArtifacts(for: id)
        var ids = try cleanupTombstones()
        ids.remove(id)
        try writeCleanupTombstones(ids)
    }

    public func retryPendingArtifactCleanup() throws {
        for id in try cleanupTombstones() {
            if try entity(for: id) == nil {
                try performArtifactCleanup(for: id)
            } else {
                var ids = try cleanupTombstones()
                ids.remove(id)
                try writeCleanupTombstones(ids)
            }
        }
    }
}

private extension JSONEncoder {
    nonisolated static var parchly: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var parchly: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension FileManager {
    nonisolated func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}

import Foundation

nonisolated public struct ConversionOptions: Sendable, Equatable { public var pageSelection: [Int]; public var ocrMode: String; public var password: String?; public var modelDirectory: URL?; public init(pageSelection: [Int] = [], ocrMode: String = "auto", password: String? = nil, modelDirectory: URL? = nil) { self.pageSelection = pageSelection; self.ocrMode = ocrMode; self.password = password; self.modelDirectory = modelDirectory } }
nonisolated public struct ConversionProgress: Sendable, Equatable { public let attempt: ConversionAttempt; public let status: DocumentStatus; public let stage: String?; public let pagesCompleted: Int?; public let pagesTotal: Int?; public init(attempt: ConversionAttempt, status: DocumentStatus, stage: String? = nil, pagesCompleted: Int? = nil, pagesTotal: Int? = nil) { self.attempt = attempt; self.status = status; self.stage = stage; self.pagesCompleted = pagesCompleted; self.pagesTotal = pagesTotal } }
nonisolated public struct ConversionEngineProgress: Sendable, Equatable {
    public let status: DocumentStatus
    public let stage: String?
    public let pagesCompleted: Int?
    public let pagesTotal: Int?

    public init(status: DocumentStatus, stage: String? = nil, pagesCompleted: Int? = nil, pagesTotal: Int? = nil) {
        self.status = status
        self.stage = stage
        self.pagesCompleted = pagesCompleted
        self.pagesTotal = pagesTotal
    }
}

public protocol ConversionEngine: Sendable {
    func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult
    func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions) async throws -> EngineResult
    func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions,
                 progress: @escaping @Sendable (ConversionEngineProgress) -> Void) async throws -> EngineResult
    func cancel(attemptID: UUID) async
}
public extension ConversionEngine { func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions) async throws -> EngineResult { try await convert(input: input, attempt: attempt) } }
public extension ConversionEngine {
    func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions,
                 progress: @escaping @Sendable (ConversionEngineProgress) -> Void) async throws -> EngineResult {
        try await convert(input: input, attempt: attempt, options: options)
    }
}

public actor ConversionCoordinator {
    private struct Pending: Sendable { let document: DocumentRecord; let input: URL; let options: ConversionOptions }
    private let engine: any ConversionEngine; private let store: WorkspaceStore
    private var pending: [Pending] = []; private var active: (attempt: ConversionAttempt, task: Task<Void, Never>)?; private var starting = false; private var reservedIDs: Set<UUID> = []; private var pendingRemovals: Set<UUID> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var progressContinuations: [UUID: AsyncStream<ConversionProgress>.Continuation] = [:]
    public init(engine: any ConversionEngine, store: WorkspaceStore) { self.engine = engine; self.store = store }
    public func enqueue(document: DocumentRecord, stagedInput: URL, options: ConversionOptions = .init()) async throws {
        guard reservedIDs.insert(document.id).inserted else { throw DocumentServiceError.conflict }
        do {
            var record = document
            record.status = .queued
            record.errorMessage = nil
            record.stage = nil
            record.pagesCompleted = nil
            record.pagesTotal = nil
            try await store.upsert(record)
            pending.append(Pending(document: record, input: stagedInput, options: options))
            await startNextIfNeeded()
        } catch {
            reservedIDs.remove(document.id)
            throw error
        }
    }
    public func cancel(documentID: UUID) async throws {
        if let i = pending.firstIndex(where: { $0.document.id == documentID }) {
            let p = pending.remove(at: i)
            reservedIDs.remove(documentID)
            var record = p.document
            record.status = .cancelled
            record.stage = nil
            record.pagesCompleted = nil
            record.pagesTotal = nil
            record.errorMessage = DocumentServiceError.cancelled.localizedDescription
            record.updatedAt = Date()
            try await store.upsert(record)
            finishIfIdle()
            return
        }
        guard let active, active.attempt.documentID == documentID else { return }
        guard var record = await store.record(for: documentID), record.attemptID == active.attempt.id else { return }
        record.status = .cancelling
        record.stage = "Stopping after the current operation"
        record.updatedAt = Date()
        try await store.upsert(record)
        emit(ConversionProgress(attempt: active.attempt, status: .cancelling, stage: record.stage))
        await engine.cancel(attemptID: active.attempt.id)
    }
    public func moveEarlier(documentID: UUID) async throws { guard active?.attempt.documentID != documentID, let index = pending.firstIndex(where: { $0.document.id == documentID }), index > 0 else { return }; pending.swapAt(index, index - 1); try await store.moveEarlier(documentID: documentID) }
    public func retry(documentID: UUID, stagedInput: URL, options: ConversionOptions = .init()) async throws { guard active?.attempt.documentID != documentID else { throw DocumentServiceError.conflict }; guard var old = await store.record(for: documentID) else { throw DocumentServiceError.missingDocument }; old.revision += 1; old.status = .queued; old.attemptID = nil; old.errorMessage = nil; try await enqueue(document: old, stagedInput: stagedInput, options: options) }
    public func remove(documentID: UUID) async throws { if active?.attempt.documentID == documentID { pendingRemovals.insert(documentID); try await cancel(documentID: documentID); return }; pending.removeAll { $0.document.id == documentID }; reservedIDs.remove(documentID); progressContinuations.removeValue(forKey: documentID)?.finish(); try await store.remove(documentID: documentID); await startNextIfNeeded() }
    public func progress(for documentID: UUID) -> AsyncStream<ConversionProgress> { AsyncStream { continuation in progressContinuations[documentID] = continuation; continuation.onTermination = { _ in Task { await self.removeProgress(documentID) } } } }
    public func waitUntilIdle() async { if active == nil && pending.isEmpty && !starting { return }; await withCheckedContinuation { idleWaiters.append($0) } }
    private func removeProgress(_ id: UUID) { progressContinuations.removeValue(forKey: id) }
    private func emit(_ p: ConversionProgress) { progressContinuations[p.attempt.documentID]?.yield(p) }
    private func startNextIfNeeded() async {
        guard active == nil, !starting, let next = pending.first else {
            finishIfIdle()
            return
        }
        starting = true
        pending.removeFirst()
        let attempt = ConversionAttempt(documentID: next.document.id, revision: next.document.revision)
        var record = next.document
        record.status = .converting
        record.attemptID = attempt.id
        record.stage = "Reading PDF"
        record.pagesCompleted = nil
        record.pagesTotal = nil
        record.updatedAt = Date()
        do {
            try await store.upsert(record)
        } catch {
            starting = false
            reservedIDs.remove(next.document.id)
            await startNextIfNeeded()
            return
        }
        emit(ConversionProgress(attempt: attempt, status: .converting, stage: record.stage))

        let task = Task { [engine, store, coordinator = self] in
            let progress: @Sendable (ConversionEngineProgress) -> Void = { update in
                Task { await coordinator.apply(update, to: attempt) }
            }
            do {
                let result = try await engine.convert(input: next.input, attempt: attempt, options: next.options, progress: progress)
                guard !Task.isCancelled,
                      let current = await store.record(for: attempt.documentID),
                      current.attemptID == attempt.id,
                      current.revision == attempt.revision else { return }
                _ = try await store.saveResult(result, for: attempt.documentID, revision: attempt.revision)
                guard var latest = await store.record(for: attempt.documentID),
                      latest.attemptID == attempt.id,
                      latest.revision == attempt.revision else { return }
                latest.status = result.warnings.isEmpty ? .completed : .needsReview
                latest.resultRevision = attempt.revision
                latest.stage = nil
                latest.pagesCompleted = result.pages.count
                latest.pagesTotal = result.pages.isEmpty ? nil : result.pages.count
                latest.updatedAt = Date()
                latest.errorMessage = nil
                try await store.upsert(latest)
                await coordinator.emit(ConversionProgress(attempt: attempt, status: latest.status, pagesCompleted: latest.pagesCompleted, pagesTotal: latest.pagesTotal))
            } catch {
                guard var latest = await store.record(for: attempt.documentID),
                      latest.attemptID == attempt.id,
                      latest.revision == attempt.revision else { return }
                if case DocumentServiceError.cancelled = error {
                    latest.status = .cancelled
                } else if case DocumentServiceError.passwordRequired = error {
                    latest.status = .passwordRequired
                } else if case DocumentServiceError.modelRequired = error {
                    latest.status = .modelRequired
                } else {
                    latest.status = .failed
                }
                latest.stage = nil
                latest.pagesCompleted = nil
                latest.pagesTotal = nil
                latest.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                latest.updatedAt = Date()
                try? await store.upsert(latest)
                await coordinator.emit(ConversionProgress(attempt: attempt, status: latest.status, stage: latest.errorMessage))
            }
        }
        active = (attempt, task)
        starting = false
        Task { await task.value; await finish(attemptID: attempt.id) }
    }

    private func apply(_ update: ConversionEngineProgress, to attempt: ConversionAttempt) async {
        guard active?.attempt.id == attempt.id,
              var record = await store.record(for: attempt.documentID),
              record.attemptID == attempt.id,
              record.revision == attempt.revision,
              ![.completed, .needsReview, .failed, .cancelled, .passwordRequired, .modelRequired].contains(record.status) else { return }
        if record.status == .cancelling, update.status != .cancelling { return }
        record.status = update.status
        record.stage = update.stage
        record.pagesCompleted = update.pagesCompleted
        record.pagesTotal = update.pagesTotal
        record.updatedAt = Date()
        try? await store.upsert(record)
        emit(ConversionProgress(attempt: attempt, status: update.status, stage: update.stage, pagesCompleted: update.pagesCompleted, pagesTotal: update.pagesTotal))
    }
    private func finish(attemptID: UUID) async { guard active?.attempt.id == attemptID else { return }; if let id = active?.attempt.documentID { reservedIDs.remove(id); active = nil; if pendingRemovals.remove(id) != nil { try? await store.remove(documentID: id) } } else { active = nil }; await startNextIfNeeded() }
    private func finishIfIdle() { guard active == nil && pending.isEmpty else { return }; idleWaiters.forEach { $0.resume() }; idleWaiters.removeAll() }
}

import Foundation

nonisolated public struct ConversionOptions: Sendable, Equatable {
    public var pageSelection: [Int]
    public var ocrMode: String
    public var password: String?
    public var modelDirectory: URL?

    public init(pageSelection: [Int] = [], ocrMode: String = "auto", password: String? = nil,
                modelDirectory: URL? = nil) {
        self.pageSelection = pageSelection
        self.ocrMode = ocrMode
        self.password = password
        self.modelDirectory = modelDirectory
    }
}

nonisolated public struct ConversionProgress: Sendable, Equatable {
    public let attempt: ConversionAttempt
    public let status: DocumentStatus
    public let stage: String?
    public let pagesCompleted: Int?
    public let pagesTotal: Int?

    public init(attempt: ConversionAttempt, status: DocumentStatus, stage: String? = nil,
                pagesCompleted: Int? = nil, pagesTotal: Int? = nil) {
        self.attempt = attempt
        self.status = status
        self.stage = stage
        self.pagesCompleted = pagesCompleted
        self.pagesTotal = pagesTotal
    }
}

nonisolated public struct ConversionEngineProgress: Sendable, Equatable {
    public let status: DocumentStatus
    public let stage: String?
    public let pagesCompleted: Int?
    public let pagesTotal: Int?

    public init(status: DocumentStatus, stage: String? = nil, pagesCompleted: Int? = nil,
                pagesTotal: Int? = nil) {
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

public extension ConversionEngine {
    func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions) async throws -> EngineResult {
        try await convert(input: input, attempt: attempt)
    }
}

public extension ConversionEngine {
    func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions,
                 progress: @escaping @Sendable (ConversionEngineProgress) -> Void) async throws -> EngineResult {
        try await convert(input: input, attempt: attempt, options: options)
    }
}

public actor ConversionCoordinator {
    private struct Pending: Sendable {
        let document: DocumentRecord
        let input: URL
        let options: ConversionOptions
    }

    private struct Active: Sendable {
        let attempt: ConversionAttempt
        let task: Task<Void, Never>
    }

    private struct Starting: Sendable {
        let pending: Pending
        let attempt: ConversionAttempt
    }

    private let engine: any ConversionEngine
    private let store: WorkspaceStore
    private let dateProvider: DateProvider

    private var pending: [Pending] = []
    private var active: Active?
    private var starting: Starting?
    private var reservedIDs: Set<UUID> = []
    private var removingIDs: Set<UUID> = []
    private var pendingCancellations: Set<UUID> = []
    private var startingCancellations: Set<UUID> = []

    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var removalWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var removalErrors: [UUID: DocumentServiceError] = [:]
    private var progressContinuations: [UUID: [UUID: AsyncStream<ConversionProgress>.Continuation]] = [:]

    public init(engine: any ConversionEngine, store: WorkspaceStore,
                dateProvider: DateProvider = DateProvider()) {
        self.engine = engine
        self.store = store
        self.dateProvider = dateProvider
    }

    public func enqueue(document: DocumentRecord, stagedInput: URL,
                        options: ConversionOptions = .init()) async throws {
        guard !reservedIDs.contains(document.id), !removingIDs.contains(document.id) else {
            throw DocumentServiceError.conflict
        }
        reservedIDs.insert(document.id)
        startingCancellations.remove(document.id)

        var record = document
        record.status = .queued
        record.attemptID = nil
        record.errorMessage = nil
        record.stage = nil
        record.pagesCompleted = nil
        record.pagesTotal = nil

        do {
            try await store.enqueue(record)
            pending.append(Pending(document: record, input: stagedInput, options: options))
            await startNextIfNeeded()
        } catch {
            reservedIDs.remove(document.id)
            throw error
        }
    }

    public func cancel(documentID: UUID) async throws {
        if let index = pending.firstIndex(where: { $0.document.id == documentID }) {
            let queued = pending.remove(at: index)
            pendingCancellations.insert(documentID)

            do {
                var record = queued.document
                if let current = try await store.record(for: documentID) {
                    record = current
                }
                record.status = .cancelled
                record.attemptID = nil
                record.stage = nil
                record.pagesCompleted = nil
                record.pagesTotal = nil
                record.errorMessage = DocumentServiceError.cancelled.localizedDescription
                record.updatedAt = dateProvider.now()
                try await store.upsert(record)
                pendingCancellations.remove(documentID)
                if removingIDs.contains(documentID) {
                    do {
                        try await store.remove(documentID: documentID)
                    } catch {
                        removalErrors[documentID] = Self.normalized(error)
                    }
                    removingIDs.remove(documentID)
                    reservedIDs.remove(documentID)
                    finishProgress(for: documentID)
                    resumeRemovalWaiters(for: documentID)
                    await startNextIfNeeded()
                    return
                }
                reservedIDs.remove(documentID)
            } catch {
                pendingCancellations.remove(documentID)
                if removingIDs.contains(documentID) {
                    do {
                        try await store.remove(documentID: documentID)
                    } catch {
                        removalErrors[documentID] = Self.normalized(error)
                    }
                    removingIDs.remove(documentID)
                    reservedIDs.remove(documentID)
                    finishProgress(for: documentID)
                    resumeRemovalWaiters(for: documentID)
                    await startNextIfNeeded()
                } else {
                    await restorePendingOrder(including: queued)
                }
                throw error
            }
            finishProgress(for: documentID)
            await startNextIfNeeded()
            return
        }

        if let starting, starting.pending.document.id == documentID {
            startingCancellations.insert(documentID)
            return
        }

        guard let active, active.attempt.documentID == documentID else { return }
        try await requestCancellation(for: active)
    }

    public func moveEarlier(documentID: UUID) async throws {
        guard active?.attempt.documentID != documentID else { return }
        if let index = pending.firstIndex(where: { $0.document.id == documentID }) {
            guard index > 0 else { return }
            try await store.moveEarlier(documentID: documentID)
            await restorePendingOrder()
            return
        }
        guard active == nil,
              starting == nil,
              try await store.record(for: documentID)?.status == .queued else { return }
        try await store.moveEarlier(documentID: documentID)
    }

    private func restorePendingOrder(including restored: Pending? = nil) async {
        var candidates = pending
        if let restored, !candidates.contains(where: { $0.document.id == restored.document.id }) {
            candidates.append(restored)
        }
        guard let records = try? await store.documents() else {
            pending = candidates
            return
        }
        let order = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        pending = candidates.sorted {
            order[$0.document.id, default: Int.max] < order[$1.document.id, default: Int.max]
        }
    }

    public func retry(documentID: UUID, stagedInput: URL,
                      options: ConversionOptions = .init()) async throws {
        guard active?.attempt.documentID != documentID,
              starting?.pending.document.id != documentID,
              !reservedIDs.contains(documentID),
              !removingIDs.contains(documentID) else {
            throw DocumentServiceError.conflict
        }
        guard var old = try await store.record(for: documentID) else {
            throw DocumentServiceError.missingDocument
        }
        let retryable: Set<DocumentStatus> = [
            .completed, .needsReview, .failed, .interrupted, .cancelled,
            .passwordRequired, .modelRequired
        ]
        guard retryable.contains(old.status) else { throw DocumentServiceError.conflict }
        guard old.revision < Int.max else { throw DocumentServiceError.conflict }

        old.revision += 1
        old.status = .queued
        old.attemptID = nil
        old.resultRevision = nil
        old.errorMessage = nil
        old.stage = nil
        old.pagesCompleted = nil
        old.pagesTotal = nil
        old.updatedAt = dateProvider.now()
        try await enqueue(document: old, stagedInput: stagedInput, options: options)
    }

    public func remove(documentID: UUID) async throws {
        if removingIDs.contains(documentID) {
            await waitForRemoval(of: documentID)
            if let error = removalErrors.removeValue(forKey: documentID) { throw error }
            return
        }

        if pendingCancellations.contains(documentID) {
            removingIDs.insert(documentID)
            await waitForRemoval(of: documentID)
            if let error = removalErrors.removeValue(forKey: documentID) { throw error }
            return
        }

        if let active, active.attempt.documentID == documentID {
            removingIDs.insert(documentID)
            await requestCancellationIgnoringErrors(for: active)
            if self.active?.attempt.id == active.attempt.id {
                await waitForRemoval(of: documentID)
            }
            if let error = removalErrors.removeValue(forKey: documentID) { throw error }
            return
        }

        if let starting, starting.pending.document.id == documentID {
            removingIDs.insert(documentID)
            await waitForRemoval(of: documentID)
            if let error = removalErrors.removeValue(forKey: documentID) { throw error }
            return
        }

        removingIDs.insert(documentID)
        pending.removeAll { $0.document.id == documentID }
        do {
            try await store.remove(documentID: documentID)
            removingIDs.remove(documentID)
            reservedIDs.remove(documentID)
            finishProgress(for: documentID)
            await startNextIfNeeded()
            resumeRemovalWaiters(for: documentID)
        } catch {
            removingIDs.remove(documentID)
            reservedIDs.remove(documentID)
            let normalized = Self.normalized(error)
            removalErrors[documentID] = normalized
            resumeRemovalWaiters(for: documentID)
            await startNextIfNeeded()
            throw normalized
        }
    }

    public func progress(for documentID: UUID) -> AsyncStream<ConversionProgress> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            progressContinuations[documentID, default: [:]][token] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @concurrent in
                    await self?.removeProgress(documentID: documentID, token: token)
                }
            }
        }
    }

    public func waitUntilIdle() async {
        guard !isIdle else { return }
        let token = UUID()
        let coordinator = self
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if isIdle || Task.isCancelled {
                    continuation.resume()
                } else {
                    idleWaiters[token] = continuation
                }
            }
        }, onCancel: { @Sendable in
            Task { @concurrent in
                await coordinator.cancelIdleWaiter(token: token)
            }
        })
    }

    private var isIdle: Bool {
        active == nil && starting == nil && pending.isEmpty && reservedIDs.isEmpty
            && removingIDs.isEmpty && pendingCancellations.isEmpty
            && startingCancellations.isEmpty
    }

    private func removeProgress(documentID: UUID, token: UUID) {
        progressContinuations[documentID]?.removeValue(forKey: token)
        if progressContinuations[documentID]?.isEmpty == true {
            progressContinuations.removeValue(forKey: documentID)
        }
    }

    private func emit(_ progress: ConversionProgress) {
        progressContinuations[progress.attempt.documentID]?.values.forEach { continuation in
            continuation.yield(progress)
        }
    }

    private func finishProgress(for documentID: UUID) {
        guard let continuations = progressContinuations.removeValue(forKey: documentID) else { return }
        continuations.values.forEach { $0.finish() }
    }

    private func startNextIfNeeded() async {
        guard active == nil, starting == nil else { return }
        guard let next = pending.first else {
            resumeIdleWaitersIfNeeded()
            return
        }

        pending.removeFirst()
        let attempt = ConversionAttempt(documentID: next.document.id, revision: next.document.revision)
        var record = next.document
        record.status = .converting
        record.attemptID = attempt.id
        record.stage = "Reading PDF"
        record.pagesCompleted = nil
        record.pagesTotal = nil
        record.updatedAt = dateProvider.now()
        starting = Starting(pending: next, attempt: attempt)

        do {
            guard try await store.start(record, attempt: attempt) else {
                await finishStarting(attempt: attempt, documentID: next.document.id)
                return
            }
        } catch {
            await finishStarting(attempt: attempt, documentID: next.document.id, error: Self.normalized(error))
            return
        }

        guard starting?.attempt.id == attempt.id else { return }
        if removingIDs.contains(next.document.id) {
            starting = nil
            startingCancellations.remove(next.document.id)
            await removeStartingDocument(documentID: next.document.id)
            await startNextIfNeeded()
            return
        }
        if startingCancellations.remove(next.document.id) != nil {
            starting = nil
            var cancelled = record
            cancelled.status = .cancelled
            cancelled.attemptID = nil
            cancelled.stage = nil
            cancelled.errorMessage = DocumentServiceError.cancelled.localizedDescription
            cancelled.updatedAt = dateProvider.now()
            do {
                if try await store.update(cancelled, matching: attempt) {
                    emit(ConversionProgress(attempt: attempt, status: .cancelled,
                                             stage: cancelled.errorMessage))
                }
            } catch {
                removalErrors[next.document.id] = Self.normalized(error)
            }
            reservedIDs.remove(next.document.id)
            finishProgress(for: next.document.id)
            await startNextIfNeeded()
            return
        }

        let progressChannel = AsyncStream.makeStream(
            of: ConversionEngineProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let progressConsumer = Task { @concurrent [coordinator = self, stream = progressChannel.stream] in
            for await update in stream {
                await coordinator.apply(update, to: attempt)
            }
        }
        let task = Task { @concurrent [engine, coordinator = self] in
            do {
                let result = try await engine.convert(
                    input: next.input,
                    attempt: attempt,
                    options: next.options,
                    progress: { update in
                        progressChannel.continuation.yield(update)
                    }
                )
                progressChannel.continuation.finish()
                await progressConsumer.value
                try Task.checkCancellation()
                await coordinator.complete(result, for: attempt)
            } catch {
                progressChannel.continuation.finish()
                await progressConsumer.value
                let failure = Task.isCancelled ? DocumentServiceError.cancelled : Self.normalized(error)
                await coordinator.fail(failure, for: attempt, wasCancelled: Task.isCancelled)
            }
        }
        active = Active(attempt: attempt, task: task)
        starting = nil
        emit(ConversionProgress(attempt: attempt, status: .converting, stage: record.stage))

        Task { @concurrent [coordinator = self, task] in
            await task.value
            await coordinator.finish(attemptID: attempt.id)
        }
    }

    private func finishStarting(attempt: ConversionAttempt, documentID: UUID,
                                error: DocumentServiceError? = nil) async {
        guard starting?.attempt.id == attempt.id else { return }
        starting = nil
        startingCancellations.remove(documentID)
        if removingIDs.contains(documentID) {
            await removeStartingDocument(documentID: documentID, error: error)
        } else {
            reservedIDs.remove(documentID)
        }
        await startNextIfNeeded()
    }

    private func removeStartingDocument(documentID: UUID, error: DocumentServiceError? = nil) async {
        var removalError = error
        do {
            try await store.remove(documentID: documentID)
        } catch {
            removalError = Self.normalized(error)
        }
        removingIDs.remove(documentID)
        reservedIDs.remove(documentID)
        finishProgress(for: documentID)
        if let removalError { removalErrors[documentID] = removalError }
        resumeRemovalWaiters(for: documentID)
    }

    private func requestCancellation(for active: Active) async throws {
        var persistenceError: DocumentServiceError?
        do {
            if let current = try await store.record(for: active.attempt.documentID),
               current.attemptID == active.attempt.id,
               current.revision == active.attempt.revision,
               [.preparing, .converting].contains(current.status),
               current.status != .cancelling {
                var cancelling = current
                cancelling.status = .cancelling
                cancelling.resultRevision = nil
                cancelling.stage = "Stopping after the current operation"
                cancelling.updatedAt = dateProvider.now()
                if try await store.update(cancelling, matching: active.attempt) {
                    emit(ConversionProgress(attempt: active.attempt, status: .cancelling,
                                             stage: cancelling.stage))
                }
            }
        } catch {
            persistenceError = Self.normalized(error)
        }

        active.task.cancel()
        await engine.cancel(attemptID: active.attempt.id)
        if let persistenceError { throw persistenceError }
    }

    private func requestCancellationIgnoringErrors(for active: Active) async {
        do {
            try await requestCancellation(for: active)
        } catch {
            // The conversion task is still cancelled and the removal waits for
            // its finish callback before deleting the persisted record.
        }
    }

    private func complete(_ result: EngineResult, for attempt: ConversionAttempt) async {
        guard active?.attempt.id == attempt.id, !removingIDs.contains(attempt.documentID) else { return }
        do {
            let status: DocumentStatus = result.warnings.isEmpty ? .completed : .needsReview
            if try await store.complete(result, for: attempt, status: status,
                                        updatedAt: dateProvider.now()) {
                emit(ConversionProgress(attempt: attempt, status: status,
                                         pagesCompleted: result.pages.count,
                                         pagesTotal: result.pages.isEmpty ? nil : result.pages.count))
            }
        } catch let error as DocumentServiceError {
            guard error != .cancelled, error != .staleAttempt, error != .missingDocument else { return }
            await fail(error, for: attempt, wasCancelled: false)
        } catch {
            await fail(Self.normalized(error), for: attempt, wasCancelled: false)
        }
    }

    private func fail(_ error: DocumentServiceError, for attempt: ConversionAttempt,
                      wasCancelled: Bool) async {
        guard active?.attempt.id == attempt.id else { return }
        do {
            guard var latest = try await store.record(for: attempt.documentID),
                  latest.attemptID == attempt.id,
                  latest.revision == attempt.revision else { return }
            guard ![.completed, .needsReview, .failed, .cancelled, .passwordRequired, .modelRequired]
                .contains(latest.status) || latest.status == .cancelling else { return }

            if wasCancelled || latest.status == .cancelling || error == .cancelled {
                latest.status = .cancelled
                latest.resultRevision = nil
            } else if error == .passwordRequired {
                latest.status = .passwordRequired
            } else if error == .modelRequired {
                latest.status = .modelRequired
            } else {
                latest.status = .failed
            }
            latest.stage = nil
            latest.pagesCompleted = nil
            latest.pagesTotal = nil
            latest.errorMessage = error.errorDescription ?? error.localizedDescription
            latest.updatedAt = dateProvider.now()
            if try await store.update(latest, matching: attempt) {
                emit(ConversionProgress(attempt: attempt, status: latest.status,
                                         stage: latest.errorMessage))
            }
        } catch {
            // A missing or replaced record is already the correct outcome for
            // a stale attempt. The next queue action owns any store failure.
        }
    }

    private func apply(_ update: ConversionEngineProgress, to attempt: ConversionAttempt) async {
        guard active?.attempt.id == attempt.id else { return }
        do {
            guard var record = try await store.record(for: attempt.documentID),
                  record.attemptID == attempt.id,
                  record.revision == attempt.revision,
                  [.preparing, .converting, .cancelling].contains(record.status) else { return }
            guard record.status != .cancelling || update.status == .cancelling else { return }
            guard !(record.status == .converting && update.status == .preparing) else { return }

            record.status = update.status
            record.stage = update.stage
            if let completed = record.pagesCompleted,
               let incoming = update.pagesCompleted,
               incoming < completed {
                record.pagesCompleted = completed
            } else {
                record.pagesCompleted = update.pagesCompleted
            }
            record.pagesTotal = update.pagesTotal ?? record.pagesTotal
            record.updatedAt = dateProvider.now()
            if try await store.update(record, matching: attempt, preservingCancellation: true) {
                emit(ConversionProgress(attempt: attempt, status: record.status, stage: record.stage,
                                         pagesCompleted: record.pagesCompleted,
                                         pagesTotal: record.pagesTotal))
            }
        } catch {
            // Progress is best-effort. Completion and failure still perform a
            // conditional state transition and report their own errors.
        }
    }

    private func finish(attemptID: UUID) async {
        guard let active, active.attempt.id == attemptID else { return }
        let documentID = active.attempt.documentID
        if removingIDs.contains(documentID) {
            var removalError: DocumentServiceError?
            do {
                try await store.remove(documentID: documentID)
            } catch {
                removalError = Self.normalized(error)
            }
            self.active = nil
            removingIDs.remove(documentID)
            reservedIDs.remove(documentID)
            finishProgress(for: documentID)
            if let removalError { removalErrors[documentID] = removalError }
            resumeRemovalWaiters(for: documentID)
        } else {
            self.active = nil
            reservedIDs.remove(documentID)
            finishProgress(for: documentID)
        }
        await startNextIfNeeded()
    }

    private func waitForRemoval(of documentID: UUID) async {
        await withCheckedContinuation { continuation in
            removalWaiters[documentID, default: []].append(continuation)
        }
    }

    private func resumeRemovalWaiters(for documentID: UUID) {
        let waiters = removalWaiters.removeValue(forKey: documentID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func cancelIdleWaiter(token: UUID) {
        idleWaiters.removeValue(forKey: token)?.resume()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isIdle else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    private nonisolated static func normalized(_ error: Error) -> DocumentServiceError {
        if let error = error as? DocumentServiceError { return error }
        if error is CancellationError { return .cancelled }
        return .diskFailure(error.localizedDescription)
    }
}

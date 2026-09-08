import CryptoKit
import Foundation
import XCTest

@testable import Parchley

@MainActor
final class ServiceTests: XCTestCase {
  func testFileAccessStagesPDFWithDigestAndReplacesOldCopy() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("source.PDF")
    let input = Data("%PDF-1.7\nfirst".utf8)
    try input.write(to: source)
    let destination = root.appendingPathComponent("job", isDirectory: true)
    let service = FileAccessService()

    let first = try service.stage(source, documentID: UUID(), directory: destination)
    XCTAssertEqual(first.sourceName, "source")
    XCTAssertEqual(first.byteCount, Int64(input.count))
    XCTAssertEqual(first.url.lastPathComponent, "input.pdf")
    XCTAssertEqual(try Data(contentsOf: first.url), input)
    XCTAssertEqual(first.sha256, digest(for: input))

    let replacement = Data("%PDF-1.7\nreplacement".utf8)
    try replacement.write(to: source)
    let second = try service.stage(source, documentID: first.documentID, directory: destination)
    XCTAssertEqual(try Data(contentsOf: second.url), replacement)
    XCTAssertEqual(second.sha256, digest(for: replacement))
  }

  func testFileAccessRejectsUnsupportedAndInvalidPDFInputs() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("job", isDirectory: true)

    let text = root.appendingPathComponent("notes.txt")
    try Data("not a PDF".utf8).write(to: text)
    XCTAssertThrowsError(
      try FileAccessService().stage(text, documentID: UUID(), directory: destination)
    ) { error in
      guard case DocumentServiceError.unsupportedFile = error else {
        return XCTFail("expected unsupportedFile, got \(error)")
      }
    }

    let fakePDF = root.appendingPathComponent("fake.pdf")
    try Data("plain text".utf8).write(to: fakePDF)
    XCTAssertThrowsError(
      try FileAccessService().stage(fakePDF, documentID: UUID(), directory: destination)
    ) { error in
      guard case DocumentServiceError.invalidPDF = error else {
        return XCTFail("expected invalidPDF, got \(error)")
      }
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("input.pdf").path))
  }

  func testFileAccessEnforcesSizeLimitBeforePublishing() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("large.pdf")
    try Data("%PDF-1.7\n123456".utf8).write(to: source)
    let destination = root.appendingPathComponent("job", isDirectory: true)

    XCTAssertThrowsError(
      try FileAccessService(maximumBytes: 5).stage(
        source, documentID: UUID(), directory: destination)
    ) { error in
      guard case DocumentServiceError.fileTooLarge(let size) = error else {
        return XCTFail("expected fileTooLarge, got \(error)")
      }
      XCTAssertGreaterThan(size, 5)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("input.pdf").path))
  }

  func testExportUsesUnusedSuffixNormalizesLineEndingsAndSupportsOverwrite() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let service = ExportService()
    let item = ExportItem(documentID: UUID(), filename: "report", markdown: "one\r\ntwo\rthree")

    let first = try service.export(item, to: folder)
    let second = try service.export(item, to: folder)
    XCTAssertEqual(first.lastPathComponent, "report.md")
    XCTAssertEqual(second.lastPathComponent, "report.2.md")
    XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one\ntwo\nthree")

    let replacement = ExportItem(documentID: item.documentID, filename: "report", markdown: "new")
    let overwritten = try service.export(replacement, to: folder, overwrite: true)
    XCTAssertEqual(overwritten, first)
    XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "new")
  }

  func testExportRejectsEmptyFilenameAndUnsafeSeparators() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let service = ExportService()

    XCTAssertThrowsError(try service.safeFilename(from: "folder/report")) { error in
      guard case DocumentServiceError.unsafeFilename = error else {
        return XCTFail("expected unsafeFilename, got (error)")
      }
    }
    XCTAssertThrowsError(try service.safeFilename(from: "   ")) { error in
      guard case DocumentServiceError.unsafeFilename = error else {
        return XCTFail("expected unsafeFilename, got \(error)")
      }
    }
  }

  func testWorkspacePersistsDraftResultAndRevisionAcrossRelaunch() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let record = DocumentRecord(sourceName: "draft.pdf", revision: 3)
    let result = EngineResult(markdown: "generated")
    let store = try WorkspaceStore(root: folder)
    try await store.upsert(record)
    try await store.saveResult(result, for: record.id, revision: record.revision)
    try await store.saveDraft("edited", for: record.id, revision: record.revision)

    let reopened = try WorkspaceStore(root: folder)
    let persistedResult = try await reopened.result(for: record.id, revision: 3)
    XCTAssertEqual(persistedResult, result)
    let draft = try await reopened.draft(for: record.id)
    XCTAssertEqual(draft?.markdown, "edited")
    XCTAssertEqual(draft?.revision, 3)
  }

  func testWorkspaceRejectsStaleDraftAndClearsObsoleteResult() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let record = DocumentRecord(sourceName: "revisioned.pdf", status: .completed, revision: 1)
    let store = try WorkspaceStore(root: folder)
    try await store.upsert(record)
    try await store.saveResult(EngineResult(markdown: "generated"), for: record.id, revision: 1)

    do {
      try await store.saveDraft("late edit", for: record.id, revision: 0)
      XCTFail("a draft from an older revision must be rejected")
    } catch {
      XCTAssertEqual(error as? DocumentServiceError, .staleAttempt)
    }

    var retried = record
    retried.status = .queued
    retried.revision = 2
    retried.resultRevision = nil
    try await store.upsert(retried)

    let obsoleteResult = try await store.result(for: record.id, revision: 1)
    XCTAssertNil(obsoleteResult)
  }

  func testWorkspaceClearHistoryRetainsDraftsUntilTheyAreDiscarded() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let kept = DocumentRecord(sourceName: "kept.pdf", status: .completed)
    let removed = DocumentRecord(sourceName: "removed.pdf", status: .needsReview)
    let store = try WorkspaceStore(root: folder)
    try await store.upsert(kept)
    try await store.upsert(removed)
    try await store.saveDraft("keep me", for: kept.id, revision: 0)

    try await store.clearHistory()
    let keptAfterClear = try await store.record(for: kept.id)
    let removedAfterClear = try await store.record(for: removed.id)
    XCTAssertNotNil(keptAfterClear)
    XCTAssertNil(removedAfterClear)

    try await store.discardDraft(for: kept.id)
    try await store.clearHistory()
    let keptAfterDiscard = try await store.record(for: kept.id)
    XCTAssertNil(keptAfterDiscard)
  }

  func testWorkspaceRecoversPreparingAndCancellingDocumentsWithNewTimestamp() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let preparing = DocumentRecord(
      sourceName: "preparing.pdf", status: .preparing, stage: "Reading PDF")
    let cancelling = DocumentRecord(
      sourceName: "cancelling.pdf", status: .cancelling, stage: "Stopping")
    let oldDate = Date(timeIntervalSince1970: 100)
    let recoveryDate = Date(timeIntervalSince1970: 200)
    let metadata = WorkspaceMetadata(
      documents: [preparing, cancelling],
      lastSavedAt: oldDate,
      schemaVersion: 2
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(metadata).write(to: folder.appendingPathComponent("workspace.json"))

    let reopened = try WorkspaceStore(root: folder, dateProvider: DateProvider { recoveryDate })
    let records = try await reopened.documents()
    XCTAssertEqual(records.map(\.status), [.interrupted, .interrupted])
    XCTAssertTrue(
      records.allSatisfy { $0.errorMessage == "Conversion was interrupted. Retry to continue." })
    XCTAssertTrue(records.allSatisfy { $0.updatedAt == recoveryDate })
    XCTAssertTrue(records.allSatisfy { $0.stage == nil && $0.attemptID == nil })
  }

  func testCoordinatorEmitsProgressAndWarningsRequireReview() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = TestConversionEngine(warnings: ["Check page 2"], delay: .milliseconds(20))
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let record = DocumentRecord(sourceName: "warnings.pdf")
    let stream = await coordinator.progress(for: record.id)
    let updatesTask = Task { () -> [ConversionProgress] in
      var updates: [ConversionProgress] = []
      for await update in stream {
        updates.append(update)
        if update.status == .needsReview { break }
      }
      return updates
    }

    try await coordinator.enqueue(
      document: record, stagedInput: URL(fileURLWithPath: "/tmp/warnings.pdf"))
    await coordinator.waitUntilIdle()
    let updates = await updatesTask.value
    let finished = try await store.record(for: record.id)

    XCTAssertTrue(updates.contains { $0.stage == "Reading PDF" })
    XCTAssertEqual(updates.last?.status, .needsReview)
    XCTAssertEqual(finished?.status, .needsReview)
    XCTAssertEqual(finished?.pagesCompleted, 2)
    XCTAssertEqual(finished?.pagesTotal, 2)
  }

  func testCoordinatorMovesPendingWorkEarlierAndKeepsOneActiveConversion() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = TestConversionEngine(delay: .milliseconds(80))
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let first = DocumentRecord(sourceName: "one.pdf")
    let second = DocumentRecord(sourceName: "two.pdf")
    let third = DocumentRecord(sourceName: "three.pdf")

    try await coordinator.enqueue(
      document: first, stagedInput: URL(fileURLWithPath: "/tmp/one.pdf"))
    try await coordinator.enqueue(
      document: second, stagedInput: URL(fileURLWithPath: "/tmp/two.pdf"))
    try await coordinator.enqueue(
      document: third, stagedInput: URL(fileURLWithPath: "/tmp/three.pdf"))
    try await coordinator.moveEarlier(documentID: third.id)
    await coordinator.waitUntilIdle()

    let startedInputs = await engine.startedInputs
    let maximumConcurrent = await engine.maximumConcurrent
    let documents = try await store.documents()
    XCTAssertEqual(startedInputs, ["one.pdf", "three.pdf", "two.pdf"])
    XCTAssertEqual(maximumConcurrent, 1)
    XCTAssertEqual(documents.map(\.sourceName), ["one.pdf", "three.pdf", "two.pdf"])
  }

  func testCoordinatorCancelsActiveConversionAndPersistsCancelledState() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = BlockingConversionEngine()
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let record = DocumentRecord(sourceName: "cancel.pdf")

    try await coordinator.enqueue(
      document: record, stagedInput: URL(fileURLWithPath: "/tmp/cancel.pdf"))
    await engine.waitForStart()
    try await coordinator.cancel(documentID: record.id)
    await coordinator.waitUntilIdle()

    let cancelled = try await store.record(for: record.id)
    let cancelledCount = await engine.cancelledCount
    XCTAssertEqual(cancelled?.status, .cancelled)
    XCTAssertEqual(cancelled?.errorMessage, DocumentServiceError.cancelled.localizedDescription)
    XCTAssertEqual(cancelledCount, 1)
  }

  func testCoordinatorRetryCreatesNewRevisionAfterFailure() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = RetryConversionEngine()
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let record = DocumentRecord(
      sourceName: "retry.pdf", status: .failed, revision: 4, errorMessage: "temporary")
    try await store.upsert(record)

    try await coordinator.retry(
      documentID: record.id, stagedInput: URL(fileURLWithPath: "/tmp/retry.pdf"))
    await coordinator.waitUntilIdle()
    let failed = try await store.record(for: record.id)
    XCTAssertEqual(failed?.status, .failed)
    XCTAssertEqual(failed?.revision, 5)

    try await coordinator.retry(
      documentID: record.id, stagedInput: URL(fileURLWithPath: "/tmp/retry.pdf"))
    await coordinator.waitUntilIdle()
    let retried = try await store.record(for: record.id)
    let attempts = await engine.attempts
    XCTAssertEqual(retried?.status, .completed)
    XCTAssertEqual(retried?.revision, 6)
    XCTAssertEqual(retried?.resultRevision, 6)
    XCTAssertEqual(attempts, 2)
  }

  func testConcurrentDuplicateAdmissionAllowsOnlyOneJob() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = TestConversionEngine()
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let record = DocumentRecord(sourceName: "same.pdf")
    var successes = 0

    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<2 {
        group.addTask {
          (try? await coordinator.enqueue(
            document: record,
            stagedInput: URL(fileURLWithPath: "/tmp/same.pdf")
          )) != nil
        }
      }
      for await success in group where success {
        successes += 1
      }
    }

    await coordinator.waitUntilIdle()
    let maximumConcurrent = await engine.maximumConcurrent
    XCTAssertEqual(successes, 1)
    XCTAssertEqual(maximumConcurrent, 1)
  }

  func testCoordinatorUsesStableQueueOrderAndMovesEarlierPersistedWork() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = ControlledConversionEngine()
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let first = DocumentRecord(sourceName: "one.pdf")
    let second = DocumentRecord(sourceName: "two.pdf")
    let third = DocumentRecord(sourceName: "three.pdf")

    try await coordinator.enqueue(
      document: first, stagedInput: URL(fileURLWithPath: "/tmp/one.pdf"))
    await engine.waitForStart("one.pdf")
    try await coordinator.enqueue(
      document: second, stagedInput: URL(fileURLWithPath: "/tmp/two.pdf"))
    try await coordinator.enqueue(
      document: third, stagedInput: URL(fileURLWithPath: "/tmp/three.pdf"))
    try await coordinator.moveEarlier(documentID: third.id)

    await engine.complete("one.pdf")
    await engine.waitForStart("three.pdf")
    await engine.complete("three.pdf")
    await engine.waitForStart("two.pdf")
    await engine.complete("two.pdf")
    await coordinator.waitUntilIdle()

    let startedInputs = await engine.startedInputs
    let documents = try await store.documents()
    XCTAssertEqual(startedInputs, ["one.pdf", "three.pdf", "two.pdf"])
    XCTAssertEqual(documents.map(\.sourceName), ["one.pdf", "three.pdf", "two.pdf"])
  }

  func testCoordinatorRetriesAtQueueTailWithAFreshRevision() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = ControlledConversionEngine()
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let retryable = DocumentRecord(sourceName: "retry.pdf", status: .failed)
    let waiting = DocumentRecord(sourceName: "waiting.pdf")
    try await store.upsert(retryable)

    try await coordinator.retry(
      documentID: retryable.id, stagedInput: URL(fileURLWithPath: "/tmp/retry.pdf"))
    await engine.waitForStart("retry.pdf")
    try await coordinator.enqueue(
      document: waiting, stagedInput: URL(fileURLWithPath: "/tmp/waiting.pdf"))

    await engine.complete("retry.pdf", outcome: .failure)
    await engine.waitForStart("waiting.pdf")
    try await coordinator.retry(
      documentID: retryable.id, stagedInput: URL(fileURLWithPath: "/tmp/retry.pdf"))
    await engine.complete("waiting.pdf")
    await engine.waitForStart("retry.pdf", occurrence: 2)
    await engine.complete("retry.pdf")
    await coordinator.waitUntilIdle()

    let result = try await store.record(for: retryable.id)
    let startedInputs = await engine.startedInputs
    XCTAssertEqual(startedInputs, ["retry.pdf", "waiting.pdf", "retry.pdf"])
    XCTAssertEqual(result?.status, .completed)
    XCTAssertEqual(result?.revision, 2)
    XCTAssertEqual(result?.resultRevision, 2)
  }

  func testCoordinatorIgnoresLateSuccessAfterCancellation() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = ControlledConversionEngine()
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let record = DocumentRecord(sourceName: "cancel-late.pdf")

    try await coordinator.enqueue(
      document: record, stagedInput: URL(fileURLWithPath: "/tmp/cancel-late.pdf"))
    await engine.waitForStart("cancel-late.pdf")
    try await coordinator.cancel(documentID: record.id)
    await engine.complete("cancel-late.pdf")
    await coordinator.waitUntilIdle()

    let cancelled = try await store.record(for: record.id)
    XCTAssertEqual(cancelled?.status, .cancelled)
    let result = try await store.result(for: record.id, revision: 0)
    XCTAssertNil(result)
  }

  func testRemovingActiveDocumentWaitsForEngineAndCannotBeResurrected() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = ControlledConversionEngine()
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let record = DocumentRecord(sourceName: "remove-race.pdf")

    try await coordinator.enqueue(
      document: record, stagedInput: URL(fileURLWithPath: "/tmp/remove-race.pdf"))
    await engine.waitForStart("remove-race.pdf")
    let removal = Task { try await coordinator.remove(documentID: record.id) }
    await engine.waitForCancellation()
    let recordBeforeRemoval = try await store.record(for: record.id)
    XCTAssertNotNil(recordBeforeRemoval)

    await engine.complete("remove-race.pdf")
    do {
      try await removal.value
    } catch {
      XCTFail("removal should complete after the engine stops: \(error)")
    }
    let recordAfterRemoval = try await store.record(for: record.id)
    XCTAssertNil(recordAfterRemoval)
  }

  func testIdleWaiterStaysPendingUntilConversionFinishes() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let engine = ControlledConversionEngine()
    let coordinator = ConversionCoordinator(engine: engine, store: store)
    let marker = AsyncMarker()
    let record = DocumentRecord(sourceName: "idle.pdf")

    try await coordinator.enqueue(
      document: record, stagedInput: URL(fileURLWithPath: "/tmp/idle.pdf"))
    await engine.waitForStart("idle.pdf")
    let waiter = Task {
      await coordinator.waitUntilIdle()
      await marker.mark()
    }
    await Task.yield()
    let markedBeforeCompletion = await marker.isMarked
    XCTAssertFalse(markedBeforeCompletion)

    await engine.complete("idle.pdf")
    await waiter.value
    let markedAfterCompletion = await marker.isMarked
    XCTAssertTrue(markedAfterCompletion)
  }

  func testStaleAttemptCannotPersistAResult() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try WorkspaceStore(root: folder)
    let documentID = UUID()
    let current = ConversionAttempt(documentID: documentID, revision: 1)
    let stale = ConversionAttempt(documentID: documentID, revision: 1)
    try await store.upsert(
      DocumentRecord(
        id: documentID,
        sourceName: "stale.pdf",
        status: .converting,
        attemptID: current.id,
        revision: current.revision
      ))

    do {
      try await store.saveResult(EngineResult(markdown: "late"), for: stale)
      XCTFail("a result from another attempt must be rejected")
    } catch {
      XCTAssertEqual(error as? DocumentServiceError, .staleAttempt)
    }
    let result = try await store.result(for: documentID, revision: 1)
    XCTAssertNil(result)
  }

  func testOCRManifestRejectsUnsafeArtifactNames() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = try XCTUnwrap(URL(string: "https://models.test/model.bin"))
    let manifest = ModelManifest(
      revision: "r1",
      artifacts: [
        ModelArtifact(
          name: "../model.bin",
          url: url,
          byteCount: 1,
          sha256: String(repeating: "0", count: 64)
        )
      ]
    )
    let manager = try OCRModelManager(root: folder.appendingPathComponent("Models"))

    let discovered = await manager.discover(manifest)
    let state = await manager.state
    XCTAssertNil(discovered)
    if case .failed(let message) = state {
      XCTAssertTrue(message.contains("invalid"))
    } else {
      XCTFail("invalid manifest should put the manager in a failed state")
    }
    do {
      _ = try await manager.install(manifest)
      XCTFail("invalid manifest must fail")
    } catch {
      guard case DocumentServiceError.modelDownloadFailed(let message) = error else {
        return XCTFail("expected modelDownloadFailed, got \(error)")
      }
      XCTAssertTrue(message.contains("invalid"))
    }
  }

  func testOCRInstallRetriesTransientHTTPFailureAndPublishesVerifiedModel() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    RetryURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RetryURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let url = try XCTUnwrap(URL(string: "https://models.test/model.bin"))
    let manifest = ModelManifest(
      revision: "r2",
      artifacts: [
        ModelArtifact(
          name: "model.bin",
          url: url,
          byteCount: 5,
          sha256: digest(for: Data("short".utf8))
        )
      ]
    )
    let manager = try OCRModelManager(root: folder.appendingPathComponent("Models"))

    let installed = try await manager.install(manifest, session: session)
    let state = await manager.state
    XCTAssertEqual(RetryURLProtocol.attempts, 2)
    XCTAssertEqual(state, .ready(installed))
    XCTAssertEqual(
      try Data(contentsOf: installed.appendingPathComponent("model.bin")), Data("short".utf8))
  }

  func testOCRManagerUsesVerifiedBundledModelWithoutInstalling() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let bundled = folder.appendingPathComponent("BundleResources")
    try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    let bytes = Data("model".utf8)
    try bytes.write(to: bundled.appendingPathComponent("model.bin"))
    try Data("unrelated resource".utf8).write(to: bundled.appendingPathComponent("other.txt"))
    let url = try XCTUnwrap(URL(string: "https://models.test/model.bin"))
    let manifest = ModelManifest(
      revision: "bundled-r1",
      artifacts: [
        ModelArtifact(
          name: "model.bin",
          url: url,
          byteCount: Int64(bytes.count),
          sha256: digest(for: bytes)
        )
      ]
    )
    let manager = try OCRModelManager(
      root: folder.appendingPathComponent("Models"),
      bundledRoot: bundled
    )

    let discovered = await manager.discover(manifest)
    let state = await manager.state
    let leased = try await manager.acquireLease()
    let standardizedBundle = bundled.standardizedFileURL
    XCTAssertEqual(discovered, standardizedBundle)
    XCTAssertEqual(state, .bundled(standardizedBundle))
    XCTAssertEqual(leased, standardizedBundle)
    await manager.releaseLease()
  }

  func testTruncatedOCRArtifactDoesNotPublishAReadyDirectory() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let url = try XCTUnwrap(URL(string: "https://models.test/model.bin"))
    let manifest = ModelManifest(
      revision: "r3",
      artifacts: [
        ModelArtifact(
          name: "model.bin",
          url: url,
          byteCount: 100,
          sha256: String(repeating: "0", count: 64)
        )
      ]
    )
    let manager = try OCRModelManager(root: folder.appendingPathComponent("Models"))

    do {
      _ = try await manager.install(manifest, session: session)
      XCTFail("truncated model must fail")
    } catch {
      guard case DocumentServiceError.hashMismatch = error else {
        return XCTFail("expected hashMismatch, got \(error)")
      }
    }
    let state = await manager.state
    if case .ready = state {
      XCTFail("failed install must not become ready")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("Models/r3").path))
  }

  private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func digest(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private actor TestConversionEngine: ConversionEngine {
  private let warnings: [String]
  private let delay: Duration
  private(set) var active = 0
  private(set) var maximumConcurrent = 0
  private(set) var startedInputs: [String] = []

  init(warnings: [String] = [], delay: Duration = .milliseconds(40)) {
    self.warnings = warnings
    self.delay = delay
  }

  func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult {
    try await convert(input: input, attempt: attempt, options: .init(), progress: { _ in })
  }

  func convert(
    input: URL,
    attempt: ConversionAttempt,
    options: ConversionOptions,
    progress: @escaping @Sendable (ConversionEngineProgress) -> Void
  ) async throws -> EngineResult {
    active += 1
    maximumConcurrent = max(maximumConcurrent, active)
    startedInputs.append(input.lastPathComponent)
    defer { active -= 1 }

    progress(
      ConversionEngineProgress(
        status: .converting,
        stage: "Reading PDF",
        pagesCompleted: 0,
        pagesTotal: 2
      )
    )
    try await Task.sleep(for: delay)
    progress(
      ConversionEngineProgress(
        status: .converting,
        stage: "Writing result",
        pagesCompleted: 2,
        pagesTotal: 2
      )
    )
    return EngineResult(
      markdown: input.lastPathComponent,
      warnings: warnings,
      pages: [
        EnginePageMetadata(pageNumber: 1, method: "native"),
        EnginePageMetadata(pageNumber: 2, method: "native"),
      ]
    )
  }

  func cancel(attemptID: UUID) async {}
}

private actor AsyncMarker {
  private var marked = false

  var isMarked: Bool { marked }

  func mark() {
    marked = true
  }
}

private actor ControlledConversionEngine: ConversionEngine {
  enum Outcome: Sendable {
    case success
    case failure
  }

  private var starts: [String] = []
  private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var completionWaiters: [String: [CheckedContinuation<Outcome, Never>]] = [:]
  private var pendingOutcomes: [String: [Outcome]] = [:]
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancellationRequested = false

  var startedInputs: [String] { starts }

  func waitForStart(_ name: String, occurrence: Int = 1) async {
    guard starts.filter({ $0 == name }).count < occurrence else { return }
    await withCheckedContinuation { continuation in
      startWaiters[name, default: []].append(continuation)
    }
  }

  func complete(_ name: String, outcome: Outcome = .success) {
    if let continuation = completionWaiters[name]?.removeFirst() {
      continuation.resume(returning: outcome)
    } else {
      pendingOutcomes[name, default: []].append(outcome)
    }
  }

  func waitForCancellation() async {
    if cancellationRequested { return }
    await withCheckedContinuation { continuation in
      cancellationWaiters.append(continuation)
    }
  }

  func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult {
    try await convert(input: input, attempt: attempt, options: .init(), progress: { _ in })
  }

  func convert(
    input: URL,
    attempt: ConversionAttempt,
    options: ConversionOptions,
    progress: @escaping @Sendable (ConversionEngineProgress) -> Void
  ) async throws -> EngineResult {
    let name = input.lastPathComponent
    starts.append(name)
    let waiters = startWaiters.removeValue(forKey: name) ?? []
    for waiter in waiters {
      waiter.resume()
    }
    progress(ConversionEngineProgress(status: .converting, stage: "Reading PDF"))

    let outcome: Outcome
    if let pending = pendingOutcomes[name], !pending.isEmpty {
      outcome = pendingOutcomes[name]!.removeFirst()
    } else {
      outcome = await withCheckedContinuation { continuation in
        completionWaiters[name, default: []].append(continuation)
      }
    }
    switch outcome {
    case .success:
      return EngineResult(markdown: name)
    case .failure:
      throw DocumentServiceError.unavailable
    }
  }

  func cancel(attemptID: UUID) async {
    cancellationRequested = true
    let waiters = cancellationWaiters
    cancellationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor BlockingConversionEngine: ConversionEngine {
  private var started = false
  private var cancelRequested = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var cancelledCount = 0

  func waitForStart() async {
    if started {
      return
    }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult {
    try await convert(input: input, attempt: attempt, options: .init(), progress: { _ in })
  }

  func convert(
    input: URL,
    attempt: ConversionAttempt,
    options: ConversionOptions,
    progress: @escaping @Sendable (ConversionEngineProgress) -> Void
  ) async throws -> EngineResult {
    started = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()
    progress(ConversionEngineProgress(status: .converting, stage: "Reading PDF"))
    while !cancelRequested {
      try await Task.sleep(for: .milliseconds(10))
    }
    throw DocumentServiceError.cancelled
  }

  func cancel(attemptID: UUID) async {
    cancelRequested = true
    cancelledCount += 1
  }
}

private actor RetryConversionEngine: ConversionEngine {
  private var shouldFail = true
  private(set) var attempts = 0

  func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult {
    try await convert(input: input, attempt: attempt, options: .init(), progress: { _ in })
  }

  func convert(
    input: URL,
    attempt: ConversionAttempt,
    options: ConversionOptions,
    progress: @escaping @Sendable (ConversionEngineProgress) -> Void
  ) async throws -> EngineResult {
    attempts += 1
    if shouldFail {
      shouldFail = false
      throw DocumentServiceError.unavailable
    }
    return EngineResult(markdown: "retry succeeded")
  }

  func cancel(attemptID: UUID) async {}
}

private final class RetryURLProtocolState: @unchecked Sendable {
  let lock = NSLock()
  private var value = 0

  func reset() {
    lock.lock()
    value = 0
    lock.unlock()
  }

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class RetryURLProtocol: URLProtocol, @unchecked Sendable {
  private static let state = RetryURLProtocolState()
  static var attempts: Int { state.count }

  static func reset() {
    state.reset()
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: Self.state.next() == 1 ? 500 : 200,
        httpVersion: nil,
        headerFields: nil
      )
    else {
      self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    guard let client else { return }
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client.urlProtocol(self, didLoad: Data("short".utf8))
    client.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  static let responseData = Data("short".utf8)

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.responseData)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

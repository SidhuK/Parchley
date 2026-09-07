import XCTest
@testable import Parchley

@MainActor
final class ServiceTests: XCTestCase {
    func testExportUsesUnusedSuffixAndNormalizesLineEndings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = ExportItem(documentID: UUID(), filename: "report", markdown: "one\r\ntwo\rthree")
        let first = try ExportService().export(item, to: folder)
        let second = try ExportService().export(item, to: folder)
        XCTAssertEqual(first.lastPathComponent, "report.md"); XCTAssertEqual(second.lastPathComponent, "report.2.md")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one\ntwo\nthree")
    }

    func testWorkspaceFirstWriteAndDraftRevisionSurviveRelaunch() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let record = DocumentRecord(sourceName: "draft.pdf")
        let store = try WorkspaceStore(root: folder); try await store.upsert(record); try await store.saveDraft("edited", for: record.id, revision: 3)
        let reopened = try WorkspaceStore(root: folder)
        let draft = try await reopened.draft(for: record.id)
        XCTAssertEqual(draft?.markdown, "edited"); XCTAssertEqual(draft?.revision, 3)
    }

    func testWorkspaceFallsBackToLastGoodMetadataAndRecoversActive() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let record = DocumentRecord(sourceName: "scan.pdf", status: .converting)
        let store = try WorkspaceStore(root: folder); try await store.upsert(record)
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent("workspace.json"))
        let reopened = try WorkspaceStore(root: folder)
        let recovered = await reopened.record(for: record.id)
        XCTAssertEqual(recovered?.status, .interrupted)
        XCTAssertNil(recovered?.attemptID)
        XCTAssertNil(recovered?.stage)
        XCTAssertNil(recovered?.pagesCompleted)
        XCTAssertEqual(recovered?.errorMessage, "Conversion was interrupted. Retry to continue.")
    }

    func testCoordinatorPersistsFinalPageProgressAfterNativeUpdates() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WorkspaceStore(root: folder)
        let engine = TestConversionEngine()
        let coordinator = ConversionCoordinator(engine: engine, store: store)
        let record = DocumentRecord(sourceName: "progress.pdf")

        try await coordinator.enqueue(document: record, stagedInput: URL(fileURLWithPath: "/tmp/progress.pdf"))
        await coordinator.waitUntilIdle()

        let finished = await store.record(for: record.id)
        XCTAssertEqual(finished?.status, .completed)
        XCTAssertEqual(finished?.stage, nil)
        XCTAssertEqual(finished?.pagesCompleted, 2)
        XCTAssertEqual(finished?.pagesTotal, 2)
    }

    func testCoordinatorCancelsQueuedAndConvertsRemainingSequentially() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WorkspaceStore(root: folder); let engine = TestConversionEngine(); let coordinator = ConversionCoordinator(engine: engine, store: store)
        let first = DocumentRecord(sourceName: "one.pdf"), second = DocumentRecord(sourceName: "two.pdf")
        try await coordinator.enqueue(document: first, stagedInput: URL(fileURLWithPath: "/tmp/one.pdf"))
        try await coordinator.enqueue(document: second, stagedInput: URL(fileURLWithPath: "/tmp/two.pdf"))
        try await coordinator.cancel(documentID: second.id); await coordinator.waitUntilIdle()
        let firstResult = await store.record(for: first.id), secondResult = await store.record(for: second.id)
        XCTAssertEqual(firstResult?.status, .completed); XCTAssertEqual(secondResult?.status, .cancelled)
        let maximumConcurrent = await engine.maximumConcurrent
        XCTAssertEqual(maximumConcurrent, 1)
    }

    func testModelRejectsTruncatedArtifactAndDoesNotPublish() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = URL(string: "http://models.test/model.bin")!
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let manifest = ModelManifest(revision: "r1", artifacts: [ModelArtifact(name: "model.bin", url: url, byteCount: 100, sha256: String(repeating: "0", count: 64))])
        let manager = try OCRModelManager(root: folder.appendingPathComponent("Models"))
        do { _ = try await manager.install(manifest, session: session); XCTFail("truncated model must fail") } catch { guard case DocumentServiceError.hashMismatch = error else { return XCTFail("expected hashMismatch, got \(error)") } }
        if case .ready = await manager.state { XCTFail("failed install must not become ready") }
    }

    func testModelInstallPublishesVerifiedDirectoryAndCanBeDiscovered() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let manifest = ModelManifest(revision: "r2", artifacts: [ModelArtifact(name: "model.bin", url: URL(string: "http://models.test/model.bin")!, byteCount: 5, sha256: "f9b0078b5df596d2ea19010c001bbd009e651de2c57e8fb7e355f31eb9d3f739")])
        let manager = try OCRModelManager(root: folder.appendingPathComponent("Models"))
        let installed = try await manager.install(manifest, session: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("model.bin").path))
        let found = await manager.discover(manifest)
        let rediscovered = try XCTUnwrap(found)
        XCTAssertEqual(rediscovered.path, installed.path)
    }

    func testConcurrentDuplicateAdmissionAllowsOnlyOneJob() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WorkspaceStore(root: folder), engine = TestConversionEngine(), coordinator = ConversionCoordinator(engine: engine, store: store)
        let record = DocumentRecord(sourceName: "same.pdf")
        var successes = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask { (try? await coordinator.enqueue(document: record, stagedInput: URL(fileURLWithPath: "/tmp/same.pdf"))) != nil } }
            for await success in group { if success { successes += 1 } }
        }
        await coordinator.waitUntilIdle(); XCTAssertEqual(successes, 1); let maximumConcurrent = await engine.maximumConcurrent; XCTAssertEqual(maximumConcurrent, 1)
    }

    private func temporaryFolder() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
}

private actor TestConversionEngine: ConversionEngine {
    var active = 0; private(set) var maximumConcurrent = 0
    func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult { active += 1; maximumConcurrent = max(maximumConcurrent, active); defer { active -= 1 }; try await Task.sleep(for: .milliseconds(40)); return EngineResult(markdown: input.lastPathComponent) }
    func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions, progress: @escaping @Sendable (ConversionEngineProgress) -> Void) async throws -> EngineResult {
        active += 1; maximumConcurrent = max(maximumConcurrent, active); defer { active -= 1 }
        progress(ConversionEngineProgress(status: .converting, stage: "Reading PDF", pagesCompleted: 0, pagesTotal: 2))
        try await Task.sleep(for: .milliseconds(40))
        progress(ConversionEngineProgress(status: .converting, stage: "Writing result", pagesCompleted: 2, pagesTotal: 2))
        return EngineResult(markdown: input.lastPathComponent,
                            pages: [EnginePageMetadata(pageNumber: 1, method: "native"), EnginePageMetadata(pageNumber: 2, method: "native")])
    }
    func cancel(attemptID: UUID) async {}
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let responseData = Data("short".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!; client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Self.responseData); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() {}
}

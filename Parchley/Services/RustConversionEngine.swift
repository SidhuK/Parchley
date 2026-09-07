import Foundation
import ParchleyDomain
import ParchleyEngine

/// Adapts the typed Rust bridge to the app's queue service.
/// Rust owns parsing and writes the result files. Swift only reads the finished
/// files after the bridge reports a terminal snapshot.
public struct RustConversionEngine: ConversionEngine, Sendable {
    private let engine: RustEngine
    private let poller: SnapshotPoller
    private let handles: HandleRegistry

    public init(engine: RustEngine, poller: SnapshotPoller = SnapshotPoller()) {
        self.engine = engine
        self.poller = poller
        self.handles = HandleRegistry()
    }

    public func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult {
        try await convert(input: input, attempt: attempt, options: ConversionOptions())
    }

    public func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions) async throws -> EngineResult {
        try await convert(input: input, attempt: attempt, options: options, progress: { _ in })
    }

    public func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions,
                        progress: @escaping @Sendable (ConversionEngineProgress) -> Void) async throws -> EngineResult {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParchleyJobs", isDirectory: true)
            .appendingPathComponent(attempt.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let pages: PageSelection
        do { pages = try PageSelection(pages: options.pageSelection) } catch { throw DocumentServiceError.diskFailure("The selected pages are invalid.") }
        let mode = OCRMode(rawValue: options.ocrMode.lowercased()) ?? .auto
        let request = try JobRequest(documentID: DocumentID(attempt.documentID), attemptID: AttemptID(attempt.id),
                                     stagedInputPath: input, outputDirectory: output, pageSelection: pages,
                                     ocrMode: mode, modelDirectory: options.modelDirectory, password: options.password)
        let handle = try engine.start(request)
        await handles.insert(handle, for: attempt.id)
        defer { Task { await handles.remove(attempt.id) } }
        return try await withTaskCancellationHandler(operation: {
            let terminal = try await poller.waitForTerminal(handle) { snapshot in
                progress(ConversionEngineProgress(status: Self.documentStatus(for: snapshot.state),
                                                   stage: snapshot.stage.map(Self.stageLabel),
                                                   pagesCompleted: snapshot.pagesCompleted,
                                                   pagesTotal: snapshot.pagesTotal))
            }
            if case .failed = terminal.state { throw appError(terminal.failure) }
            if case .cancelled = terminal.state { throw DocumentServiceError.cancelled }
            let descriptor = try handle.resultDescriptor()
            let markdown = try String(contentsOf: descriptor.markdownURL, encoding: .utf8)
            let manifest = try Manifest(contentsOf: descriptor.manifestURL)
            return EngineResult(markdown: markdown, warnings: manifest.warnings,
                                engineVersion: manifest.engineVersion, modelVersion: manifest.modelVersion,
                                pages: manifest.pages.map { EnginePageMetadata(pageNumber: $0.pageNumber, method: $0.method, warning: $0.warning) })
        }, onCancel: {
            handle.requestCancel()
        })
    }

    public func cancel(attemptID: UUID) async {
        await handles.cancel(attemptID)
    }

    private func appError(_ failure: JobFailure?) -> Error {
        switch failure?.code {
        case .inputUnavailable: return DocumentServiceError.unavailable
        case .invalidPDF: return DocumentServiceError.invalidPDF
        case .passwordRequired: return DocumentServiceError.passwordRequired
        case .incorrectPassword: return DocumentServiceError.incorrectPassword
        case .modelRequired, .modelUnavailable: return DocumentServiceError.modelRequired
        case .cancelled: return DocumentServiceError.cancelled
        default: return DocumentServiceError.diskFailure(failure?.message ?? "Conversion failed.")
        }
    }

    nonisolated private static func documentStatus(for state: JobState) -> DocumentStatus {
        switch state {
        case .queued: .preparing
        case .preparing: .preparing
        case .converting: .converting
        case .cancelling: .cancelling
        case .completed: .completed
        case .needsReview: .needsReview
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    nonisolated private static func stageLabel(_ stage: JobStage) -> String {
        switch stage {
        case .readingPDF: "Reading PDF"
        case .recognizingScannedPages: "Recognizing scanned pages"
        case .writingResult: "Writing result"
        }
    }
}

private actor HandleRegistry {
    private var values: [UUID: JobHandle] = [:]
    func insert(_ handle: JobHandle, for id: UUID) { values[id] = handle }
    func remove(_ id: UUID) { values.removeValue(forKey: id) }
    func cancel(_ id: UUID) { values[id]?.requestCancel() }
}

private struct Manifest: Decodable {
    let engineVersion: String
    let modelVersion: String?
    let warnings: [String]
    let pages: [Page]
    enum CodingKeys: String, CodingKey {
        case engineVersion = "engine_version"
        case modelVersion = "model_version"
        case warnings, pages
    }
    struct Page: Decodable { let pageNumber: Int; let method: String; let warning: String?; enum CodingKeys: String, CodingKey { case pageNumber = "page_number", method, warning } }
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

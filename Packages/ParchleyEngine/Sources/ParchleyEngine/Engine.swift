import Foundation
import ParchleyDomain
#if canImport(Darwin)
import Darwin
#endif

public protocol EngineJobHandleBackend: AnyObject, Sendable {
    func snapshot() throws -> JobSnapshot
    func requestCancel()
    func resultDescriptor() throws -> ResultDescriptor
}

public protocol EngineBackend: Sendable {
    func start(_ request: JobRequest) throws -> any EngineJobHandleBackend
    func releaseJob(attemptID: AttemptID)
    func shutdownRequest()
}

public struct JobHandle: Sendable {
    private let backend: any EngineJobHandleBackend
    public let attemptID: AttemptID

    init(attemptID: AttemptID, backend: any EngineJobHandleBackend) {
        self.attemptID = attemptID
        self.backend = backend
    }

    public func snapshot() throws -> JobSnapshot { try backend.snapshot() }
    public func requestCancel() { backend.requestCancel() }
    public func resultDescriptor() throws -> ResultDescriptor { try backend.resultDescriptor() }
}

public protocol ParchleyEngine: Sendable {
    func start(_ request: JobRequest) throws -> JobHandle
    func releaseJob(attemptID: AttemptID)
    func shutdownRequest()
}

public struct EngineAdapter: ParchleyEngine, Sendable {
    private let backend: any EngineBackend

    public init(backend: any EngineBackend) { self.backend = backend }

    public func start(_ request: JobRequest) throws -> JobHandle {
        let handle = try backend.start(request)
        return JobHandle(attemptID: request.attemptID, backend: handle)
    }

    public func releaseJob(attemptID: AttemptID) { backend.releaseJob(attemptID: attemptID) }
    public func shutdownRequest() { backend.shutdownRequest() }
}

public struct UnavailableEngine: ParchleyEngine, Sendable {
    public init() {}
    public func start(_ request: JobRequest) throws -> JobHandle { throw EngineError.internalFailure }
    public func releaseJob(attemptID: AttemptID) {}
    public func shutdownRequest() {}
}

private enum RustLibraryError: LocalizedError {
    case libraryNotFound(String)
    case missingSymbol(String)
    case engineCreationFailed
    case runtimeConfigurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .libraryNotFound(let detail):
            return "The bundled Rust library could not be opened. \(detail)"
        case .missingSymbol(let name):
            return "The bundled Rust library is missing \(name)."
        case .engineCreationFailed:
            return "The bundled Rust engine could not be created."
        case .runtimeConfigurationFailed(let detail):
            return "The bundled OCR runtime could not be configured: \(detail)"
        }
    }
}

/// The production adapter for the bundled Rust engine.
///
/// The Rust library exports a small JSON C ABI. Loading it at runtime keeps the
/// Swift package testable without requiring a machine-specific artifact, while
/// the app target supplies the bundled static/dynamic library at link time.
public struct RustEngine: ParchleyEngine, Sendable {
    private let library: RustLibrary

    public init(libraryURL: URL? = nil) throws {
        self.library = try RustLibrary(url: libraryURL)
    }

    public func start(_ request: JobRequest) throws -> JobHandle {
        let backend = try RustJobBackend(library: library, request: request)
        return JobHandle(attemptID: request.attemptID, backend: backend)
    }

    public func releaseJob(attemptID: AttemptID) {
        // The Swift JobHandle owns the native job lease. Dropping that handle
        // calls parchly_job_free after the final snapshot/result call.
        _ = attemptID
    }

    public func shutdownRequest() { library.shutdown() }
}

/// The only type that stores a native handle. Calls and destruction share one
/// lock, so the handle cannot be freed while another synchronous ABI call uses
/// it. The wrapper is `@unchecked Sendable` because the pointer is otherwise
/// intentionally hidden from Swift's value-level concurrency checking.
private final class LockedFFIHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: UnsafeMutableRawPointer?
    private let free: @convention(c) (UnsafeMutableRawPointer?) -> Void

    init(pointer: UnsafeMutableRawPointer, free: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void) {
        self.pointer = pointer
        self.free = free
    }

    func withPointer<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let pointer else { return nil }
        return body(pointer)
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        guard let pointer else { return }
        self.pointer = nil
        free(pointer)
    }
}

private final class RustLibrary: @unchecked Sendable {
    typealias NewEngine = @convention(c) () -> UnsafeMutableRawPointer?
    typealias FreeEngine = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    typealias Snapshot = @convention(c) (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
    typealias Cancel = @convention(c) (UnsafeRawPointer?) -> Void
    typealias Result = @convention(c) (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
    typealias FreeJob = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias Shutdown = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias ConfigureRuntime = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    typealias LastError = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

    private static var bundledFrameworksURL: URL {
        let frameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        if FileManager.default.fileExists(atPath: frameworks.path) { return frameworks }
        return Bundle.main.privateFrameworksURL ?? frameworks
    }

    private let engine: LockedFFIHandle
    fileprivate let startFunction: Start
    fileprivate let snapshotFunction: Snapshot
    fileprivate let cancelFunction: Cancel
    fileprivate let resultFunction: Result
    fileprivate let freeJob: FreeJob
    fileprivate let freeString: FreeString
    fileprivate let shutdownFunction: Shutdown
    private let lastErrorFunction: LastError

    init(url: URL?) throws {
        #if canImport(Darwin)
        #if DEBUG
        let developmentOverride = ProcessInfo.processInfo.environment["PARCHLY_RUST_LIBRARY"]
        #else
        let developmentOverride: String? = nil
        #endif
        let frameworks = Self.bundledFrameworksURL
        let bundledLibrary = frameworks.appendingPathComponent("libparchley_ffi.dylib").path
        let candidates = [url?.path, developmentOverride, bundledLibrary,
                          Bundle.main.path(forResource: "parchley_ffi", ofType: "dylib")].compactMap { $0 }
        var loaded: UnsafeMutableRawPointer?
        var loadFailures: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            loaded = dlopen(candidate, RTLD_NOW | RTLD_LOCAL)
            if loaded != nil { break }
            if let error = dlerror() { loadFailures.append("\(candidate): \(String(cString: error))") }
        }
        guard let loaded else {
            throw RustLibraryError.libraryNotFound(loadFailures.joined(separator: " "))
        }
        // Keep the dlopen reference resident for the process lifetime. Job
        // handles can outlive RustEngine values, and dlclose here would make
        // their function pointers unsafe. The loader reference is deliberate.
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let address = dlsym(loaded, name) else { throw RustLibraryError.missingSymbol(name) }
            return unsafeBitCast(address, to: type)
        }
        let freeEngine = try symbol("parchly_engine_free", FreeEngine.self)
        let start = try symbol("parchly_engine_start_json", Start.self)
        let snapshot = try symbol("parchly_job_snapshot_json", Snapshot.self)
        let cancel = try symbol("parchly_job_cancel", Cancel.self)
        let result = try symbol("parchly_job_result_json", Result.self)
        let freeJob = try symbol("parchly_job_free", FreeJob.self)
        let freeString = try symbol("parchly_string_free", FreeString.self)
        let shutdown = try symbol("parchly_engine_shutdown", Shutdown.self)
        let configureRuntime = try symbol("parchly_engine_configure_runtime", ConfigureRuntime.self)
        let lastError = try symbol("parchly_engine_last_error_json", LastError.self)
        let newEngine = try symbol("parchly_engine_new", NewEngine.self)
        guard let engine = newEngine() else { throw RustLibraryError.engineCreationFailed }

        self.startFunction = start
        self.snapshotFunction = snapshot
        self.cancelFunction = cancel
        self.resultFunction = result
        self.freeJob = freeJob
        self.freeString = freeString
        self.shutdownFunction = shutdown
        self.lastErrorFunction = lastError
        self.engine = LockedFFIHandle(pointer: engine, free: freeEngine)

        let pdfium = frameworks.appendingPathComponent("libpdfium.dylib")
        let ort = frameworks.appendingPathComponent("libonnxruntime.dylib")
        if FileManager.default.fileExists(atPath: pdfium.path), FileManager.default.fileExists(atPath: ort.path) {
            let error = pdfium.path.withCString { pdfiumPointer in
                ort.path.withCString { ortPointer in
                    self.engine.withPointer { raw in
                        configureRuntime(raw, pdfiumPointer, ortPointer)
                    } ?? nil
                }
            }
            if let error {
                let message = String(cString: error)
                freeString(error)
                throw RustLibraryError.runtimeConfigurationFailed(message)
            }
        }
        #else
        throw EngineError.internalFailure
        #endif
    }

    deinit {
        _ = engine.withPointer { shutdownFunction($0) }
    }

    func start(json: String) throws -> UnsafeMutableRawPointer {
        let outcome: (UnsafeMutableRawPointer?, RustError?)? = json.withCString { jsonPointer in
            engine.withPointer { raw in
                let job = startFunction(raw, jsonPointer)
                guard job == nil, let pointer = lastErrorFunction(raw) else { return (job, nil) }
                defer { freeString(pointer) }
                let data = Data(String(cString: pointer).utf8)
                return (nil, try? JSONDecoder().decode(RustError.self, from: data))
            }
        }
        guard let outcome, let job = outcome.0 else {
            if let error = outcome?.1 { throw mapRustError(error.kind) }
            throw EngineError.internalFailure
        }
        return job
    }

    func lastError() -> RustError? {
        guard let pointer = engine.withPointer({ lastErrorFunction($0) }) ?? nil else { return nil }
        defer { freeString(pointer) }
        guard let data = String(cString: pointer).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RustError.self, from: data)
    }

    func shutdown() {
        _ = engine.withPointer { shutdownFunction($0) }
    }
}

private final class RustJobBackend: EngineJobHandleBackend, Sendable {
    private let library: RustLibrary
    private let job: LockedFFIHandle
    private let expectedAttemptID: AttemptID

    init(library: RustLibrary, request: JobRequest) throws {
        self.library = library
        self.expectedAttemptID = request.attemptID
        let wire = RustRequest(request)
        let data = try JSONEncoder().encode(wire)
        let json = String(decoding: data, as: UTF8.self)
        self.job = LockedFFIHandle(pointer: try library.start(json: json), free: library.freeJob)
    }

    func snapshot() throws -> JobSnapshot {
        let wire: RustSnapshot = try decode(pointer: job.withPointer { raw in
            library.snapshotFunction(UnsafeRawPointer(raw))
        } ?? nil)
        guard let attempt = UUID(uuidString: wire.attemptID), AttemptID(attempt) == expectedAttemptID else {
            throw EngineError.internalFailure
        }
        let state: JobState
        switch wire.state {
        case "Queued": state = .queued
        case "Preparing": state = .preparing
        case "Converting": state = .converting
        case "Cancelling": state = .cancelling
        case "Completed": state = .completed
        case "Cancelled": state = .cancelled
        case "Failed": state = .failed
        default: throw EngineError.internalFailure
        }
        let stage: JobStage? = switch wire.stage {
        case "Reading PDF": .readingPDF
        case "Extracting native text": .extractingNativeText
        case "Recognizing scanned pages": .recognizingScannedPages
        case "Writing result": .writingResult
        case "Complete": .writingResult
        default: nil
        }
        let failure = wire.error.map { JobFailure(code: mapRustError($0.kind), message: $0.message) }
        return JobSnapshot(attemptID: AttemptID(attempt), revision: wire.revision, state: state,
                           stage: stage, pagesCompleted: wire.pagesCompleted.map(Int.init),
                           pagesTotal: wire.pagesTotal.map(Int.init), failure: failure)
    }

    func requestCancel() {
        _ = job.withPointer { raw in library.cancelFunction(UnsafeRawPointer(raw)) }
    }

    func resultDescriptor() throws -> ResultDescriptor {
        let result: RustResult? = try decode(pointer: job.withPointer { raw in
            library.resultFunction(UnsafeRawPointer(raw))
        } ?? nil)
        guard let result else { throw EngineError.outputUnavailable }
        guard let attempt = UUID(uuidString: result.attemptID), AttemptID(attempt) == expectedAttemptID,
              !result.manifestPath.isEmpty, !result.markdownPath.isEmpty,
              result.manifestPath.hasPrefix("/"), result.markdownPath.hasPrefix("/") else {
            throw EngineError.internalFailure
        }
        return ResultDescriptor(attemptID: AttemptID(attempt),
                                manifestURL: URL(fileURLWithPath: result.manifestPath),
                                markdownURL: URL(fileURLWithPath: result.markdownPath))
    }

    private func decode<T: Decodable>(pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        guard let pointer else { throw EngineError.internalFailure }
        defer { library.freeString(pointer) }
        do {
            return try JSONDecoder().decode(T.self, from: Data(String(cString: pointer).utf8))
        } catch {
            throw EngineError.internalFailure
        }
    }
}

private func mapRustError(_ kind: String) -> EngineError {
    switch kind {
    case "InvalidRequest": return .invalidRequest
    case "FileNotFound": return .inputUnavailable
    case "NotPdf": return .invalidPDF
    case "PasswordRequired": return .passwordRequired
    case "WrongPassword": return .incorrectPassword
    case "MissingOcrModel": return .modelRequired
    case "OutputUnavailable": return .outputUnavailable
    case "Cancelled": return .cancelled
    default: return .internalFailure
    }
}

private struct RustRequest: Encodable {
    let documentID: String
    let attemptID: String
    let inputPath: String
    let outputDirectory: String
    let pageNumbers: [UInt32]?
    let ocrMode: String
    let modelDirectory: String?
    let password: String?

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case attemptID = "attempt_id"
        case inputPath = "input_path"
        case outputDirectory = "output_directory"
        case pageNumbers = "page_numbers"
        case ocrMode = "ocr_mode"
        case modelDirectory = "model_directory"
        case password
    }

    init(_ request: JobRequest) {
        documentID = request.documentID.description
        attemptID = request.attemptID.description
        inputPath = request.stagedInputPath.path
        outputDirectory = request.outputDirectory.path
        pageNumbers = request.pageSelection.pages.isEmpty ? nil : request.pageSelection.pages.map(UInt32.init)
        ocrMode = request.ocrMode.rawValue.capitalized
        modelDirectory = request.modelDirectory?.path
        password = request.password
    }
}

private struct RustResult: Decodable {
    let attemptID: String
    let manifestPath: String
    let markdownPath: String

    enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id"
        case manifestPath = "manifest_path"
        case markdownPath = "markdown_path"
    }
}

private struct RustError: Decodable {
    let kind: String
    let message: String
}

private struct RustSnapshot: Decodable {
    let attemptID: String
    let revision: UInt64
    let state: String
    let stage: String?
    let pagesCompleted: UInt32?
    let pagesTotal: UInt32?
    let error: RustError?

    enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id"
        case revision
        case state
        case stage
        case pagesCompleted = "pages_completed"
        case pagesTotal = "pages_total"
        case error
    }
}

/// Polls one handle at a bounded cadence. The terminal snapshot is always yielded.
public struct SnapshotPoller: Sendable {
    public let intervalNanoseconds: UInt64

    public init(intervalNanoseconds: UInt64 = 200_000_000) {
        self.intervalNanoseconds = max(50_000_000, intervalNanoseconds)
    }

    public func waitForTerminal(_ handle: JobHandle,
                                onUpdate: @escaping @Sendable (JobSnapshot) -> Void = { _ in }) async throws -> JobSnapshot {
        var cancellationRequested = false
        var lastRevision: UInt64?
        while true {
            let snapshot = try handle.snapshot()
            if snapshot.revision != lastRevision {
                lastRevision = snapshot.revision
                onUpdate(snapshot)
            }
            if snapshot.isTerminal { return snapshot }

            if Task.isCancelled {
                if !cancellationRequested {
                    handle.requestCancel()
                    cancellationRequested = true
                }
                await Task.detached {
                    try? await Task.sleep(nanoseconds: self.intervalNanoseconds)
                }.value
            } else {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    handle.requestCancel()
                    cancellationRequested = true
                }
            }
        }
    }

    public func snapshots(for handle: JobHandle) -> AsyncThrowingStream<JobSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @concurrent in
                do {
                    _ = try await waitForTerminal(handle) { snapshot in
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

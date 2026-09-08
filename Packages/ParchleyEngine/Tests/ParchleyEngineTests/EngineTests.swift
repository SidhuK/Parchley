import Foundation
import ParchleyDomain
import XCTest

@testable import ParchleyEngine

final class EngineTests: XCTestCase {
  func testAdapterPreservesAttemptID() throws {
    let id = AttemptID()
    let backend = TestBackend()
    let engine = EngineAdapter(backend: backend)
    let request = try JobRequest(
      documentID: DocumentID(), attemptID: id,
      stagedInputPath: URL(fileURLWithPath: "/tmp/input.pdf"),
      outputDirectory: URL(fileURLWithPath: "/tmp/out"))
    XCTAssertEqual(try engine.start(request).attemptID, id)
  }

  func testRustEngineConvertsNativeTextFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["PARCHLY_RUST_LIBRARY"] else {
      throw XCTSkip("Set PARCHLY_RUST_LIBRARY to run the native Rust bridge fixture")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("fixture.pdf")
    try makeFixturePDF().write(to: input)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let request = try JobRequest(
      documentID: DocumentID(), attemptID: AttemptID(), stagedInputPath: input,
      outputDirectory: output, ocrMode: .off)
    let engine = try RustEngine(libraryURL: URL(fileURLWithPath: path))
    let handle = try engine.start(request)
    var terminal: JobSnapshot?
    for try await snapshot in SnapshotPoller(intervalNanoseconds: 50_000_000).snapshots(for: handle)
    { terminal = snapshot }
    XCTAssertEqual(terminal?.state, .completed, terminal?.failure?.message ?? "no failure detail")
    let result = try handle.resultDescriptor()
    XCTAssertTrue(
      try String(contentsOf: result.markdownURL, encoding: .utf8).contains("Parchley bridge"))
  }

  func testRustEngineMapsMissingInputAndMissingOutput() async throws {
    guard let path = ProcessInfo.processInfo.environment["PARCHLY_RUST_LIBRARY"] else {
      throw XCTSkip("Set PARCHLY_RUST_LIBRARY to run the native Rust bridge fixture")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("missing.pdf")
    let output = root.appendingPathComponent("output", isDirectory: true)
    let request = try JobRequest(
      documentID: DocumentID(), attemptID: AttemptID(),
      stagedInputPath: input, outputDirectory: output, ocrMode: .off)
    let engine = try RustEngine(libraryURL: URL(fileURLWithPath: path))
    let handle = try engine.start(request)
    let terminal = try await SnapshotPoller(intervalNanoseconds: 50_000_000).waitForTerminal(handle)
    XCTAssertEqual(terminal.state, .failed)
    XCTAssertEqual(terminal.failure?.code, .inputUnavailable)
    XCTAssertThrowsError(try handle.resultDescriptor()) { error in
      XCTAssertEqual(error as? EngineError, .outputUnavailable)
    }
  }

  func testRustEngineCancellationAndStaleHandleAreSafe() async throws {
    guard let path = ProcessInfo.processInfo.environment["PARCHLY_RUST_LIBRARY"] else {
      throw XCTSkip("Set PARCHLY_RUST_LIBRARY to run the native Rust bridge fixture")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("fixture.pdf")
    try makeFixturePDF().write(to: input)
    let request = try JobRequest(
      documentID: DocumentID(), attemptID: AttemptID(),
      stagedInputPath: input,
      outputDirectory: root.appendingPathComponent("output", isDirectory: true),
      ocrMode: .off)
    let engine = try RustEngine(libraryURL: URL(fileURLWithPath: path))
    let handle = try engine.start(request)
    handle.requestCancel()
    handle.requestCancel()
    engine.shutdownRequest()
    let terminal = try await SnapshotPoller(intervalNanoseconds: 50_000_000).waitForTerminal(handle)
    XCTAssertTrue([.cancelled, .failed].contains(terminal.state))
    XCTAssertNotNil(try handle.snapshot())
    XCTAssertThrowsError(try engine.start(request))
  }
}

private func makeFixturePDF() -> Data {
  let objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
    "4 0 obj\n<< /Length 46 >>\nstream\nBT /F1 18 Tf 72 720 Td (Parchley bridge) Tj ET\nendstream\nendobj\n",
    "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
  ]
  var pdf = Data("%PDF-1.4\n".utf8)
  var offsets = [0]
  for object in objects {
    offsets.append(pdf.count)
    pdf.append(Data(object.utf8))
  }
  let xref = pdf.count
  var tail = "xref\n0 6\n0000000000 65535 f \n"
  for offset in offsets.dropFirst() { tail += String(format: "%010d 00000 n \n", offset) }
  tail += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
  pdf.append(Data(tail.utf8))
  return pdf
}

private final class TestHandle: EngineJobHandleBackend, @unchecked Sendable {
  func snapshot() throws -> JobSnapshot {
    JobSnapshot(attemptID: AttemptID(), revision: 0, state: .queued)
  }
  func requestCancel() {}
  func resultDescriptor() throws -> ResultDescriptor { throw EngineError.outputUnavailable }
}
private struct TestBackend: EngineBackend {
  func start(_ request: JobRequest) throws -> any EngineJobHandleBackend { TestHandle() }
  func releaseJob(attemptID: AttemptID) {}
  func shutdownRequest() {}
}

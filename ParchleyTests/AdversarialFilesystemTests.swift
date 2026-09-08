import CryptoKit
import Foundation
import PDFKit
import XCTest

@testable import Parchley

@MainActor
final class AdversarialFilesystemTests: XCTestCase {
  func testStageRejectsOversizedPDFAndCleansTemporaryFiles() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("unsafe.pdf")
    try Data("%PDF-1.7\n123456".utf8).write(to: source)
    let job = folder.appendingPathComponent("job")

    XCTAssertThrowsError(
      try FileAccessService(maximumBytes: 5).stage(source, documentID: UUID(), directory: job)
    ) { error in
      guard case DocumentServiceError.fileTooLarge = error else {
        return XCTFail("expected a size error, got \(error)")
      }
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: job.appendingPathComponent("input.pdf").path))
    if FileManager.default.fileExists(atPath: job.path) {
      let leftovers = try FileManager.default.contentsOfDirectory(
        at: job, includingPropertiesForKeys: nil)
      XCTAssertTrue(leftovers.isEmpty)
    }
  }

  func testStageRejectsSymlinkedWorkspaceDirectory() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.pdf")
    try Data("%PDF-1.7\n".utf8).write(to: source)
    let outside = folder.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("job")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    XCTAssertThrowsError(try FileAccessService().stage(source, documentID: UUID(), directory: link))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: outside.appendingPathComponent("input.pdf").path))
  }

  func testExportRejectsTraversalAndConcurrentNamesDoNotCollide() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let service = ExportService()
    for name in ["../escape", "subdir/file", "subdir\\file", "..", "\u{202E}cod.exe"] {
      XCTAssertThrowsError(try service.safeFilename(from: name), "unsafe name: \(name)")
    }

    let outcomes = await withTaskGroup(
      of: ExportTestOutcome.self, returning: [ExportTestOutcome].self
    ) { group in
      for _ in 0..<16 {
        group.addTask {
          do {
            return .success(
              try service.export(
                ExportItem(documentID: UUID(), filename: "same", markdown: "# safe"),
                to: folder
              ))
          } catch {
            return .failure(error.localizedDescription)
          }
        }
      }
      var values: [ExportTestOutcome] = []
      for await outcome in group {
        values.append(outcome)
      }
      return values
    }
    let urls = outcomes.compactMap { outcome -> URL? in
      guard case .success(let url) = outcome else { return nil }
      return url
    }
    let errors = outcomes.compactMap { result -> String? in
      guard case .failure(let error) = result else { return nil }
      return error
    }

    XCTAssertEqual(urls.count, 16, errors.joined(separator: "\n"))
    XCTAssertEqual(Set(urls.map(\.lastPathComponent)).count, 16)
    XCTAssertTrue(urls.allSatisfy { $0.path.hasPrefix(folder.path + "/") })
  }

  func testExportRejectsSymlinkedDestinationFolderAndLargeMarkdown() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let outside = folder.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("export")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(
      try ExportService().export(
        ExportItem(documentID: UUID(), filename: "report", markdown: "text"),
        to: link
      ))

    XCTAssertThrowsError(
      try ExportService(maximumBytes: 4).export(
        ExportItem(documentID: UUID(), filename: "large", markdown: "12345"),
        to: folder
      )
    ) { error in
      guard case DocumentServiceError.fileTooLarge = error else {
        return XCTFail("expected a size error, got \(error)")
      }
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("large.md").path))
  }

  func testModelRejectsUnsafeManifestAndCleansCorruptPartialDownload() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fileURL = try XCTUnwrap(URL(string: "file:///tmp/model.bin"))
    let bad = ModelManifest(
      revision: "../escape",
      artifacts: [
        ModelArtifact(
          name: "model.bin", url: fileURL, byteCount: 5, sha256: String(repeating: "0", count: 64))
      ]
    )
    XCTAssertFalse(OCRModelManager.validate(bad))
    let manager = try OCRModelManager(root: folder.appendingPathComponent("Models"))
    do {
      _ = try await manager.install(bad, session: .shared)
      XCTFail("unsafe manifests must fail closed")
    } catch {
      guard case DocumentServiceError.modelDownloadFailed(_) = error else {
        return XCTFail("expected a manifest error, got \(error)")
      }
    }

    let orphan = folder.appendingPathComponent("Models/.download-orphan")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: orphan.appendingPathComponent("model.bin"))
    let managerAfterRestart = try OCRModelManager(root: folder.appendingPathComponent("Models"))
    _ = managerAfterRestart
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))

    let url = try XCTUnwrap(URL(string: "https://models.test/model.bin"))
    let manifest = ModelManifest(
      revision: "r1",
      artifacts: [
        ModelArtifact(
          name: "model.bin",
          url: url,
          byteCount: 5,
          sha256: digest(of: Data("model".utf8))
        )
      ]
    )
    AdversarialURLProtocol.responseData = Data("wrong".utf8)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AdversarialURLProtocol.self]
    let session = URLSession(configuration: configuration)
    do {
      _ = try await managerAfterRestart.install(manifest, session: session)
      XCTFail("corrupt downloads must fail integrity verification")
    } catch {
      guard case DocumentServiceError.hashMismatch = error else {
        return XCTFail("expected a hash mismatch, got \(error)")
      }
    }
    let contents = try FileManager.default.contentsOfDirectory(
      at: folder.appendingPathComponent("Models"),
      includingPropertiesForKeys: nil
    )
    XCTAssertFalse(contents.contains { $0.lastPathComponent.hasPrefix(".download-") })
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("Models/r1").path))
  }

  func testModelLeaseBlocksRemovalUntilReleased() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = try XCTUnwrap(URL(string: "https://models.test/model.bin"))
    let bytes = Data("model".utf8)
    let manifest = ModelManifest(
      revision: "r2",
      artifacts: [
        ModelArtifact(name: "model.bin", url: url, byteCount: 5, sha256: digest(of: bytes))
      ]
    )
    AdversarialURLProtocol.responseData = bytes
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AdversarialURLProtocol.self]
    let manager = try OCRModelManager(root: folder.appendingPathComponent("Models"))
    _ = try await manager.install(manifest, session: URLSession(configuration: configuration))
    _ = try await manager.acquireLease()
    do {
      try await manager.remove()
      XCTFail("a leased model must not be removed")
    } catch {
      guard case DocumentServiceError.diskFailure = error else {
        return XCTFail("expected a lease conflict, got \(error)")
      }
    }
    await manager.releaseLease()
    try await manager.remove()
    if case .notInstalled = await manager.state {
      // expected
    } else {
      XCTFail("released model should be removable")
    }
  }

  func testPDFPreviewRejectsMalformedPDF() throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Tests/Fixtures/malformed.pdf")
    XCTAssertNil(PDFPreview.validatedDocument(for: fixture))
  }

  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func digest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private enum ExportTestOutcome: Sendable {
  case success(URL)
  case failure(String)
}

private final class AdversarialURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var responseData = Data()

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

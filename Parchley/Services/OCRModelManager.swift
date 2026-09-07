import Foundation
import CryptoKit

nonisolated public struct ModelArtifact: Codable, Sendable, Equatable { public let name: String; public let url: URL; public let byteCount: Int64; public let sha256: String; public init(name: String, url: URL, byteCount: Int64, sha256: String) { self.name = name; self.url = url; self.byteCount = byteCount; self.sha256 = sha256 }; private enum CodingKeys: String, CodingKey { case name, url, byteCount = "bytes", sha256 } }
nonisolated public struct ModelManifest: Codable, Sendable, Equatable { public let revision: String; public let artifacts: [ModelArtifact]; public init(revision: String, artifacts: [ModelArtifact]) { self.revision = revision; self.artifacts = artifacts } }
nonisolated public enum ModelState: Sendable, Equatable { case notInstalled, downloading, verifying, ready(URL), failed(String), removing }
nonisolated public struct ModelProgress: Sendable, Equatable { public let completedBytes: Int64; public let totalBytes: Int64; public let artifact: String; public var fraction: Double? { totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : nil } }

public actor OCRModelManager {
    public let root: URL
    private(set) public var state: ModelState = .notInstalled
    private(set) public var progress: ModelProgress?
    private var installation: Task<URL, Error>?; private var leaseCount = 0
    public init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    public func discover(_ manifest: ModelManifest) -> URL? {
        guard Self.validManifest(manifest) else {
            progress = nil
            state = .failed("The OCR model manifest is invalid.")
            return nil
        }
        let url = root.appendingPathComponent(manifest.revision)
        guard isValidInstallation(url, manifest: manifest) else {
            progress = nil
            state = FileManager.default.fileExists(atPath: url.path)
                ? .failed("The installed OCR model failed integrity verification. Download it again.")
                : .notInstalled
            return nil
        }
        progress = nil
        state = .ready(url)
        return url
    }
    public func install(_ manifest: ModelManifest, session: URLSession = .shared) async throws -> URL {
        guard Self.validManifest(manifest) else { throw DocumentServiceError.modelDownloadFailed("The OCR model manifest is invalid.") }
        if let ready = discover(manifest) { return ready }; if let installation { return try await installation.value }
        progress = ModelProgress(completedBytes: 0,
                                 totalBytes: manifest.artifacts.reduce(0) { $0 + $1.byteCount },
                                 artifact: manifest.artifacts.first?.name ?? "")
        let task = Task { [self] in try await download(manifest, session: session) }
        installation = task
        state = .downloading
        do {
            let destination = try await task.value
            installation = nil
            progress = nil
            state = .ready(destination)
            return destination
        } catch {
            installation = nil
            progress = nil
            if error is CancellationError || Task.isCancelled {
                state = .notInstalled
                throw DocumentServiceError.cancelled
            }
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }
    public func cancelInstallation() { installation?.cancel() }
    public func acquireLease() throws -> URL { guard case .ready(let url) = state, FileManager.default.fileExists(atPath: url.path) else { throw DocumentServiceError.modelNotInstalled }; leaseCount += 1; return url }
    public func releaseLease() { leaseCount = max(0, leaseCount - 1) }
    public func remove() throws { guard installation == nil else { throw DocumentServiceError.conflict }; guard leaseCount == 0 else { throw DocumentServiceError.diskFailure("The OCR model is in use.") }; let previous = state; state = .removing; do { for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !url.lastPathComponent.hasPrefix(".") { try FileManager.default.removeItem(at: url) }; state = .notInstalled } catch { state = previous; throw error } }
    private func isValidInstallation(_ url: URL, manifest: ModelManifest) -> Bool { (try? Self.verify(url, manifest: manifest)) != nil }
    private static func validManifest(_ manifest: ModelManifest) -> Bool { !manifest.revision.isEmpty && manifest.revision == URL(fileURLWithPath: manifest.revision).lastPathComponent && !manifest.revision.contains("/") && !manifest.revision.contains("\\") && !manifest.artifacts.isEmpty && manifest.artifacts.allSatisfy { $0.byteCount >= 0 && $0.name == URL(fileURLWithPath: $0.name).lastPathComponent && !$0.name.isEmpty && $0.name != "." && $0.name != ".." && !$0.name.contains("/") && !$0.name.contains("\\") && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) } }
    private static func verify(_ folder: URL, manifest: ModelManifest) throws { for artifact in manifest.artifacts { let file = folder.appendingPathComponent(artifact.name); let data = try Data(contentsOf: file, options: [.mappedIfSafe]); guard Int64(data.count) == artifact.byteCount else { throw DocumentServiceError.hashMismatch }; let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(); guard digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame else { throw DocumentServiceError.hashMismatch } } }
    private func download(_ manifest: ModelManifest, session: URLSession) async throws -> URL {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await downloadOnce(manifest, session: session)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                lastError = error
                guard attempt < 3, Self.shouldRetry(error) else { throw error }
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
        throw lastError ?? DocumentServiceError.modelDownloadFailed("The OCR model download failed.")
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if case DocumentServiceError.modelDownloadFailed(let message) = error,
           let code = message.split(separator: " ").last.flatMap({ Int($0.filter(\.isNumber)) }),
           (400..<500).contains(code) {
            return false
        }
        return true
    }

    private func downloadOnce(_ manifest: ModelManifest, session: URLSession) async throws -> URL {
        let temp = root.appendingPathComponent(".download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            state = .downloading
            let totalBytes = manifest.artifacts.reduce(0) { $0 + $1.byteCount }
            var completedBytes: Int64 = 0
            for artifact in manifest.artifacts {
                try Task.checkCancellation()
                progress = ModelProgress(completedBytes: completedBytes,
                                         totalBytes: totalBytes,
                                         artifact: artifact.name)
                let (bytes, response) = try await session.bytes(from: artifact.url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DocumentServiceError.modelDownloadFailed("The OCR model download failed (HTTP \(http.statusCode)).")
                }
                let file = temp.appendingPathComponent(artifact.name)
                FileManager.default.createFile(atPath: file.path, contents: nil)
                let handle = try FileHandle(forWritingTo: file)
                do {
                    var count: Int64 = 0
                    var buffer = Data()
                    buffer.reserveCapacity(64 * 1024)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        count += 1
                        guard count <= artifact.byteCount else { throw DocumentServiceError.hashMismatch }
                        buffer.append(byte)
                        if buffer.count >= 64 * 1024 {
                            try handle.write(contentsOf: buffer)
                            buffer.removeAll(keepingCapacity: true)
                            progress = ModelProgress(completedBytes: completedBytes + count,
                                                     totalBytes: totalBytes,
                                                     artifact: artifact.name)
                        }
                    }
                    if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
                    guard count == artifact.byteCount else { throw DocumentServiceError.hashMismatch }
                    try handle.close()
                    completedBytes += count
                    progress = ModelProgress(completedBytes: completedBytes,
                                             totalBytes: totalBytes,
                                             artifact: artifact.name)
                } catch {
                    try? handle.close()
                    throw error
                }
            }
            state = .verifying
            progress = nil
            try Self.verify(temp, manifest: manifest)
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(manifest.revision)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

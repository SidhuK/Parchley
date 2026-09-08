import CryptoKit
import Foundation

nonisolated public struct ModelArtifact: Codable, Sendable, Equatable {
    public let name: String
    public let url: URL
    public let byteCount: Int64
    public let sha256: String

    public init(name: String, url: URL, byteCount: Int64, sha256: String) {
        self.name = name
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case url
        case byteCount = "bytes"
        case sha256
    }
}

nonisolated public struct ModelManifest: Codable, Sendable, Equatable {
    public let revision: String
    public let artifacts: [ModelArtifact]

    public init(revision: String, artifacts: [ModelArtifact]) {
        self.revision = revision
        self.artifacts = artifacts
    }
}

nonisolated public enum OCRModelConfigurationError: Error, LocalizedError, Sendable {
    case invalidArtifactURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArtifactURL(let name):
            return "The OCR model URL for " + name + " is invalid."
        }
    }

    public var recoverySuggestion: String? {
        "Update Parchley to restore the built-in OCR model configuration."
    }
}

/// The signed, versioned OCR model manifest used by the production app.
public enum OCRModelCatalog {
    public static func defaultManifest() throws -> ModelManifest {
        let definitions: [(name: String, address: String, bytes: Int64, sha256: String)] = [
            (
                "pp-ocrv6_small_det.onnx",
                "https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/pp-ocrv6_small_det.onnx",
                9_880_512,
                "d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e"
            ),
            (
                "pp-ocrv6_small_rec.onnx",
                "https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/pp-ocrv6_small_rec.onnx",
                21_159_378,
                "5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634"
            ),
            (
                "ppocrv6_dict.txt",
                "https://github.com/GreatV/oar-ocr/releases/download/v0.7.0/ppocrv6_dict.txt",
                74_947,
                "b5f2bfe2bdd9448429e3e82b51c789775d9b42f2403d082b00662eb77e401c5d"
            )
        ]

        let artifacts = try definitions.map { definition in
            guard let url = URL(string: definition.address) else {
                throw OCRModelConfigurationError.invalidArtifactURL(definition.name)
            }
            return ModelArtifact(
                name: definition.name,
                url: url,
                byteCount: definition.bytes,
                sha256: definition.sha256
            )
        }
        return ModelManifest(revision: "oar-ocr-v0.7.0", artifacts: artifacts)
    }
}

extension ModelManifest {
    static let unavailable = ModelManifest(revision: "unavailable", artifacts: [])
}

nonisolated public enum ModelState: Sendable, Equatable {
    case notInstalled
    case downloading
    case verifying
    case ready(URL)
    case bundled(URL)
    case failed(String)
    case removing
}

nonisolated public struct ModelProgress: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let artifact: String

    public var fraction: Double? {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil
    }
}

public actor OCRModelManager {
    public let root: URL
    public let bundledRoot: URL?
    private(set) public var state: ModelState = .notInstalled
    private(set) public var progress: ModelProgress?
    private var installation: Task<URL, Error>?
    private var installationRevision: String?
    private var leaseCount = 0
    private var lastManifest: ModelManifest?

    private static let maximumArtifactBytes: Int64 = 512 * 1024 * 1024
    private static let maximumManifestBytes: Int64 = 1024 * 1024 * 1024
    private static let maximumArtifactCount = 32

    public init(root: URL, bundledRoot: URL? = nil) throws {
        guard root.isFileURL else {
            throw DocumentServiceError.diskFailure("The OCR model folder is unavailable.")
        }
        self.root = root.standardizedFileURL
        self.bundledRoot = bundledRoot?.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        guard Self.isDirectory(self.root), !Self.isSymbolicLink(self.root) else {
            throw DocumentServiceError.diskFailure("The OCR model folder is unavailable.")
        }
        Self.removeStaleDownloads(in: self.root)
    }

    public func discover(_ manifest: ModelManifest) -> URL? {
        lastManifest = manifest
        guard Self.validManifest(manifest) else {
            progress = nil
            state = .failed("The OCR model manifest is invalid.")
            return nil
        }
        let url = root.appendingPathComponent(manifest.revision, isDirectory: true)
        if Self.isContained(url, in: root), isValidInstallation(url, manifest: manifest) {
            progress = nil
            state = .ready(url)
            return url
        }
        if let bundledRoot {
            let bundledURL = bundledRoot
            if isValidBundledInstallation(bundledURL, manifest: manifest) {
                progress = nil
                state = .bundled(bundledURL)
                return bundledURL
            }
        }
        progress = nil
        state = .failed(Self.isDirectory(url)
            ? "The installed OCR model failed integrity verification."
            : "The bundled OCR model is unavailable.")
        return nil
    }

    public func install(_ manifest: ModelManifest, session: URLSession = .shared) async throws -> URL {
        guard Self.validManifest(manifest) else {
            throw DocumentServiceError.modelDownloadFailed("The OCR model manifest is invalid.")
        }
        if let installation {
            guard installationRevision == manifest.revision else {
                throw DocumentServiceError.conflict
            }
            return try await installation.value
        }
        if let ready = discover(manifest) {
            return ready
        }
        guard leaseCount == 0 else {
            throw DocumentServiceError.conflict
        }

        let totalBytes = manifest.artifacts.reduce(0) { $0 + $1.byteCount }
        progress = ModelProgress(
            completedBytes: 0,
            totalBytes: totalBytes,
            artifact: manifest.artifacts[0].name
        )
        state = .downloading
        let task = Task { [self] in
            try await download(manifest, session: session)
        }
        installation = task
        installationRevision = manifest.revision

        do {
            let destination = try await task.value
            installation = nil
            installationRevision = nil
            progress = nil
            state = .ready(destination)
            return destination
        } catch {
            installation = nil
            installationRevision = nil
            progress = nil
            if error is CancellationError || Task.isCancelled {
                state = .notInstalled
                throw DocumentServiceError.cancelled
            }
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    public func cancelInstallation() {
        installation?.cancel()
    }

    public nonisolated static func validate(_ manifest: ModelManifest) -> Bool {
        validManifest(manifest)
    }

    /// The returned URL remains usable until a matching releaseLease call.
    public func acquireLease() throws -> URL {
        let url: URL
        switch state {
        case .ready(let readyURL):
            guard Self.isContained(readyURL, in: root) else { throw DocumentServiceError.modelNotInstalled }
            url = readyURL
        case .bundled(let bundledURL):
            guard let bundledRoot, Self.isContained(bundledURL, in: bundledRoot) else {
                throw DocumentServiceError.modelNotInstalled
            }
            url = bundledURL
        default:
            throw DocumentServiceError.modelNotInstalled
        }
        guard Self.isDirectory(url) else { throw DocumentServiceError.modelNotInstalled }
        leaseCount += 1
        return url
    }

    public func acquireLeaseIfAvailable() -> URL? {
        try? acquireLease()
    }

    public func releaseLease() {
        leaseCount = max(0, leaseCount - 1)
    }

    public func remove() throws {
        guard installation == nil else { throw DocumentServiceError.conflict }
        guard leaseCount == 0 else {
            throw DocumentServiceError.diskFailure("The OCR model is in use.")
        }

        let previous = state
        state = .removing
        do {
            Self.removeStaleDownloads(in: root)
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                guard !url.lastPathComponent.hasPrefix("."), Self.isContained(url, in: root) else {
                    continue
                }
                guard Self.isDirectory(url), !Self.isSymbolicLink(url) else {
                    continue
                }
                try FileManager.default.removeItem(at: url)
            }
            if bundledRoot != nil, let lastManifest {
                _ = discover(lastManifest)
            } else {
                state = .notInstalled
            }
        } catch {
            state = previous
            throw error
        }
    }

    private func isValidInstallation(_ url: URL, manifest: ModelManifest) -> Bool {
        (try? Self.verify(url, manifest: manifest)) != nil
    }

    private func isValidBundledInstallation(_ url: URL, manifest: ModelManifest) -> Bool {
        (try? Self.verify(url, manifest: manifest, allowsAdditionalFiles: true)) != nil
    }

    private nonisolated static func validManifest(_ manifest: ModelManifest) -> Bool {
        guard validComponent(manifest.revision, maximumBytes: 128),
              !manifest.revision.hasPrefix("."),
              !manifest.revision.hasSuffix("."),
              manifest.artifacts.count > 0,
              manifest.artifacts.count <= maximumArtifactCount else {
            return false
        }

        var names = Set<String>()
        var total: Int64 = 0
        for artifact in manifest.artifacts {
            guard validComponent(artifact.name, maximumBytes: 255),
                  !artifact.name.hasPrefix("."),
                  artifact.byteCount > 0,
                  artifact.byteCount <= maximumArtifactBytes,
                  let components = URLComponents(url: artifact.url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  let host = components.host,
                  !host.isEmpty,
                  components.user == nil,
                  components.password == nil,
                  components.fragment == nil,
                  !artifact.url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return false
            }
            guard artifact.sha256.utf8.count == 64,
                  artifact.sha256.utf8.allSatisfy({
                      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
                  }) else {
                return false
            }
            let key = collisionKey(artifact.name)
            guard names.insert(key).inserted,
                  total <= maximumManifestBytes - artifact.byteCount else {
                return false
            }
            total += artifact.byteCount
        }
        return true
    }

    private nonisolated static func validComponent(_ value: String, maximumBytes: Int) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= maximumBytes,
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains(":") else {
            return false
        }
        let unsafeScalars: Set<Unicode.Scalar> = [
            "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}",
            "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}",
            "\u{2069}", "\u{FEFF}"
        ]
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !unsafeScalars.contains($0)
        }
    }

    private static func verify(
        _ folder: URL,
        manifest: ModelManifest,
        allowsAdditionalFiles: Bool = false
    ) throws {
        guard isDirectory(folder), !isSymbolicLink(folder) else {
            throw DocumentServiceError.hashMismatch
        }
        let expected = Set(manifest.artifacts.map { collisionKey($0.name) })
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        if !allowsAdditionalFiles {
            guard contents.count == manifest.artifacts.count,
                  contents.allSatisfy({ expected.contains(collisionKey($0.lastPathComponent)) }) else {
                throw DocumentServiceError.hashMismatch
            }
        }

        for artifact in manifest.artifacts {
            let file = folder.appendingPathComponent(artifact.name, isDirectory: false)
            guard isRegularFile(file), !isSymbolicLink(file) else {
                throw DocumentServiceError.hashMismatch
            }
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize.map(Int64.init) == artifact.byteCount else {
                throw DocumentServiceError.hashMismatch
            }

            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            while true {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                total += Int64(data.count)
                hasher.update(data: data)
            }
            guard total == artifact.byteCount else {
                throw DocumentServiceError.hashMismatch
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
                throw DocumentServiceError.hashMismatch
            }
        }
    }

    private func download(_ manifest: ModelManifest, session: URLSession) async throws -> URL {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await downloadOnce(manifest, session: session)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                lastError = error
                guard attempt < 3, Self.shouldRetry(error) else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
        throw lastError ?? DocumentServiceError.modelDownloadFailed("The OCR model download failed.")
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if case DocumentServiceError.hashMismatch = error {
            return true
        }
        if case DocumentServiceError.modelDownloadFailed(let message) = error,
           let status = httpStatus(in: message) {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        if let urlError = error as? URLError {
            return [
                .badServerResponse, .cannotConnectToHost, .networkConnectionLost,
                .notConnectedToInternet, .timedOut, .dnsLookupFailed, .resourceUnavailable
            ].contains(urlError.code)
        }
        return false
    }

    private static func httpStatus(in message: String) -> Int? {
        guard let range = message.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else {
            return nil
        }
        return Int(message[range].dropFirst(5))
    }

    private func downloadOnce(_ manifest: ModelManifest, session: URLSession) async throws -> URL {
        let temporary = root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        guard Self.isDirectory(temporary), !Self.isSymbolicLink(temporary) else {
            throw DocumentServiceError.diskFailure("The OCR model could not be staged on disk.")
        }

        do {
            var completedBytes: Int64 = 0
            let totalBytes = manifest.artifacts.reduce(0) { $0 + $1.byteCount }
            for artifact in manifest.artifacts {
                try Task.checkCancellation()
                progress = ModelProgress(
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    artifact: artifact.name
                )

                let (bytes, response) = try await session.bytes(from: artifact.url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DocumentServiceError.modelDownloadFailed(
                        "The OCR model download failed (HTTP \(http.statusCode))."
                    )
                }
                if response.expectedContentLength > artifact.byteCount {
                    throw DocumentServiceError.hashMismatch
                }

                let file = temporary.appendingPathComponent(artifact.name, isDirectory: false)
                guard Self.isContained(file, in: temporary),
                      FileManager.default.createFile(atPath: file.path, contents: nil) else {
                    throw DocumentServiceError.diskFailure("The OCR model could not be saved to disk.")
                }
                let handle = try FileHandle(forWritingTo: file)
                do {
                    var count: Int64 = 0
                    var buffer = Data()
                    buffer.reserveCapacity(64 * 1024)
                    var hasher = SHA256()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard count < artifact.byteCount else {
                            throw DocumentServiceError.hashMismatch
                        }
                        count += 1
                        buffer.append(byte)
                        if buffer.count >= 64 * 1024 {
                            try handle.write(contentsOf: buffer)
                            hasher.update(data: buffer)
                            buffer.removeAll(keepingCapacity: true)
                            progress = ModelProgress(
                                completedBytes: completedBytes + count,
                                totalBytes: totalBytes,
                                artifact: artifact.name
                            )
                        }
                    }
                    if !buffer.isEmpty {
                        try handle.write(contentsOf: buffer)
                        hasher.update(data: buffer)
                    }
                    try handle.synchronize()
                    guard count == artifact.byteCount else {
                        throw DocumentServiceError.hashMismatch
                    }
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    guard digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
                        throw DocumentServiceError.hashMismatch
                    }
                    try handle.close()
                    completedBytes += count
                    progress = ModelProgress(
                        completedBytes: completedBytes,
                        totalBytes: totalBytes,
                        artifact: artifact.name
                    )
                } catch {
                    try? handle.close()
                    throw error
                }
            }

            state = .verifying
            progress = nil
            try Self.verify(temporary, manifest: manifest)
            try Task.checkCancellation()

            let destination = root.appendingPathComponent(manifest.revision, isDirectory: true)
            guard Self.isContained(destination, in: root) else {
                throw DocumentServiceError.modelDownloadFailed("The OCR model destination is invalid.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard Self.isDirectory(destination), !Self.isSymbolicLink(destination) else {
                    throw DocumentServiceError.diskFailure("The OCR model destination is unsafe.")
                }
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func removeStaleDownloads(in root: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents where url.lastPathComponent.hasPrefix(".download-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func isContained(_ child: URL, in directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = child.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

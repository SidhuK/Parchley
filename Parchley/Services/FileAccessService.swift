import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct StagedDocument: Sendable, Equatable {
    public let documentID: UUID
    public let sourceName: String
    public let url: URL
    public let byteCount: Int64
    public let sha256: String
}

public struct FileAccessService: Sendable {
    public let maximumBytes: Int64

    public nonisolated init(maximumBytes: Int64 = 250 * 1024 * 1024) {
        self.maximumBytes = max(1, maximumBytes)
    }

    /// Copies a user-selected PDF into the workspace while the security scope is held.
    /// The returned URL is workspace-owned and never depends on the source scope.
    public nonisolated func stage(_ source: URL, documentID: UUID, directory: URL) throws -> StagedDocument {
        guard source.isFileURL, directory.isFileURL else {
            throw DocumentServiceError.unavailable
        }

        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                source.stopAccessingSecurityScopedResource()
            }
        }

        guard Self.isRegularFile(source), !Self.isSymbolicLink(source) else {
            throw DocumentServiceError.unavailable
        }
        guard source.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame ||
            (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true else {
            throw DocumentServiceError.unsupportedFile
        }

        let values = try source.resourceValues(forKeys: [
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        if values.isUbiquitousItem == true,
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            throw DocumentServiceError.unavailable
        }
        if let size = values.fileSize.map(Int64.init), size > maximumBytes {
            throw DocumentServiceError.fileTooLarge(size)
        }

        let header = try FileHandle(forReadingFrom: source)
        defer { try? header.close() }
        let signature = try header.read(upToCount: 5) ?? Data()
        guard signature == Data("%PDF-".utf8) else {
            throw DocumentServiceError.invalidPDF
        }

        try Self.prepareDirectory(directory)
        let destination = directory.appendingPathComponent("input.pdf", isDirectory: false)
        let temporary = directory.appendingPathComponent(
            ".input-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard Self.isContained(temporary, in: directory) else {
            throw DocumentServiceError.unavailable
        }

        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItemIfExists(at: temporary)
            }
        }

        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw DocumentServiceError.diskFailure("The PDF could not be staged in the workspace.")
        }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary)
        defer {
            try? output.close()
        }

        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            if Int64(data.count) > maximumBytes - total {
                throw DocumentServiceError.fileTooLarge(total + Int64(data.count))
            }
            total += Int64(data.count)
            hasher.update(data: data)
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        try output.close()

        try Self.publish(temporary, as: destination)
        committed = true

        return StagedDocument(
            documentID: documentID,
            sourceName: source.deletingPathExtension().lastPathComponent,
            url: destination,
            byteCount: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private nonisolated static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard isDirectory(directory), !isSymbolicLink(directory) else {
            throw DocumentServiceError.unavailable
        }
    }

    private nonisolated static func publish(_ temporary: URL, as destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard isRegularFile(destination), !isSymbolicLink(destination) else {
                throw DocumentServiceError.diskFailure("The workspace already contains an unsafe staged file.")
            }
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private nonisolated static func isContained(_ child: URL, in directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = child.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private nonisolated static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private nonisolated static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

private extension FileManager {
    nonisolated func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}

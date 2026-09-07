import Foundation
import UniformTypeIdentifiers
import CryptoKit

public struct StagedDocument: Sendable, Equatable {
    public let documentID: UUID
    public let sourceName: String
    public let url: URL
    public let byteCount: Int64
    public let sha256: String
}

public struct FileAccessService: Sendable {
    public let maximumBytes: Int64
    public nonisolated init(maximumBytes: Int64 = 250 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    public nonisolated func stage(_ source: URL, documentID: UUID, directory: URL) throws -> StagedDocument {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: source.path) else { throw DocumentServiceError.unavailable }
        guard source.pathExtension.lowercased() == "pdf" || (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true else { throw DocumentServiceError.unsupportedFile }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current { throw DocumentServiceError.unavailable }
        guard let size = values.fileSize.map(Int64.init), size <= maximumBytes else { throw DocumentServiceError.fileTooLarge(values.fileSize.map(Int64.init) ?? -1) }
        guard let header = try? FileHandle(forReadingFrom: source) else { throw DocumentServiceError.unavailable }
        defer { try? header.close() }
        let signature = (try? header.read(upToCount: 5)) ?? Data()
        guard String(decoding: signature, as: UTF8.self) == "%PDF-" else { throw DocumentServiceError.invalidPDF }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("input.pdf", isDirectory: false)
        try FileManager.default.removeItemIfExists(at: destination)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItemIfExists(at: destination) } }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let input = try? FileHandle(forReadingFrom: source), let output = try? FileHandle(forWritingTo: destination) else { throw DocumentServiceError.unavailable }
        defer { try? input.close(); try? output.close() }
        var hasher = SHA256(); var total: Int64 = 0
        while true {
            if Task.isCancelled { throw DocumentServiceError.cancelled }
            let data = try input.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            total += Int64(data.count); if total > maximumBytes { throw DocumentServiceError.fileTooLarge(total) }
            hasher.update(data: data); try output.write(contentsOf: data)
        }
        completed = true
        return StagedDocument(documentID: documentID, sourceName: source.deletingPathExtension().lastPathComponent, url: destination, byteCount: total, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

private extension FileManager {
    nonisolated func removeItemIfExists(at url: URL) throws { if fileExists(atPath: url.path) { try removeItem(at: url) } }
}

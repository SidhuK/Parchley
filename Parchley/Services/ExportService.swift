import Foundation
import Darwin

/// A completed Markdown document ready to be written to disk.
nonisolated public struct ExportItem: Sendable, Equatable {
    public let documentID: UUID
    public let filename: String
    public let markdown: String

    public init(documentID: UUID, filename: String, markdown: String) {
        self.documentID = documentID
        self.filename = filename
        self.markdown = markdown
    }
}

/// The result of one item in a batch export.
nonisolated public struct ExportOutcome: Sendable, Equatable {
    public let item: ExportItem
    public let url: URL?
    public let error: String?

    public init(item: ExportItem, url: URL? = nil, error: String? = nil) {
        self.item = item
        self.url = url
        self.error = error
    }
}

/// Writes Markdown atomically and avoids overwriting existing files by default.
nonisolated public struct ExportService: Sendable {
    public let maximumBytes: Int64

    public init(maximumBytes: Int64 = 250 * 1024 * 1024) {
        self.maximumBytes = max(1, maximumBytes)
    }

    /// Returns a safe Markdown filename derived from a source document name.
    public nonisolated func safeFilename(from sourceName: String) throws -> String {
        let candidate = sourceName
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidate.isEmpty,
              candidate != ".",
              candidate != "..",
              !candidate.hasPrefix("."),
              !candidate.hasSuffix("."),
              !candidate.hasSuffix(" "),
              candidate.utf8.count <= 240,
              !candidate.contains("/"),
              !candidate.contains("\\"),
              !candidate.contains(":") else {
            throw DocumentServiceError.unsafeFilename
        }

        let unsafeScalars: Set<Unicode.Scalar> = [
            "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}",
            "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}",
            "\u{2069}", "\u{FEFF}"
        ]
        guard candidate.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && !unsafeScalars.contains($0)
        }) else {
            throw DocumentServiceError.unsafeFilename
        }

        let filename = candidate.lowercased().hasSuffix(".md") ? candidate : candidate + ".md"
        guard filename.utf8.count <= 240,
              URL(fileURLWithPath: filename).lastPathComponent == filename else {
            throw DocumentServiceError.unsafeFilename
        }
        return filename
    }

    /// Exports one item and returns the final URL.
    public nonisolated func export(_ item: ExportItem, to folder: URL, overwrite: Bool = false) throws -> URL {
        guard folder.isFileURL else {
            throw DocumentServiceError.diskFailure("Choose a local folder for export.")
        }

        let scoped = folder.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try Self.prepareDirectory(folder)
            let name = try safeFilename(from: item.filename)
            let temporary = folder.appendingPathComponent(
                "." + UUID().uuidString + ".tmp",
                isDirectory: false
            )
            guard Self.isContained(temporary, in: folder) else {
                throw DocumentServiceError.diskFailure("Choose a local folder for export.")
            }

            var committed = false
            defer {
                if !committed {
                    try? FileManager.default.removeItemIfExists(at: temporary)
                }
            }

            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw DocumentServiceError.diskFailure("The Markdown file could not be exported.")
            }
            try writeMarkdown(item.markdown, to: temporary)

            if overwrite {
                let destination = folder.appendingPathComponent(name, isDirectory: false)
                try publishReplacing(temporary, at: destination)
                committed = true
                return destination
            }

            for attempt in 0..<100_000 {
                let destination = folder.appendingPathComponent(
                    filename(for: name, attempt: attempt),
                    isDirectory: false
                )
                guard Self.isContained(destination, in: folder) else {
                    throw DocumentServiceError.unsafeFilename
                }
                guard destination.lastPathComponent.utf8.count <= 255 else {
                    throw DocumentServiceError.unsafeFilename
                }
                if Self.nameAlreadyExists(destination.lastPathComponent, in: folder) {
                    continue
                }

                if try publishUniquely(temporary, at: destination) {
                    committed = true
                    return destination
                }
            }
            throw DocumentServiceError.diskFailure("There are too many Markdown files with this name.")
        } catch let error as DocumentServiceError {
            throw error
        } catch {
            throw DocumentServiceError.diskFailure(
                "The Markdown file could not be exported. " + error.localizedDescription
            )
        }
    }

    private nonisolated func writeMarkdown(_ markdown: String, to temporary: URL) throws {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard Int64(normalized.utf8.count) <= maximumBytes else {
            throw DocumentServiceError.fileTooLarge(Int64(normalized.utf8.count))
        }

        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for byte in normalized.utf8 {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try handle.synchronize()
    }

    private nonisolated func publishReplacing(_ temporary: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard Self.isRegularFile(destination), !Self.isSymbolicLink(destination) else {
                throw DocumentServiceError.diskFailure("The export destination is not a regular file.")
            }
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private nonisolated func publishUniquely(_ temporary: URL, at destination: URL) throws -> Bool {
        // Linking is an atomic, non-overwriting publish when both URLs are in
        // the same directory. Unlike reserving an empty file and replacing it,
        // it leaves no gap in which another exporter can claim this name.
        do {
            try FileManager.default.linkItem(at: temporary, to: destination)
            try FileManager.default.removeItem(at: temporary)
            return true
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return false
        } catch {
            return try publishUniquelyByWriting(temporary, at: destination)
        }
    }

    private nonisolated func publishUniquelyByWriting(_ temporary: URL, at destination: URL) throws -> Bool {
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var committed = false
        defer {
            Darwin.close(descriptor)
            if !committed { try? FileManager.default.removeItem(at: destination) }
        }
        let source = try FileHandle(forReadingFrom: temporary)
        defer { try? source.close() }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        while let chunk = try source.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        committed = true
        try FileManager.default.removeItem(at: temporary)
        return true
    }

    private nonisolated func filename(for name: String, attempt: Int) -> String {
        guard attempt > 0 else { return name }
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return stem + "." + String(attempt + 1) + ".md"
    }

    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard isDirectory(directory), !isSymbolicLink(directory) else {
            throw DocumentServiceError.diskFailure("Choose a local folder for export.")
        }
    }

    private static func nameAlreadyExists(_ name: String, in directory: URL) -> Bool {
        let key = collisionKey(name)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains { collisionKey($0) == key }
    }

    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
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

private extension FileManager {
    nonisolated func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}

import AppKit
import PDFKit
import ParchleyEngine

actor LocalVLMConversionEngine: ConversionEngine {
    private let base: any ConversionEngine
    private let assistant: any LocalVLMPageAssistant

    init(base: any ConversionEngine, assistant: any LocalVLMPageAssistant) {
        self.base = base
        self.assistant = assistant
    }

    func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult {
        try await convert(input: input, attempt: attempt, options: ConversionOptions())
    }

    func convert(input: URL, attempt: ConversionAttempt, options: ConversionOptions) async throws -> EngineResult {
        try await convert(input: input, attempt: attempt, options: options, progress: { _ in })
    }

    func convert(
        input: URL,
        attempt: ConversionAttempt,
        options: ConversionOptions,
        progress: @escaping @Sendable (ConversionEngineProgress) -> Void
    ) async throws -> EngineResult {
        let result = try await base.convert(
            input: input,
            attempt: attempt,
            options: options,
            progress: progress
        )
        guard options.localVLMEnabled else { return result }
        guard let modelDirectory = options.localVLMModelDirectory else {
            return addingWarning("Local VLM assistance is enabled, but its model folder is unavailable.", to: result)
        }
        let ocrPages = result.pages.filter { $0.method.lowercased().contains("ocr") }
        guard !ocrPages.isEmpty else { return result }

        do {
            try await assistant.load(from: modelDirectory)
        } catch {
            await assistant.unload()
            return addingWarning("Local VLM could not load its model: \(error.localizedDescription)", to: result)
        }

        guard let document = PDFDocument(url: input) else {
            await assistant.unload()
            return addingWarning("Local VLM could not read the converted PDF pages.", to: result)
        }
        if document.isLocked {
            guard let password = options.password,
                  document.unlock(withPassword: password) else {
                await assistant.unload()
                return addingWarning("Local VLM could not unlock the converted PDF pages.", to: result)
            }
        }

        var pageWarnings: [Int: String] = [:]
        var additions: [(pageNumber: Int, text: String)] = []
        do {
            for page in ocrPages {
                try Task.checkCancellation()
                do {
                    let text = try await supplementalOCR(
                        for: page.pageNumber,
                        in: document,
                        attemptID: attempt.id
                    )
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed.caseInsensitiveCompare("NO ADDITIONS") != .orderedSame {
                        additions.append((page.pageNumber, trimmed))
                        pageWarnings[page.pageNumber] = "Local VLM added supplemental notes."
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    pageWarnings[page.pageNumber] = "Local VLM could not process page \(page.pageNumber): \(error.localizedDescription)"
                }
            }
        } catch {
            await assistant.unload()
            throw error
        }
        await assistant.unload()

        var warnings = result.warnings
        warnings.append(contentsOf: pageWarnings.sorted { $0.key < $1.key }.map {
            "Page \($0.key): \($0.value)"
        })
        let pages = result.pages.map { page in
            let warning = [page.warning, pageWarnings[page.pageNumber]]
                .compactMap { $0 }
                .joined(separator: "; ")
            return EnginePageMetadata(
                pageNumber: page.pageNumber,
                method: page.method,
                warning: warning.isEmpty ? nil : warning
            )
        }
        let markdown = additions.isEmpty
            ? result.markdown
            : result.markdown + "\n\n### Local VLM supplemental OCR\n\n" + additions
                .map { "#### Page \($0.pageNumber)\n\n\($0.text)" }
                .joined(separator: "\n\n")

        return EngineResult(
            markdown: markdown,
            warnings: warnings,
            engineVersion: result.engineVersion,
            modelVersion: result.modelVersion,
            pages: pages
        )
    }

    func cancel(attemptID: UUID) async {
        await base.cancel(attemptID: attemptID)
    }

    private func supplementalOCR(for pageNumber: Int, in document: PDFDocument, attemptID: UUID) async throws -> String {
        guard pageNumber > 0,
              let page = document.page(at: pageNumber - 1) else {
            throw LocalVLMPageError.unavailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParchleyVLM-\(attemptID.uuidString)-\(pageNumber)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                NSLog("Parchley could not remove a temporary local VLM page image: %@", error.localizedDescription)
            }
        }

        let thumbnail = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .cropBox)
        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw LocalVLMPageError.unavailable
        }
        let imageURL = directory.appendingPathComponent("page.png")
        try png.write(to: imageURL, options: .atomic)
        return try await assistant.supplementalOCR(for: imageURL)
    }

    private func addingWarning(_ warning: String, to result: EngineResult) -> EngineResult {
        EngineResult(
            markdown: result.markdown,
            warnings: result.warnings + [warning],
            engineVersion: result.engineVersion,
            modelVersion: result.modelVersion,
            pages: result.pages
        )
    }
}

private enum LocalVLMPageError: Error, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
        "The scanned PDF page could not be rendered for local vision assistance."
    }
}

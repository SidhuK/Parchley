import Foundation
import PDFKit
import ParchleyEngine
import XCTest

@testable import Parchley

final class LocalVLMConversionEngineTests: XCTestCase {
    func testAppendsSupplementalOCRAndReportsThePage() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("scanned.pdf")
        try makeFixturePDF().write(to: input)
        let assistant = StubLocalVLMPageAssistant(response: "| Item | Count |\n| --- | ---: |\n| Apples | 3 |")
        let sut = LocalVLMConversionEngine(
            base: StubConversionEngine(result: result(method: "ocr")),
            assistant: assistant
        )

        let converted = try await sut.convert(
            input: input,
            attempt: ConversionAttempt(documentID: UUID(), revision: 1),
            options: ConversionOptions(
                localVLMEnabled: true,
                localVLMModelDirectory: root
            )
        )

        XCTAssertTrue(converted.markdown.hasPrefix("Base OCR"))
        XCTAssertTrue(converted.markdown.contains("### Local VLM supplemental OCR"))
        XCTAssertTrue(converted.markdown.contains("#### Page 1"))
        XCTAssertTrue(converted.markdown.contains("| Apples | 3 |"))
        XCTAssertTrue(converted.warnings.contains("Page 1: Local VLM added supplemental notes."))
        XCTAssertEqual(converted.pages.first?.warning, "Local VLM added supplemental notes.")
        let processedImageCount = await assistant.processedImageCount
        XCTAssertEqual(processedImageCount, 1)
    }

    func testInferenceFailurePreservesBaseOCRAndAddsWarning() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("scanned.pdf")
        try makeFixturePDF().write(to: input)
        let assistant = StubLocalVLMPageAssistant(failsDuringInference: true)
        let sut = LocalVLMConversionEngine(
            base: StubConversionEngine(result: result(method: "ocr")),
            assistant: assistant
        )

        let converted = try await sut.convert(
            input: input,
            attempt: ConversionAttempt(documentID: UUID(), revision: 1),
            options: ConversionOptions(
                localVLMEnabled: true,
                localVLMModelDirectory: root
            )
        )

        XCTAssertEqual(converted.markdown, "Base OCR")
        XCTAssertTrue(converted.warnings.contains {
            $0.contains("Page 1: Local VLM could not process page 1:")
        })
        XCTAssertEqual(converted.pages.first?.warning?.contains("could not process page 1"), true)
    }

    func testDoesNotLoadVLMForNativePages() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("native.pdf")
        try makeFixturePDF().write(to: input)
        let assistant = StubLocalVLMPageAssistant(response: "Unused")
        let sut = LocalVLMConversionEngine(
            base: StubConversionEngine(result: result(method: "native")),
            assistant: assistant
        )

        let converted = try await sut.convert(
            input: input,
            attempt: ConversionAttempt(documentID: UUID(), revision: 1),
            options: ConversionOptions(
                localVLMEnabled: true,
                localVLMModelDirectory: root
            )
        )

        XCTAssertEqual(converted.markdown, "Base OCR")
        XCTAssertTrue(converted.warnings.isEmpty)
        let loadCount = await assistant.loadCount
        XCTAssertEqual(loadCount, 0)
    }

    private func result(method: String) -> EngineResult {
        EngineResult(
            markdown: "Base OCR",
            engineVersion: "test",
            pages: [EnginePageMetadata(pageNumber: 1, method: method)]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixturePDF() -> Data {
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
            "4 0 obj\n<< /Length 44 >>\nstream\nBT /F1 18 Tf 72 720 Td (Scanned page) Tj ET\nendstream\nendobj\n",
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
}

private actor StubConversionEngine: ConversionEngine {
    private let result: EngineResult

    init(result: EngineResult) {
        self.result = result
    }

    func convert(input: URL, attempt: ConversionAttempt) async throws -> EngineResult {
        result
    }

    func cancel(attemptID: UUID) async {}
}

private actor StubLocalVLMPageAssistant: LocalVLMPageAssistant {
    private let response: String
    private let failsDuringInference: Bool
    private(set) var processedImageCount = 0
    private(set) var loadCount = 0

    init(response: String = "", failsDuringInference: Bool = false) {
        self.response = response
        self.failsDuringInference = failsDuringInference
    }

    func load(from modelDirectory: URL) async throws {
        loadCount += 1
    }

    func supplementalOCR(for imageURL: URL) async throws -> String {
        processedImageCount += 1
        if failsDuringInference {
            throw StubVLMError.inferenceFailed
        }
        return response
    }

    func unload() async {}
}

private enum StubVLMError: Error, LocalizedError, Sendable {
    case inferenceFailed

    var errorDescription: String? { "test inference failure" }
}

import Foundation

public struct DocumentID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct AttemptID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public enum OCRMode: String, Codable, Sendable { case auto, off, force }

public struct PageSelection: Codable, Hashable, Sendable {
    public let pages: [Int]

    public init(pages: [Int] = []) throws {
        guard pages.allSatisfy({ $0 > 0 && $0 <= Int(UInt32.max) }) &&
                pages == pages.sorted() && Set(pages).count == pages.count else {
            throw DomainError.invalidPageSelection
        }
        self.pages = pages
    }

    private init(uncheckedPages pages: [Int]) {
        self.pages = pages
    }

    public static let all = PageSelection(uncheckedPages: [])
}

public struct JobRequest: Codable, Sendable {
    public let documentID: DocumentID
    public let attemptID: AttemptID
    public let stagedInputPath: URL
    public let outputDirectory: URL
    public let pageSelection: PageSelection
    public let ocrMode: OCRMode
    public let modelDirectory: URL?
    public let password: String?

    public init(documentID: DocumentID, attemptID: AttemptID, stagedInputPath: URL, outputDirectory: URL,
                pageSelection: PageSelection = .all, ocrMode: OCRMode = .auto,
                modelDirectory: URL? = nil, password: String? = nil) throws {
        guard stagedInputPath.isFileURL, outputDirectory.isFileURL,
              modelDirectory?.isFileURL ?? true,
              stagedInputPath.path.hasPrefix("/"), outputDirectory.path.hasPrefix("/") else {
            throw DomainError.invalidPath
        }
        self.documentID = documentID; self.attemptID = attemptID
        self.stagedInputPath = stagedInputPath; self.outputDirectory = outputDirectory
        self.pageSelection = pageSelection; self.ocrMode = ocrMode
        self.modelDirectory = modelDirectory; self.password = password
    }
}

public enum JobState: String, Codable, Sendable { case queued, preparing, converting, cancelling, completed, needsReview, failed, cancelled }
public enum JobStage: String, Codable, Sendable {
    case readingPDF, extractingNativeText, recognizingScannedPages, writingResult
}

public enum EngineError: String, Codable, Sendable, Error {
    case invalidRequest, inputUnavailable, invalidPDF, passwordRequired, incorrectPassword
    case modelRequired, modelUnavailable, unsupportedPDF, cancelled, outputUnavailable, internalFailure
}

public enum DomainError: Error, LocalizedError, Sendable {
    case invalidPageSelection
    case invalidPath

    public var errorDescription: String? {
        switch self {
        case .invalidPageSelection:
            return "The selected page range is invalid."
        case .invalidPath:
            return "The conversion input and output paths must be local file URLs."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidPageSelection:
            return "Select pages in ascending order without duplicates."
        case .invalidPath:
            return "Choose a PDF from local storage and try again."
        }
    }
}

public struct JobFailure: Codable, Sendable, Equatable {
    public let code: EngineError
    public let message: String
    public init(code: EngineError, message: String) { self.code = code; self.message = message }
}

public struct JobSnapshot: Codable, Sendable, Equatable {
    public let attemptID: AttemptID
    public let revision: UInt64
    public let state: JobState
    public let stage: JobStage?
    public let pagesCompleted: Int?
    public let pagesTotal: Int?
    public let failure: JobFailure?
    public init(attemptID: AttemptID, revision: UInt64, state: JobState, stage: JobStage? = nil,
                pagesCompleted: Int? = nil, pagesTotal: Int? = nil, failure: JobFailure? = nil) {
        self.attemptID = attemptID; self.revision = revision; self.state = state; self.stage = stage
        self.pagesCompleted = pagesCompleted; self.pagesTotal = pagesTotal; self.failure = failure
    }
    public var isTerminal: Bool { [.completed, .needsReview, .failed, .cancelled].contains(state) }
}

public struct ResultDescriptor: Codable, Sendable, Equatable {
    public let attemptID: AttemptID
    public let manifestURL: URL
    public let markdownURL: URL
    public let warningCount: Int
    public init(attemptID: AttemptID, manifestURL: URL, markdownURL: URL, warningCount: Int = 0) {
        self.attemptID = attemptID; self.manifestURL = manifestURL; self.markdownURL = markdownURL; self.warningCount = warningCount
    }
}

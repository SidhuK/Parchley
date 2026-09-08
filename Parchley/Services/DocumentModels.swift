import Foundation
import SwiftData

nonisolated public enum DocumentStatus: String, Codable, Hashable, Sendable {
    case queued, preparing, converting, cancelling, completed, needsReview, failed, interrupted, passwordRequired, modelRequired, cancelled
}

nonisolated public struct DocumentRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var sourceName: String
    public var sourceBookmark: Data?
    public var status: DocumentStatus
    public var attemptID: UUID?
    public var revision: Int
    public var resultRevision: Int?
    public var updatedAt: Date
    public var errorMessage: String?
    public var stage: String?
    public var pagesCompleted: Int?
    public var pagesTotal: Int?

    public init(id: UUID = UUID(), sourceName: String, sourceBookmark: Data? = nil,
                status: DocumentStatus = .queued, attemptID: UUID? = nil,
                revision: Int = 0, resultRevision: Int? = nil, updatedAt: Date = Date(),
                errorMessage: String? = nil, stage: String? = nil,
                pagesCompleted: Int? = nil, pagesTotal: Int? = nil) {
        self.id = id; self.sourceName = sourceName; self.sourceBookmark = sourceBookmark
        self.status = status; self.attemptID = attemptID; self.revision = revision
        self.resultRevision = resultRevision; self.updatedAt = updatedAt; self.errorMessage = errorMessage
        self.stage = stage; self.pagesCompleted = pagesCompleted; self.pagesTotal = pagesTotal
    }
}

nonisolated public struct WorkspaceMetadata: Codable, Sendable {
    public static let currentSchema = 3
    public var schemaVersion: Int
    public var documents: [DocumentRecord]
    public var lastSavedAt: Date
    public var draftRevisions: [UUID: Int]

    public init(documents: [DocumentRecord] = [], lastSavedAt: Date = Date(), schemaVersion: Int = currentSchema, draftRevisions: [UUID: Int] = [:]) {
        self.schemaVersion = schemaVersion; self.documents = documents; self.lastSavedAt = lastSavedAt; self.draftRevisions = draftRevisions
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, documents, lastSavedAt, draftRevisions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        documents = try c.decodeIfPresent([DocumentRecord].self, forKey: .documents) ?? []
        lastSavedAt = try c.decodeIfPresent(Date.self, forKey: .lastSavedAt) ?? Date.distantPast
        draftRevisions = try c.decodeIfPresent([UUID: Int].self, forKey: .draftRevisions) ?? [:]
    }
}

nonisolated public struct EngineResult: Codable, Sendable, Equatable {
    public let markdown: String
    public let warnings: [String]
    public let engineVersion: String
    public let modelVersion: String?
    public let pages: [EnginePageMetadata]
    public init(markdown: String, warnings: [String] = [], engineVersion: String = "unknown", modelVersion: String? = nil, pages: [EnginePageMetadata] = []) {
        self.markdown = markdown; self.warnings = warnings; self.engineVersion = engineVersion; self.modelVersion = modelVersion; self.pages = pages
    }
}

nonisolated public struct EnginePageMetadata: Codable, Sendable, Equatable {
    public let pageNumber: Int
    public let method: String
    public let warning: String?
    public init(pageNumber: Int, method: String, warning: String? = nil) {
        self.pageNumber = pageNumber; self.method = method; self.warning = warning
    }
}

nonisolated public struct ConversionAttempt: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let documentID: UUID
    public let revision: Int
    public init(id: UUID = UUID(), documentID: UUID, revision: Int) {
        self.id = id; self.documentID = documentID; self.revision = revision
    }
}

/// Supplies wall-clock time to services that persist timestamps.
///
/// Production uses the system clock. Tests can provide a fixed closure without
/// changing the behavior under test.
nonisolated public struct DateProvider: Sendable {
    public let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }
}

@Model
final class PersistedDocument {
    #Index<PersistedDocument>([\.queueOrder])

    @Attribute(.unique) var id: UUID
    var sourceName: String
    var sourceBookmark: Data?
    var statusRawValue: String
    var attemptID: UUID?
    var revision: Int
    var resultRevision: Int?
    var updatedAt: Date
    var errorMessage: String?
    var stage: String?
    var pagesCompleted: Int?
    var pagesTotal: Int?
    var queueOrder: Int
    @Attribute(.externalStorage) var resultData: Data?
    var draftMarkdown: String?
    var draftRevision: Int?

    init(record: DocumentRecord, queueOrder: Int) {
        id = record.id
        sourceName = record.sourceName
        sourceBookmark = record.sourceBookmark
        statusRawValue = record.status.rawValue
        attemptID = record.attemptID
        revision = record.revision
        resultRevision = record.resultRevision
        updatedAt = record.updatedAt
        errorMessage = record.errorMessage
        stage = record.stage
        pagesCompleted = record.pagesCompleted
        pagesTotal = record.pagesTotal
        self.queueOrder = queueOrder
        resultData = nil
        draftMarkdown = nil
        draftRevision = nil
    }

    func apply(_ record: DocumentRecord) {
        sourceName = record.sourceName
        sourceBookmark = record.sourceBookmark
        statusRawValue = record.status.rawValue
        attemptID = record.attemptID
        revision = record.revision
        resultRevision = record.resultRevision
        updatedAt = record.updatedAt
        errorMessage = record.errorMessage
        stage = record.stage
        pagesCompleted = record.pagesCompleted
        pagesTotal = record.pagesTotal
    }

    func record() throws -> DocumentRecord {
        guard let status = DocumentStatus(rawValue: statusRawValue) else {
            throw DocumentServiceError.diskFailure("The workspace contains an unknown document status.")
        }
        return DocumentRecord(
            id: id,
            sourceName: sourceName,
            sourceBookmark: sourceBookmark,
            status: status,
            attemptID: attemptID,
            revision: revision,
            resultRevision: resultRevision,
            updatedAt: updatedAt,
            errorMessage: errorMessage,
            stage: stage,
            pagesCompleted: pagesCompleted,
            pagesTotal: pagesTotal
        )
    }
}

enum ParchleySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [PersistedDocument.self] }
}

enum ParchleyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ParchleySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

nonisolated public enum DocumentServiceError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFile, fileTooLarge(Int64), unavailable, invalidPDF, hashMismatch
    case missingDocument, staleAttempt, cancelled, conflict, unsafeFilename, passwordRequired, modelRequired
    case diskFailure(String), modelNotInstalled, modelDownloadFailed(String), incorrectPassword
    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "The selected file is not a PDF."
        case .fileTooLarge(let size): return "This PDF is too large to import (\(size) bytes)."
        case .unavailable: return "The selected file is unavailable."
        case .invalidPDF: return "The PDF could not be read."
        case .hashMismatch: return "The downloaded file failed integrity verification."
        case .missingDocument: return "The document is no longer in the workspace."
        case .staleAttempt: return "This conversion result belongs to an older attempt."
        case .cancelled: return "The operation was cancelled."
        case .passwordRequired: return "This PDF needs a password."
        case .modelRequired: return "The OCR model is not installed."
        case .conflict: return "The draft changed while conversion was running."
        case .unsafeFilename: return "The document name cannot be used for export."
        case .diskFailure(let message): return message
        case .modelNotInstalled: return "The OCR model is not installed."
        case .modelDownloadFailed(let message): return message
        case .incorrectPassword: return "The password was incorrect."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFile, .invalidPDF:
            return "Choose a readable PDF file and try again."
        case .fileTooLarge:
            return "Choose a smaller PDF or split the document before importing it."
        case .unavailable:
            return "Check the file permissions or move the PDF to a local folder."
        case .hashMismatch, .modelDownloadFailed:
            return "Try the download again."
        case .missingDocument:
            return "Return to the document list and select an existing document."
        case .staleAttempt, .conflict:
            return "Reload the document and retry the operation."
        case .cancelled:
            return "Start the operation again when you are ready."
        case .passwordRequired:
            return "Enter the PDF password or choose Skip OCR if OCR is not needed."
        case .incorrectPassword:
            return "Check the password and try again."
        case .modelRequired, .modelNotInstalled:
            return "Download the OCR model or turn off OCR in Settings."
        case .unsafeFilename:
            return "Rename the document before exporting it."
        case .diskFailure:
            return "Check available storage and folder permissions, then try again."
        }
    }
}

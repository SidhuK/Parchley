import Foundation

public actor WorkspaceStore {
    public let root: URL
    private let fileManager = FileManager.default
    private var metadata: WorkspaceMetadata
    public init(root: URL? = nil) throws {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Parchley", isDirectory: true)
        self.root = base
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        for path in ["Results", "Drafts", "Caches/Jobs", "Models"] { try fileManager.createDirectory(at: base.appendingPathComponent(path), withIntermediateDirectories: true) }
        let primary = base.appendingPathComponent("workspace.json"), backup = base.appendingPathComponent("workspace.last-good.json")
        let loaded = [primary, backup].compactMap { url -> WorkspaceMetadata? in
            guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder.parchly.decode(WorkspaceMetadata.self, from: data), value.schemaVersion <= WorkspaceMetadata.currentSchema else { return nil }; return value
        }.first ?? WorkspaceMetadata()
        let recovered = Self.recovered(loaded)
        self.metadata = recovered
        let changed = recovered.documents != loaded.documents || recovered.schemaVersion != loaded.schemaVersion || recovered.draftRevisions != loaded.draftRevisions
        if changed { try? Self.writeAtomically(try JSONEncoder.parchly.encode(recovered), to: primary, backup: backup, fileManager: fileManager) }
    }
    public func documents() -> [DocumentRecord] { metadata.documents }
    public func upsert(_ record: DocumentRecord) throws { if let i = metadata.documents.firstIndex(where: { $0.id == record.id }) { metadata.documents[i] = record } else { metadata.documents.append(record) }; try persist() }
    public func record(for id: UUID) -> DocumentRecord? { metadata.documents.first { $0.id == id } }
    public func moveEarlier(documentID: UUID) throws { guard let index = metadata.documents.firstIndex(where: { $0.id == documentID }), index > 0 else { return }; metadata.documents.swapAt(index, index - 1); try persist() }
    public func remove(documentID: UUID) throws { metadata.documents.removeAll { $0.id == documentID }; metadata.draftRevisions.removeValue(forKey: documentID); try fileManager.removeItemIfExists(at: resultURL(documentID)); try fileManager.removeItemIfExists(at: draftFolder(documentID)); try fileManager.removeItemIfExists(at: root.appendingPathComponent("Caches/Jobs/\(documentID.uuidString)")); try persist() }
    public func saveResult(_ result: EngineResult, for documentID: UUID, revision: Int) throws -> URL { let folder = resultURL(documentID); try fileManager.createDirectory(at: folder, withIntermediateDirectories: true); let md = folder.appendingPathComponent("revision-\(revision).md"); try Self.writeAtomically(Data(result.markdown.utf8), to: md, fileManager: fileManager); try Self.writeAtomically(try JSONEncoder.parchly.encode(result), to: folder.appendingPathComponent("revision-\(revision).json"), fileManager: fileManager); return md }
    public func saveDraft(_ markdown: String, for documentID: UUID, revision: Int) throws { let folder = draftFolder(documentID); try fileManager.createDirectory(at: folder, withIntermediateDirectories: true); try Self.writeAtomically(Data(markdown.utf8), to: folder.appendingPathComponent("draft.md"), fileManager: fileManager); metadata.draftRevisions[documentID] = revision; try persist() }
    public func draft(for documentID: UUID) throws -> (markdown: String, revision: Int)? { let url = draftFolder(documentID).appendingPathComponent("draft.md"); guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }; return (text, metadata.draftRevisions[documentID] ?? 0) }
    public func discardDraft(for documentID: UUID) throws { try fileManager.removeItemIfExists(at: draftFolder(documentID)); metadata.draftRevisions.removeValue(forKey: documentID); try persist() }
    public func result(for documentID: UUID, revision: Int) throws -> EngineResult? { let url = resultURL(documentID).appendingPathComponent("revision-\(revision).json"); guard let data = try? Data(contentsOf: url) else { return nil }; return try JSONDecoder.parchly.decode(EngineResult.self, from: data) }
    public func hasDraft(for documentID: UUID) -> Bool { fileManager.fileExists(atPath: draftFolder(documentID).appendingPathComponent("draft.md").path) }
    public func clearHistory() throws { let ids = metadata.documents.filter { [.completed, .needsReview].contains($0.status) && !hasDraft(for: $0.id) }.map(\.id); for id in ids { try fileManager.removeItemIfExists(at: resultURL(id)) }; metadata.documents.removeAll { ids.contains($0.id) }; ids.forEach { metadata.draftRevisions.removeValue(forKey: $0) }; try persist() }
    public func prune(completedBefore cutoff: Date, maximumCount: Int = 20) throws { let completed = metadata.documents.filter { [.completed, .needsReview].contains($0.status) }.sorted { $0.updatedAt > $1.updatedAt }; for (index, record) in completed.enumerated() where index >= max(0, maximumCount) || record.updatedAt < cutoff { let hasDraft = fileManager.fileExists(atPath: draftFolder(record.id).appendingPathComponent("draft.md").path); guard !hasDraft else { continue }; try fileManager.removeItemIfExists(at: resultURL(record.id)); metadata.documents.removeAll { $0.id == record.id }; metadata.draftRevisions.removeValue(forKey: record.id) }; try persist() }
    public func jobDirectory(for attemptID: UUID) throws -> URL { let url = root.appendingPathComponent("Caches/Jobs/\(attemptID.uuidString)"); try fileManager.createDirectory(at: url, withIntermediateDirectories: true); return url }
    private func resultURL(_ id: UUID) -> URL { root.appendingPathComponent("Results/\(id.uuidString)") }
    private func draftFolder(_ id: UUID) -> URL { root.appendingPathComponent("Drafts/\(id.uuidString)") }
    private func persist() throws { metadata.schemaVersion = WorkspaceMetadata.currentSchema; metadata.lastSavedAt = Date(); try Self.writeAtomically(try JSONEncoder.parchly.encode(metadata), to: root.appendingPathComponent("workspace.json"), backup: root.appendingPathComponent("workspace.last-good.json"), fileManager: fileManager) }
    private static func recovered(_ value: WorkspaceMetadata) -> WorkspaceMetadata {
        var copy = value
        for i in copy.documents.indices where [.preparing, .converting, .cancelling].contains(copy.documents[i].status) {
            copy.documents[i].status = .interrupted
            copy.documents[i].attemptID = nil
            copy.documents[i].stage = nil
            copy.documents[i].pagesCompleted = nil
            copy.documents[i].pagesTotal = nil
            copy.documents[i].errorMessage = "Conversion was interrupted. Retry to continue."
            copy.documents[i].updatedAt = Date()
        }
        return copy
    }
    private static func writeAtomically(_ data: Data, to url: URL, backup: URL? = nil, fileManager: FileManager) throws { let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp"); do { try data.write(to: temp, options: .completeFileProtection); if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: .usingNewMetadataOnly) } else { try fileManager.moveItem(at: temp, to: url) }; if let backup { try? data.write(to: backup, options: .atomic) } } catch { try? fileManager.removeItem(at: temp); throw DocumentServiceError.diskFailure(error.localizedDescription) } }
}
private extension JSONEncoder { nonisolated static var parchly: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
private extension JSONDecoder { nonisolated static var parchly: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
private extension FileManager { nonisolated func removeItemIfExists(at url: URL) throws { if fileExists(atPath: url.path) { try removeItem(at: url) } } }

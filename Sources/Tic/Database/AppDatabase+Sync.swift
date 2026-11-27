import Foundation
import CryptoKit
import GRDB

/// Immutable, independently uploaded revision. A nil archive is an explicit deletion.
struct SyncOperation: Codable, Sendable {
    let format: String
    let version: Int
    let id: UUID
    let noteID: UUID
    let parentID: UUID?
    let archive: NoteArchive?
    let clipboardEntries: [SyncClipboardEntry]
    var mergeParentIDs: [UUID]? = nil
}

struct SyncConflict: Sendable {
    struct Branch: Sendable {
        let operationID: UUID
        let title: String?
        let isLocal: Bool
        var isDeleted: Bool { title == nil }
    }
    let noteID: UUID
    let branches: [Branch]
}

struct SyncClipboardEntry: Codable, Sendable {
    let id: UUID
    let noteId: UUID
    let text: String
    let imageData: Data?
    let createdAt: Date
    let thumbnail: Data?
}

enum SyncError: LocalizedError {
    case invalid, conflict, missingParent, unsavedChanges
    var errorDescription: String? {
        switch self {
        case .invalid: return AppLanguage.text("云端同步数据无效，未覆盖本地数据。", "Invalid sync data; local data was not overwritten.")
        case .conflict: return AppLanguage.text("检测到不同设备的并发修改，已暂停同步并保留数据。", "Concurrent edits detected. Sync paused and data was preserved.")
        case .missingParent: return AppLanguage.text("云端同步数据尚未完整下载。", "Sync data is incomplete; a parent revision is missing.")
        case .unsavedChanges: return AppLanguage.text("本地便签在同步期间发生变化，请重试。", "A local note changed during sync. Please retry.")
        }
    }
}

extension AppDatabase {
    private static func syncPrepare(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS ticoSyncHead (
                noteID TEXT PRIMARY KEY NOT NULL, operationID TEXT NOT NULL,
                fingerprint TEXT NOT NULL, deleted INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS ticoSyncOperation (
                id TEXT PRIMARY KEY NOT NULL, noteID TEXT NOT NULL, parentID TEXT,
                data BLOB NOT NULL, uploaded INTEGER NOT NULL
            )
            """)
    }

    private static func syncEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func syncArchive(_ noteID: UUID, db: Database) throws -> (NoteArchive?, [SyncClipboardEntry]) {
        guard try Note.filter(Note.Columns.id == noteID).fetchOne(db) != nil else { return (nil, []) }
        var archive = try exportNote(id: noteID, from: db)
        // Window geometry and visibility belong to this Mac, not to the shared content.
        let defaults = Note()
        archive.note.frameX = defaults.frameX
        archive.note.frameY = defaults.frameY
        archive.note.frameW = defaults.frameW
        archive.note.frameH = defaults.frameH
        archive.note.isOpen = defaults.isOpen
        archive.note.isCollapsed = defaults.isCollapsed
        archive.tasks.sort { $0.sortIndex == $1.sortIndex ? $0.id.uuidString < $1.id.uuidString : $0.sortIndex < $1.sortIndex }
        archive.inlineImages.sort { $0.id < $1.id }
        archive.taskImages.sort { $0.taskId.uuidString < $1.taskId.uuidString }
        let rows = try Row.fetchAll(db, sql: "SELECT id, noteId, text, imageData, createdAt, thumbnail FROM clipboardEntry WHERE noteId = ? ORDER BY id", arguments: [noteID])
        let entries = rows.map { row in
            SyncClipboardEntry(id: row["id"], noteId: row["noteId"], text: row["text"],
                               imageData: row["imageData"], createdAt: row["createdAt"], thumbnail: row["thumbnail"])
        }
        return (archive, entries)
    }

    private static func syncFingerprint(_ archive: NoteArchive?, _ entries: [SyncClipboardEntry]) throws -> String {
        struct Content: Codable { let archive: NoteArchive?; let entries: [SyncClipboardEntry] }
        var contentArchive = archive
        // Window movements update this timestamp too. Content itself still changes the hash.
        if let created = contentArchive?.note.createdAt { contentArchive?.note.updatedAt = created }
        return SHA256.hash(data: try syncEncode(Content(archive: contentArchive, entries: entries))).map { String(format: "%02x", $0) }.joined()
    }

    /// Persists local revisions and explicit deletion tombstones before any network operation.
    /// Must be called before applying remote revisions, including after every editing drain.
    func syncCaptureLocalChanges() async throws {
        try await dbQueue.write { db in
            try Self.syncPrepare(db)
            let notes = try Note.fetchAll(db)
            let current = Set(notes.map(\.id))
            let headRows = try Row.fetchAll(db, sql: "SELECT noteID, operationID, fingerprint, deleted FROM ticoSyncHead")
            var heads: [UUID: (UUID, String, Bool)] = [:]
            for row in headRows {
                guard let noteID = UUID(uuidString: row["noteID"]), let opID = UUID(uuidString: row["operationID"]) else { throw SyncError.invalid }
                heads[noteID] = (opID, row["fingerprint"], row["deleted"])
            }
            let deleted = Set(heads.compactMap { current.contains($0.key) || $0.value.2 ? nil : $0.key })
            for noteID in current.union(deleted).sorted(by: { $0.uuidString < $1.uuidString }) {
                let (archive, entries) = try Self.syncArchive(noteID, db: db)
                let fingerprint = try Self.syncFingerprint(archive, entries)
                let old = heads[noteID]
                if old?.1 == fingerprint { continue }
                let op = SyncOperation(format: "tico-sync", version: 1, id: UUID(), noteID: noteID, parentID: old?.0, archive: archive, clipboardEntries: entries)
                let data = try Self.syncEncode(op)
                try db.execute(sql: "INSERT INTO ticoSyncOperation (id,noteID,parentID,data,uploaded) VALUES (?,?,?,?,0)",
                               arguments: [op.id.uuidString, noteID.uuidString, op.parentID?.uuidString, data])
                try db.execute(sql: "INSERT OR REPLACE INTO ticoSyncHead (noteID,operationID,fingerprint,deleted) VALUES (?,?,?,?)",
                               arguments: [noteID.uuidString, op.id.uuidString, fingerprint, archive == nil])
            }
        }
    }

    func syncPendingOperations() async throws -> [SyncOperation] {
        try await dbQueue.write { db in
            try Self.syncPrepare(db)
            let rows = try Data.fetchAll(db, sql: "SELECT data FROM ticoSyncOperation WHERE uploaded = 0 ORDER BY rowid")
            return try rows.map { try JSONDecoder().decode(SyncOperation.self, from: $0) }
        }
    }

    /// Includes ancestors already marked uploaded so another destination can be repaired.
    func syncAllOperations() async throws -> [SyncOperation] {
        try await dbQueue.write { db in
            try Self.syncPrepare(db)
            return try Data.fetchAll(db, sql: "SELECT data FROM ticoSyncOperation ORDER BY rowid")
                .map { try JSONDecoder().decode(SyncOperation.self, from: $0) }
        }
    }

    static func syncOperationData(_ operation: SyncOperation) throws -> Data {
        try syncEncode(operation)
    }

    func syncMarkUploaded(ids: [UUID]) async throws {
        try await dbQueue.write { db in
            try Self.syncPrepare(db)
            for id in ids { try db.execute(sql: "UPDATE ticoSyncOperation SET uploaded = 1 WHERE id = ?", arguments: [id.uuidString]) }
        }
    }

    /// Applies an entire batch atomically. Concurrent branches are rejected without changing
    /// either side; callers must surface the conflict and keep the remote files intact.
    func syncApplyRemote(operations: [SyncOperation]) async throws {
        try await dbQueue.write { db in try Self.syncApply(operations, db: db) }
    }

    /// Call on the main actor immediately after checking that no note window is open.
    /// This avoids an opening window between the check and the transaction. Large batches
    /// may block the main thread; prefer an asynchronous apply behind a window-opening gate.
    func syncApplyRemoteSynchronously(operations: [SyncOperation]) throws {
        try dbQueue.write { db in try Self.syncApply(operations, db: db) }
    }

    private static func syncParents(_ op: SyncOperation) throws -> [UUID] {
        guard op.format == "tico-sync", (op.version == 1 || op.version == 2),
              op.archive?.note.id == op.noteID || op.archive == nil,
              op.archive != nil || op.clipboardEntries.isEmpty else { throw SyncError.invalid }
        if op.version == 1 {
            guard op.mergeParentIDs == nil else { throw SyncError.invalid }
            return op.parentID.map { [$0] } ?? []
        }
        guard op.parentID == nil, let parents = op.mergeParentIDs,
              parents.count >= 2, Set(parents).count == parents.count,
              !parents.contains(op.id) else { throw SyncError.invalid }
        return parents
    }

    private struct SyncNode {
        let id: UUID
        let noteID: UUID
        let parents: [UUID]
        let title: String?
    }

    private static func syncNode(_ op: SyncOperation) throws -> SyncNode {
        SyncNode(id: op.id, noteID: op.noteID, parents: try syncParents(op), title: op.archive?.note.title)
    }

    /// Keep only lightweight graph metadata; decode and release each historic image snapshot
    /// before reading the next row, so history size does not multiply peak image memory.
    private static func syncGraph(_ incoming: [SyncOperation], db: Database) throws -> [UUID: SyncNode] {
        let cursor = try Row.fetchCursor(db, sql: "SELECT data FROM ticoSyncOperation")
        var graph: [UUID: SyncNode] = [:]
        while let row = try cursor.next() {
            let data: Data = row["data"]
            let op = try JSONDecoder().decode(SyncOperation.self, from: data)
            guard graph[op.id] == nil else { throw SyncError.invalid }
            graph[op.id] = try syncNode(op)
        }
        var seenIncoming: [UUID: SyncOperation] = [:]
        for op in incoming {
            let node = try syncNode(op)
            if graph[op.id] != nil {
                let existing = try seenIncoming[op.id].map { try syncEncode($0) } ?? Data.fetchOne(db, sql: "SELECT data FROM ticoSyncOperation WHERE id = ?", arguments: [op.id.uuidString])
                guard existing == (try syncEncode(op)) else { throw SyncError.invalid }
            } else { graph[op.id] = node; seenIncoming[op.id] = op }
        }
        // Kahn's algorithm checks ancestry in O(revisions + parent edges), including cycles.
        var indegree: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        for (id, node) in graph {
            indegree[id] = node.parents.count
            for parent in node.parents {
                guard let source = graph[parent] else { throw SyncError.missingParent }
                guard source.noteID == node.noteID else { throw SyncError.invalid }
                children[parent, default: []].append(id)
            }
        }
        var ready = indegree.compactMap { $0.value == 0 ? $0.key : nil }
        var index = 0
        while index < ready.count {
            let id = ready[index]; index += 1
            for child in children[id, default: []] {
                indegree[child, default: 0] -= 1
                if indegree[child] == 0 { ready.append(child) }
            }
        }
        guard ready.count == graph.count else { throw SyncError.invalid }
        return graph
    }

    private static func syncLeaves(_ graph: [UUID: SyncNode], noteID: UUID) -> [SyncNode] {
        let nodes = graph.values.filter { $0.noteID == noteID }
        var parents = Set<UUID>()
        for node in nodes { parents.formUnion(node.parents) }
        return nodes.filter { !parents.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func syncLoad(_ node: SyncNode, incoming: [SyncOperation], db: Database) throws -> SyncOperation {
        if let op = incoming.first(where: { $0.id == node.id }) { return op }
        guard let data = try Data.fetchOne(db, sql: "SELECT data FROM ticoSyncOperation WHERE id = ?", arguments: [node.id.uuidString]) else { throw SyncError.invalid }
        return try JSONDecoder().decode(SyncOperation.self, from: data)
    }

    private static func syncHead(_ noteID: UUID, db: Database) throws -> (UUID, String)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT operationID, fingerprint FROM ticoSyncHead WHERE noteID = ?", arguments: [noteID.uuidString]) else { return nil }
        guard let id = UUID(uuidString: row["operationID"]) else { throw SyncError.invalid }
        return (id, row["fingerprint"])
    }

    private static func syncVerifyCurrent(_ noteID: UUID, db: Database) throws {
        let (current, entries) = try syncArchive(noteID, db: db)
        if let head = try syncHead(noteID, db: db) {
            guard try syncFingerprint(current, entries) == head.1 else { throw SyncError.unsavedChanges }
        } else if current != nil { throw SyncError.conflict }
    }

    private static func syncStore(_ operations: [SyncOperation], db: Database) throws {
        for op in operations {
            let bytes = try syncEncode(op)
            if let existing = try Data.fetchOne(db, sql: "SELECT data FROM ticoSyncOperation WHERE id = ?", arguments: [op.id.uuidString]) {
                guard existing == bytes else { throw SyncError.invalid }
                continue
            }
            try db.execute(sql: "INSERT INTO ticoSyncOperation (id,noteID,parentID,data,uploaded) VALUES (?,?,?,?,1)",
                           arguments: [op.id.uuidString, op.noteID.uuidString, op.parentID?.uuidString, bytes])
        }
    }

    private static func syncSetHead(_ op: SyncOperation, db: Database) throws {
        try syncReplace(op, db: db)
        let fingerprint = try syncFingerprint(op.archive, op.clipboardEntries)
        try db.execute(sql: "INSERT OR REPLACE INTO ticoSyncHead (noteID,operationID,fingerprint,deleted) VALUES (?,?,?,?)",
                       arguments: [op.noteID.uuidString, op.id.uuidString, fingerprint, op.archive == nil])
    }

    private static func syncApply(_ operations: [SyncOperation], db: Database) throws {
        try syncPrepare(db)
        let graph = try syncGraph(operations, db: db)
        let affected = Set(operations.map(\.noteID))
        for noteID in affected {
            let leaves = syncLeaves(graph, noteID: noteID)
            guard leaves.count == 1, let leaf = leaves.first else { throw SyncError.conflict }
            if try syncHead(noteID, db: db)?.0 == leaf.id { continue }
            try syncVerifyCurrent(noteID, db: db)
        }
        try syncStore(operations, db: db)
        for noteID in affected {
            guard let leaf = syncLeaves(graph, noteID: noteID).first else { throw SyncError.invalid }
            if try syncHead(noteID, db: db)?.0 != leaf.id { try syncSetHead(syncLoad(leaf, incoming: operations, db: db), db: db) }
        }
    }

    /// Inspect conflicting leaves without modifying either local or remote history.
    func syncConflicts(operations: [SyncOperation]) async throws -> [SyncConflict] {
        try await dbQueue.write { db in
            try Self.syncPrepare(db)
            let graph = try Self.syncGraph(operations, db: db)
            var result: [SyncConflict] = []
            for noteID in Set(operations.map(\.noteID)).sorted(by: { $0.uuidString < $1.uuidString }) {
                let leaves = Self.syncLeaves(graph, noteID: noteID)
                guard leaves.count > 1 else { continue }
                let local = try Self.syncHead(noteID, db: db)?.0
                result.append(SyncConflict(noteID: noteID, branches: leaves.map {
                    SyncConflict.Branch(operationID: $0.id, title: $0.title, isLocal: $0.id == local)
                }))
            }
            return result
        }
    }

    /// Explicitly resolve one conflict. All other branches become separate copies. The copies,
    /// merge revision, incoming history and data writes commit together or are all rolled back.
    func syncResolveConflict(noteID: UUID, selectedVersion: UUID, operations: [SyncOperation]) async throws -> [UUID] {
        try await dbQueue.write { db in try Self.syncResolve(noteID: noteID, selectedVersion: selectedVersion, operations: operations, db: db) }
    }

    /// Call on the main actor immediately after verifying no note window is open.
    func syncResolveConflictSynchronously(noteID: UUID, selectedVersion: UUID, operations: [SyncOperation]) throws -> [UUID] {
        try dbQueue.write { db in try Self.syncResolve(noteID: noteID, selectedVersion: selectedVersion, operations: operations, db: db) }
    }

    private static func syncResolve(noteID: UUID, selectedVersion: UUID, operations: [SyncOperation], db: Database) throws -> [UUID] {
            try Self.syncPrepare(db)
            let incoming = operations.filter { $0.noteID == noteID }
            let graph = try Self.syncGraph(incoming, db: db)
            let leaves = Self.syncLeaves(graph, noteID: noteID)
            guard leaves.count > 1, let chosen = leaves.first(where: { $0.id == selectedVersion }) else { throw SyncError.conflict }
            try Self.syncVerifyCurrent(noteID, db: db)
            try Self.syncStore(incoming, db: db)
            var copies: [UUID] = []
            for loser in leaves where loser.id != chosen.id {
                let losingOp = try Self.syncLoad(loser, incoming: incoming, db: db)
                guard let archive = losingOp.archive else { continue }
                guard losingOp.clipboardEntries.allSatisfy({ $0.noteId == noteID }) else { throw SyncError.invalid }
                var copy = try Self.importNote(archive, into: db)
                copy.title += AppLanguage.text("（同步冲突）", " (Sync conflict)")
                try copy.update(db)
                for entry in losingOp.clipboardEntries {
                    try db.execute(sql: "INSERT INTO clipboardEntry (id,noteId,text,imageData,createdAt,thumbnail) VALUES (?,?,?,?,?,?)",
                                   arguments: [UUID(), copy.id, entry.text, entry.imageData, entry.createdAt, entry.thumbnail])
                }
                let (snapshot, entries) = try Self.syncArchive(copy.id, db: db)
                let conflictOp = SyncOperation(format: "tico-sync", version: 1, id: UUID(), noteID: copy.id, parentID: nil, archive: snapshot, clipboardEntries: entries)
                try db.execute(sql: "INSERT INTO ticoSyncOperation (id,noteID,parentID,data,uploaded) VALUES (?,?,?,?,0)",
                               arguments: [conflictOp.id.uuidString, copy.id.uuidString, nil, try Self.syncEncode(conflictOp)])
                try db.execute(sql: "INSERT INTO ticoSyncHead (noteID,operationID,fingerprint,deleted) VALUES (?,?,?,0)",
                               arguments: [copy.id.uuidString, conflictOp.id.uuidString, try Self.syncFingerprint(snapshot, entries)])
                copies.append(copy.id)
            }
            let chosenOp = try Self.syncLoad(chosen, incoming: incoming, db: db)
            var merge = SyncOperation(format: "tico-sync", version: 2, id: UUID(), noteID: noteID, parentID: nil, archive: chosenOp.archive, clipboardEntries: chosenOp.clipboardEntries)
            merge.mergeParentIDs = leaves.map(\.id).sorted { $0.uuidString < $1.uuidString }
            try db.execute(sql: "INSERT INTO ticoSyncOperation (id,noteID,parentID,data,uploaded) VALUES (?,?,?,?,0)",
                           arguments: [merge.id.uuidString, noteID.uuidString, nil, try Self.syncEncode(merge)])
            try Self.syncSetHead(merge, db: db)
            return copies
    }

    private static func syncReplace(_ op: SyncOperation, db: Database) throws {
        if let archive = op.archive {
            guard archive.format == "tic-note", archive.version == 1,
                  archive.tasks.allSatisfy({ $0.noteId == op.noteID }),
                  op.clipboardEntries.allSatisfy({ $0.noteId == op.noteID }),
                  Set(archive.tasks.map(\.id)).count == archive.tasks.count,
                  Set(archive.inlineImages.map(\.id)).count == archive.inlineImages.count,
                  Set(archive.taskImages.map(\.taskId)).count == archive.taskImages.count,
                  Set(archive.taskImages.map(\.taskId)).isSubset(of: Set(archive.tasks.map(\.id))),
                  Set(op.clipboardEntries.map(\.id)).count == op.clipboardEntries.count else { throw SyncError.invalid }
            let source = archive.note.markdown as NSString
            let expression = try NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(tic-image://([0-9A-Fa-f-]+)\)"#)
            let references = Set(expression.matches(in: archive.note.markdown, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range(at: 1)) })
            guard references.isSubset(of: Set(archive.inlineImages.map(\.id))) else { throw SyncError.invalid }
        }
        let local = try Note.filter(Note.Columns.id == op.noteID).fetchOne(db)
        _ = try Note.filter(Note.Columns.id == op.noteID).deleteAll(db)
        guard let archive = op.archive else { return }
        var note = archive.note
        if let local {
            note.frameX = local.frameX; note.frameY = local.frameY
            note.frameW = local.frameW; note.frameH = local.frameH
            note.isOpen = local.isOpen; note.isCollapsed = local.isCollapsed
        }
        try note.insert(db)
        for task in archive.tasks { try task.insert(db) }
        for image in archive.inlineImages {
            try db.execute(sql: "INSERT INTO noteInlineImage (id,noteId,data,thumbnail) VALUES (?,?,?,?)", arguments: [image.id, op.noteID, image.data, image.thumbnail])
        }
        for image in archive.taskImages {
            try db.execute(sql: "INSERT INTO taskImage (taskId,data,cropX,cropY,cropW,cropH,updatedAt) VALUES (?,?,?,?,?,?,?)",
                           arguments: [image.taskId, image.data, image.cropX, image.cropY, image.cropW, image.cropH, Date()])
        }
        for entry in op.clipboardEntries {
            try db.execute(sql: "INSERT INTO clipboardEntry (id,noteId,text,imageData,createdAt,thumbnail) VALUES (?,?,?,?,?,?)",
                           arguments: [entry.id, entry.noteId, entry.text, entry.imageData, entry.createdAt, entry.thumbnail])
        }
    }
}

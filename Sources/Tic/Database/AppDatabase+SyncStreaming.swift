import Foundation
import GRDB

extension AppDatabase {
    /// Read revision metadata separately so already-synced image history is not decoded at once.
    func syncOperationIDs() async throws -> [UUID] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM ticoSyncOperation ORDER BY rowid").map {
                guard let id = UUID(uuidString: $0) else { throw SyncError.invalid }
                return id
            }
        }
    }

    func syncOperationBytes(id: UUID) async throws -> Data {
        try await dbQueue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT data FROM ticoSyncOperation WHERE id = ?",
                                               arguments: [id.uuidString]) else { throw SyncError.invalid }
            return data
        }
    }
}

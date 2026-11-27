import Foundation

/// Exchanges immutable revisions using the same path in the app and integration tests.
enum WebDAVSyncExchange {
    static func exchange(database: AppDatabase, client: WebDAVClient) async throws -> [SyncOperation] {
        let local = try await database.syncOperationIDs()
        let localIDs = Set(local)
        let names = try await client.list().filter { $0.hasPrefix("sync-op-") && $0.hasSuffix(".json") }
        var remote: [SyncOperation] = []
        var remoteIDs = Set<UUID>()
        for name in names {
            let rawID = String(name.dropFirst("sync-op-".count).dropLast(".json".count))
            guard let id = UUID(uuidString: rawID), remoteIDs.insert(id).inserted else { throw SyncError.invalid }
            let data = try await client.download(name: name)
            if localIDs.contains(id) {
                guard try await database.syncOperationBytes(id: id) == data else { throw SyncError.invalid }
            } else {
                let op = try JSONDecoder().decode(SyncOperation.self, from: data)
                guard op.id == id else { throw SyncError.invalid }
                remote.append(op)
            }
        }
        for id in local {
            if !remoteIDs.contains(id) {
                let data = try await database.syncOperationBytes(id: id)
                try await client.upload(name: "sync-op-\(id.uuidString).json", data: data)
            }
            try await database.syncMarkUploaded(ids: [id])
        }
        return remote
    }
}

import Foundation
import GRDB
import Testing
@testable import Tic

@Suite("WebDAV sync integration", .serialized)
struct WebDAVSyncIntegrationTests {
    @Test("two isolated devices exchange, resolve concurrent edits, delete and converge")
    func twoDevices() async throws {
        MemoryDAVProtocol.reset()
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MemoryDAVProtocol.self]
        let config = try WebDAVConfiguration(baseURL: URL(string: "https://fake.test/dav/")!, username: "test")
        let client = try WebDAVClient(configuration: config, password: "test-password", sessionConfiguration: session)
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        try await client.verifyAuthentication()

        let note = Note(title: "Synthetic project")
        let task = TaskItem(noteId: note.id, text: "Synthetic task")
        let inlineID = UUID().uuidString
        try await a.insert(note)
        try await a.insert(task)
        try await a.storeInlineImage(noteID: note.id, id: inlineID, data: Data([1, 2, 3]), thumbnail: nil)
        try await a.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO clipboardEntry (id,noteId,text,imageData,createdAt,thumbnail) VALUES (?,?,?,?,?,?)",
                           arguments: [UUID(), note.id, "Synthetic clipboard", Data([4, 5]), Date(), nil])
        }
        try await a.syncCaptureLocalChanges()
        #expect(try await WebDAVSyncExchange.exchange(database: a, client: client).isEmpty)
        try await b.syncCaptureLocalChanges()
        let first = try await WebDAVSyncExchange.exchange(database: b, client: client)
        try await b.syncApplyRemote(operations: first)
        #expect(try await b.note(id: note.id)?.title == "Synthetic project")
        #expect(try await b.tasks(noteId: note.id).first?.text == "Synthetic task")
        #expect(try await b.exportNote(id: note.id).inlineImages.first?.data == Data([1, 2, 3]))
        let clipboardCount = try await b.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboardEntry WHERE noteId = ? AND text = ?",
                             arguments: [note.id, "Synthetic clipboard"])
        }
        #expect(clipboardCount == 1)

        try await a.updateNoteTitle(id: note.id, title: "Edit from A")
        try await b.updateNoteTitle(id: note.id, title: "Edit from B")
        try await a.syncCaptureLocalChanges()
        try await b.syncCaptureLocalChanges()
        _ = try await WebDAVSyncExchange.exchange(database: a, client: client)
        let aBranch = try await WebDAVSyncExchange.exchange(database: b, client: client)
        do {
            try await b.syncApplyRemote(operations: aBranch)
            Issue.record("Expected concurrent edit conflict")
        } catch SyncError.conflict {}
        #expect(try await b.note(id: note.id)?.title == "Edit from B")
        let bBranch = try await WebDAVSyncExchange.exchange(database: a, client: client)
        let conflict = try #require(try await a.syncConflicts(operations: bBranch).first)
        let local = try #require(conflict.branches.first(where: { $0.isLocal }))
        let copies = try await a.syncResolveConflict(noteID: note.id, selectedVersion: local.operationID,
                                                     operations: bBranch)
        #expect(copies.count == 1)
        _ = try await WebDAVSyncExchange.exchange(database: a, client: client)
        let resolution = try await WebDAVSyncExchange.exchange(database: b, client: client)
        try await b.syncApplyRemote(operations: resolution)
        #expect(try await b.note(id: note.id)?.title == "Edit from A")
        #expect(try await b.note(id: copies[0])?.title.contains("Edit from B") == true)
        let repeatChanges = try await WebDAVSyncExchange.exchange(database: b, client: client)
        #expect(repeatChanges.isEmpty)
        #expect(try await b.allNotes().count == 2)

        try await a.deleteNote(id: note.id)
        try await a.syncCaptureLocalChanges()
        _ = try await WebDAVSyncExchange.exchange(database: a, client: client)
        let deletion = try await WebDAVSyncExchange.exchange(database: b, client: client)
        try await b.syncApplyRemote(operations: deletion)
        #expect(try await b.note(id: note.id) == nil)
        #expect(try await b.note(id: copies[0]) != nil)
        #expect(try await WebDAVSyncExchange.exchange(database: b, client: client).isEmpty)
    }
}

/// An in-process server: no sockets, persisted files, credentials, or user data.
private final class MemoryDAVProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [String: Data] = [:]
    static func reset() { lock.lock(); defer { lock.unlock() }; files = [:] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let result = Self.respond(request)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func respond(_ request: URLRequest) -> (Int, Data) {
        guard request.value(forHTTPHeaderField: "Authorization") != nil else { return (401, Data()) }
        let name = request.url?.lastPathComponent ?? ""
        switch request.httpMethod {
        case "PROPFIND":
            let root = "<d:response><d:href>/dav/</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response>"
            let children = request.value(forHTTPHeaderField: "Depth") == "1" ? files.keys.sorted().map {
                "<d:response><d:href>/dav/\($0)</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response>"
            }.joined() : ""
            return (207, Data("<d:multistatus xmlns:d=\"DAV:\">\(root)\(children)</d:multistatus>".utf8))
        case "GET":
            guard let data = files[name] else { return (404, Data()) }
            return (200, data)
        case "PUT":
            guard request.value(forHTTPHeaderField: "If-None-Match") == "*" else { return (400, Data()) }
            guard files[name] == nil else { return (412, Data()) }
            let data: Data
            if let body = request.httpBody {
                data = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var result = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count < 0 { return (400, Data()) }
                    if count == 0 { break }
                    result.append(contentsOf: bytes.prefix(count))
                }
                data = result
            } else { return (400, Data()) }
            files[name] = data
            return (201, Data())
        case "DELETE":
            return files.removeValue(forKey: name) == nil ? (404, Data()) : (204, Data())
        default: return (405, Data())
        }
    }
}

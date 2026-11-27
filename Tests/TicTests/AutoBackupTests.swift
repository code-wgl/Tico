import Foundation
import Testing
@testable import Tic

@Suite("Automatic backups")
@MainActor
struct AutoBackupTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tico-auto-tests-\(UUID().uuidString)", isDirectory: true)
    }
    private var preferences: BackupPreferences {
        BackupPreferences(clipboardNoteID: nil, clipboardCaptureEnabled: false)
    }

    @Test("disabled backup does nothing; enabled snapshot runs once a day")
    func daily() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.makeInMemory()
        _ = try await db.insertNewNote(Note(title: "Example"))
        let service = AutoBackupService(directory: directory)
        var prepared = 0
        var finished = 0
        let disabled = try await service.runIfDue(enabled: false, database: db, prepare: { prepared += 1; return preferences }, finish: { finished += 1 })
        #expect(disabled == .disabled)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let first = try await service.runIfDue(enabled: true, database: db, prepare: { prepared += 1; return preferences }, finish: { finished += 1 })
        guard case .created(let url) = first else { Issue.record("missing backup"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
        let second = try await service.runIfDue(enabled: true, database: db, prepare: { prepared += 1; return preferences }, finish: { finished += 1 })
        #expect(second == .alreadyBackedUp)
        #expect(prepared == 1 && finished == 1)
        let target = try AppDatabase.makeInMemory()
        #expect(try target.importBackup(from: url).notes.map(\.title) == ["Example"])
    }

    @Test("retention deletes only registered automatic snapshots")
    func retention() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manual = directory.appendingPathComponent("My Manual Backup.ticbackup")
        try Data("manual".utf8).write(to: manual)
        let db = try AppDatabase.makeInMemory()
        let service = AutoBackupService(directory: directory, maximumBackups: 2)
        var created: [URL] = []
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in 0..<3 {
            let day = try #require(Calendar.current.date(byAdding: .day, value: offset, to: base))
            let result = try await service.runIfDue(enabled: true, database: db, now: day, prepare: { preferences }, finish: {})
            guard case .created(let url) = result else { Issue.record("missing backup"); return }
            created.append(url)
        }
        #expect(!FileManager.default.fileExists(atPath: created[0].path))
        #expect(FileManager.default.fileExists(atPath: created[1].path))
        #expect(FileManager.default.fileExists(atPath: created[2].path))
        #expect(try Data(contentsOf: manual) == Data("manual".utf8))
    }

    @Test("preparation failure preserves all snapshots and always resumes capture")
    func prepareFailure() async throws {
        enum ExampleError: Error { case pending }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.makeInMemory()
        let service = AutoBackupService(directory: directory, maximumBackups: 1)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = try await service.runIfDue(enabled: true, database: db, now: base, prepare: { preferences }, finish: {})
        guard case .created(let existing) = initial else { Issue.record("missing backup"); return }
        var finished = false
        let next = try #require(Calendar.current.date(byAdding: .day, value: 1, to: base))
        do {
            _ = try await service.runIfDue(enabled: true, database: db, now: next, prepare: { throw ExampleError.pending }, finish: { finished = true })
            Issue.record("preparation should fail")
        } catch ExampleError.pending {}
        #expect(finished)
        #expect(FileManager.default.fileExists(atPath: existing.path))
    }
}

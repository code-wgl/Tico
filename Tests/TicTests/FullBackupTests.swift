import Foundation
import GRDB
import Testing
@testable import Tic

@Suite("Full backup")
struct FullBackupTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tico-test-\(UUID().uuidString).ticbackup")
    }

    @Test("backup restores copies with clipboard history, images and closed state")
    func roundTrip() async throws {
        let source = try AppDatabase.makeInMemory()
        let imageID = UUID().uuidString
        let original = try await source.insertNewNote(Note(title: "Test", markdown: "![image](tic-image://\(imageID))", isCollapsed: true, isOpen: false))
        let task = TaskItem(noteId: original.id, text: "A task", isDone: true, sortIndex: 0)
        try await source.insert(task)
        let pixels = Data([1, 2, 3, 4])
        try await source.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO noteInlineImage (id,noteId,data,thumbnail) VALUES (?,?,?,?)", arguments: [imageID, original.id, pixels, pixels])
            try db.execute(sql: "INSERT INTO taskImage (taskId,data,cropX,cropY,cropW,cropH,updatedAt) VALUES (?,?,?,?,?,?,?)", arguments: [task.id, pixels, 0.1, 0.2, 0.5, 0.6, Date()])
            try db.execute(sql: "INSERT INTO clipboardEntry (id,noteId,text,imageData,thumbnail,createdAt) VALUES (?,?,?,?,?,?)", arguments: [UUID(), original.id, "synthetic", pixels, pixels, Date()])
        }
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let preferences = BackupPreferences(clipboardNoteID: original.id.uuidString, clipboardCaptureEnabled: true)
        try source.writeBackup(to: file, preferences: preferences)
        let target = try AppDatabase.makeInMemory()
        let existing = try await target.insertNewNote(Note(title: "Existing"))
        let result = try target.importBackup(from: file)
        let copy = try #require(result.notes.first)
        #expect(result.notes.count == 1)
        #expect(copy.id != original.id && copy.id != existing.id)
        #expect(!copy.isOpen && copy.isCollapsed)
        #expect(result.clipboardID == copy.id && result.preferences.clipboardCaptureEnabled)
        #expect(try await target.allNotes().count == 2)
        let archive = try await target.exportNote(id: copy.id)
        #expect(archive.tasks.count == 1 && archive.tasks[0].isDone)
        #expect(archive.inlineImages.first?.data == pixels && archive.taskImages.first?.data == pixels)
        #expect(archive.note.markdown.contains(try #require(archive.inlineImages.first?.id)))
        let copiedClipboard = try await target.dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT text,imageData,thumbnail FROM clipboardEntry WHERE noteId = ?", arguments: [copy.id]) else { return nil as (String, Data?, Data?)? }
            return (row["text"] as String, row["imageData"] as Data?, row["thumbnail"] as Data?)
        }
        #expect(copiedClipboard?.0 == "synthetic")
        #expect(copiedClipboard?.1 == pixels)
        #expect(copiedClipboard?.2 == pixels)
    }

    @Test("missing attachment rolls back every restored note")
    func missingImageRollsBack() async throws {
        let source = try AppDatabase.makeInMemory()
        _ = try await source.insertNewNote(Note(title: "First"))
        _ = try await source.insertNewNote(Note(title: "Broken", markdown: "![image](tic-image://\(UUID().uuidString))"))
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file) }
        try source.writeBackup(to: file, preferences: BackupPreferences(clipboardNoteID: nil, clipboardCaptureEnabled: false))
        let target = try AppDatabase.makeInMemory()
        _ = try await target.insertNewNote(Note(title: "Existing"))
        #expect(throws: (any Error).self) { try target.importBackup(from: file) }
        #expect(try await target.allNotes().map(\.title) == ["Existing"])
    }

    @Test("a damaged file does not modify existing data")
    func damagedBackup() async throws {
        let target = try AppDatabase.makeInMemory()
        _ = try await target.insertNewNote(Note(title: "Existing"))
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("invalid sqlite".utf8).write(to: file)
        #expect(throws: (any Error).self) { try target.importBackup(from: file) }
        #expect(try await target.allNotes().map(\.title) == ["Existing"])
    }

    @Test("old backup is migrated in a copy, leaving the original untouched")
    func migrateOldBackup() async throws {
        let source = try AppDatabase.makeInMemory()
        _ = try await source.insertNewNote(Note(title: "Older"))
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file) }
        try source.writeBackup(to: file, preferences: BackupPreferences(clipboardNoteID: nil, clipboardCaptureEnabled: false))
        do {
            let old = try DatabaseQueue(path: file.path)
            try await old.write { db in
                try db.execute(sql: "ALTER TABLE note DROP COLUMN backgroundOpacity")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v10_note_background_opacity'")
            }
        }
        let target = try AppDatabase.makeInMemory()
        let result = try target.importBackup(from: file)
        #expect(result.notes.first?.title == "Older")
        let check = try DatabaseQueue(path: file.path)
        let stillOld = try await check.read { db in
            try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v10_note_background_opacity'") == nil
        }
        #expect(stillOld)
    }
}

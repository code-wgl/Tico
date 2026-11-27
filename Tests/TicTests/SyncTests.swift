import Foundation
import GRDB
import Testing
@testable import Tic

@Suite("Sync revisions")
struct SyncTests {
    @Test("copies notes, tasks and images, then propagates deletions")
    func transferAndDelete() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Synthetic note")
        try await a.insert(note)
        let task = TaskItem(noteId: note.id, text: "Synthetic task")
        try await a.dbQueue.write { db in try task.insert(db) }
        try await a.storeInlineImage(noteID: note.id, id: UUID().uuidString, data: Data([1, 2]), thumbnail: nil)
        try await a.syncCaptureLocalChanges()
        let original = try await a.syncPendingOperations()
        try await b.syncApplyRemote(operations: original)
        #expect(try await b.tasks(noteId: note.id).first?.text == "Synthetic task")
        let imported = try await b.exportNote(id: note.id)
        #expect(imported.inlineImages.first?.data == Data([1, 2]))
        try await a.syncMarkUploaded(ids: original.map(\.id))
        try await a.deleteNote(id: note.id)
        try await a.syncCaptureLocalChanges()
        let deletion = try await a.syncPendingOperations()
        #expect(deletion.count == 1)
        #expect(deletion[0].archive == nil)
        try await b.syncApplyRemote(operations: deletion)
        #expect(try await b.note(id: note.id) == nil)
    }

    @Test("concurrent edits preserve local data and report conflict")
    func conflict() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Original")
        try await a.insert(note)
        try await a.syncCaptureLocalChanges()
        let root = try await a.syncPendingOperations()
        try await a.syncMarkUploaded(ids: root.map(\.id))
        try await b.syncApplyRemote(operations: root)
        try await a.updateNoteTitle(id: note.id, title: "Local A")
        try await b.updateNoteTitle(id: note.id, title: "Local B")
        try await a.syncCaptureLocalChanges()
        try await b.syncCaptureLocalChanges()
        let remote = try await a.syncPendingOperations()
        do {
            try await b.syncApplyRemote(operations: remote)
            Issue.record("Expected conflict")
        } catch SyncError.conflict {}
        #expect(try await b.note(id: note.id)?.title == "Local B")
    }

    @Test("local changes after capture cannot be overwritten by an incoming revision")
    func protectsChanges() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Original")
        try await a.insert(note)
        try await a.syncCaptureLocalChanges()
        let root = try await a.syncPendingOperations()
        try await a.syncMarkUploaded(ids: root.map(\.id))
        try await b.syncApplyRemote(operations: root)
        try await a.updateNoteTitle(id: note.id, title: "Remote")
        try await a.syncCaptureLocalChanges()
        try await b.updateNoteTitle(id: note.id, title: "Unsynced")
        do {
            try await b.syncApplyRemote(operations: a.syncPendingOperations())
            Issue.record("Expected unsaved changes")
        } catch SyncError.unsavedChanges {}
        #expect(try await b.note(id: note.id)?.title == "Unsynced")
    }

    @Test("duplicate revisions are idempotent and include clipboard and task images")
    func duplicateAndClipboard() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Synthetic")
        let task = TaskItem(noteId: note.id, text: "Synthetic")
        let entry = UUID()
        try await a.insert(note)
        try await a.dbQueue.write { db in
            try task.insert(db)
            try db.execute(sql: "INSERT INTO taskImage (taskId,data,updatedAt) VALUES (?,?,?)", arguments: [task.id, Data([3, 4]), Date()])
            try db.execute(sql: "INSERT INTO clipboardEntry (id,noteId,text,imageData,createdAt,thumbnail) VALUES (?,?,?,?,?,?)",
                           arguments: [entry, note.id, "synthetic clipboard", Data([5]), Date(), Data([6])])
        }
        try await a.syncCaptureLocalChanges()
        let ops = try await a.syncPendingOperations()
        try await b.syncApplyRemote(operations: ops)
        try await b.syncApplyRemote(operations: ops)
        let archive = try await b.exportNote(id: note.id)
        #expect(archive.taskImages.first?.data == Data([3, 4]))
        let count = try await b.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM clipboardEntry WHERE noteId = ? AND text = ?", arguments: [note.id, "synthetic clipboard"]) }
        #expect(count == 1)
    }

    @Test("batch conflicts roll back other notes and delete-edit conflicts preserve local edits")
    func atomicDeleteConflict() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let first = Note(title: "First")
        let second = Note(title: "Second")
        try await a.insert(first)
        try await a.insert(second)
        try await a.syncCaptureLocalChanges()
        let roots = try await a.syncPendingOperations()
        try await a.syncMarkUploaded(ids: roots.map(\.id))
        try await b.syncApplyRemote(operations: roots)
        try await a.updateNoteTitle(id: first.id, title: "Changed remotely")
        try await a.deleteNote(id: second.id)
        try await a.syncCaptureLocalChanges()
        let ops = try await a.syncPendingOperations().sorted { $0.noteID == first.id && $1.noteID != first.id }
        try await b.updateNoteTitle(id: second.id, title: "Edited locally")
        try await b.syncCaptureLocalChanges()
        do {
            try await b.syncApplyRemote(operations: ops)
            Issue.record("Expected conflict")
        } catch SyncError.conflict {}
        #expect(try await b.note(id: first.id)?.title == "First")
        #expect(try await b.note(id: second.id)?.title == "Edited locally")
    }

    @Test("missing parent cannot create partial history")
    func missingParent() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Original")
        try await a.insert(note)
        try await a.syncCaptureLocalChanges()
        let root = try await a.syncPendingOperations()
        try await a.syncMarkUploaded(ids: root.map(\.id))
        try await a.updateNoteTitle(id: note.id, title: "Changed")
        try await a.syncCaptureLocalChanges()
        do {
            try await b.syncApplyRemote(operations: a.syncPendingOperations())
            Issue.record("Expected missing parent")
        } catch SyncError.missingParent {}
        #expect(try await b.note(id: note.id) == nil)
    }

    @Test("local window positioning does not create sync conflicts or get replaced")
    func keepsLocalWindowState() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Original")
        try await a.insert(note)
        try await a.syncCaptureLocalChanges()
        let root = try await a.syncPendingOperations()
        try await a.syncMarkUploaded(ids: root.map(\.id))
        try await b.syncApplyRemote(operations: root)
        try await b.updateNoteFrame(id: note.id, x: 490, y: 500, width: 410, height: 420)
        try await b.updateNoteOpen(id: note.id, isOpen: false)
        try await b.syncCaptureLocalChanges()
        #expect(try await b.syncPendingOperations().isEmpty)
        try await a.updateNoteTitle(id: note.id, title: "Updated")
        try await a.syncCaptureLocalChanges()
        try await b.syncApplyRemote(operations: a.syncPendingOperations())
        let saved = try #require(try await b.note(id: note.id))
        #expect(saved.title == "Updated")
        #expect(saved.frameX == 490 && saved.frameY == 500 && saved.frameW == 410 && saved.frameH == 420)
        #expect(!saved.isOpen)
    }

    @Test("explicit resolution keeps losing edits as a copy and merges out-of-order history")
    func resolveConflict() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Original")
        try await a.insert(note)
        try await a.syncCaptureLocalChanges()
        try await b.syncApplyRemote(operations: a.syncAllOperations())
        try await a.updateNoteTitle(id: note.id, title: "On A")
        try await b.updateNoteTitle(id: note.id, title: "On B")
        try await a.syncCaptureLocalChanges()
        try await b.syncCaptureLocalChanges()
        let remote = try await b.syncAllOperations()
        let conflict = try #require(try await a.syncConflicts(operations: remote).first)
        let local = try #require(conflict.branches.first(where: { $0.isLocal }))
        let copies = try await a.syncResolveConflict(noteID: note.id, selectedVersion: local.operationID, operations: remote)
        #expect(copies.count == 1)
        #expect(try await a.note(id: copies[0])?.title.contains("On B") == true)
        let all = try await a.syncAllOperations()
        try await b.syncApplyRemote(operations: Array(all.reversed()))
        #expect(try await b.note(id: note.id)?.title == "On A")
        #expect(try await b.note(id: copies[0])?.title.contains("On B") == true)
        try await b.syncApplyRemote(operations: all)
        #expect(try await b.allNotes().count == 2)
    }

    @Test("delete versus edit can select deletion while preserving edited copy")
    func resolveDeleteConflict() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Original")
        try await a.insert(note)
        try await a.syncCaptureLocalChanges()
        try await b.syncApplyRemote(operations: a.syncAllOperations())
        try await a.deleteNote(id: note.id)
        try await b.updateNoteTitle(id: note.id, title: "Edited")
        try await a.syncCaptureLocalChanges()
        try await b.syncCaptureLocalChanges()
        let remote = try await b.syncAllOperations()
        let conflict = try #require(try await a.syncConflicts(operations: remote).first)
        let deleted = try #require(conflict.branches.first(where: { $0.isLocal && $0.isDeleted }))
        let copies = try await a.syncResolveConflict(noteID: note.id, selectedVersion: deleted.operationID, operations: remote)
        #expect(try await a.note(id: note.id) == nil)
        #expect(copies.count == 1)
        #expect(try await a.note(id: copies[0])?.title.contains("Edited") == true)
        try await b.syncApplyRemote(operations: a.syncAllOperations())
        #expect(try await b.note(id: note.id) == nil)
        #expect(try await b.note(id: copies[0])?.title.contains("Edited") == true)
    }

    @Test("simultaneous resolutions remain visible as conflict and can converge later")
    func simultaneousResolution() async throws {
        let a = try AppDatabase.makeInMemory()
        let b = try AppDatabase.makeInMemory()
        let note = Note(title: "Original")
        try await a.insert(note)
        try await a.syncCaptureLocalChanges()
        try await b.syncApplyRemote(operations: a.syncAllOperations())
        try await a.updateNoteTitle(id: note.id, title: "A edit")
        try await b.updateNoteTitle(id: note.id, title: "B edit")
        try await a.syncCaptureLocalChanges()
        try await b.syncCaptureLocalChanges()
        let aBefore = try await a.syncAllOperations()
        let bBefore = try await b.syncAllOperations()
        let ac = try #require(try await a.syncConflicts(operations: bBefore).first)
        let bc = try #require(try await b.syncConflicts(operations: aBefore).first)
        let aHead = try #require(ac.branches.first(where: { $0.isLocal }))
        let bHead = try #require(bc.branches.first(where: { $0.isLocal }))
        let aCopies = try await a.syncResolveConflict(noteID: note.id, selectedVersion: aHead.operationID, operations: bBefore)
        let bCopies = try await b.syncResolveConflict(noteID: note.id, selectedVersion: bHead.operationID, operations: aBefore)
        let aAfter = try await a.syncAllOperations()
        let bAfter = try await b.syncAllOperations()
        do { try await a.syncApplyRemote(operations: bAfter); Issue.record("Expected concurrent resolution conflict") }
        catch SyncError.conflict {}
        #expect(try await a.note(id: note.id)?.title == "A edit")
        let again = try #require(try await a.syncConflicts(operations: bAfter).first(where: { $0.noteID == note.id }))
        let winner = try #require(again.branches.first(where: { $0.isLocal }))
        _ = try await a.syncResolveConflict(noteID: note.id, selectedVersion: winner.operationID, operations: bAfter)
        try await b.syncApplyRemote(operations: a.syncAllOperations())
        try await a.syncApplyRemote(operations: b.syncAllOperations())
        #expect(try await b.note(id: note.id)?.title == "A edit")
        #expect(try await a.note(id: aCopies[0]) != nil)
        #expect(try await a.note(id: bCopies[0]) != nil)
        #expect(try await b.note(id: aCopies[0]) != nil)
        #expect(try await b.note(id: bCopies[0]) != nil)
        _ = aAfter
    }

}

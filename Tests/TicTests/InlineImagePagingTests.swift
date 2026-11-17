import Foundation
import Testing
@testable import Tic

@Suite("Inline image paging")
struct InlineImagePagingTests {
    @Test("observation reads only requested thumbnails and leaves other images in place")
    func selectedImagesOnly() async throws {
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        let other = Note()
        try await db.insert(note)
        try await db.insert(other)
        try await db.storeInlineImage(noteID: note.id, id: "AAAA", data: Data([1, 2]), thumbnail: Data([3]))
        try await db.storeInlineImage(noteID: note.id, id: "BBBB", data: Data([4, 5]), thumbnail: nil)
        try await db.storeInlineImage(noteID: other.id, id: "CCCC", data: Data([6]), thumbnail: nil)

        var first = db.observeInlineImages(noteID: note.id, ids: ["AAAA", "CCCC"]).makeAsyncIterator()
        let selected = try #require(try await first.next())
        #expect(selected.map(\.id) == ["AAAA"])
        #expect(selected.first?.data == Data([3]))

        var second = db.observeInlineImages(noteID: note.id, ids: ["BBBB"]).makeAsyncIterator()
        let older = try #require(try await second.next())
        #expect(older.map(\.id) == ["BBBB"])
        #expect(older.first?.data == Data([4, 5]))
    }

    @Test("changing segments discards stale cached images and shows the current segment")
    @MainActor
    func switchingSegments() async throws {
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        try await db.insert(note)
        try await db.storeInlineImage(noteID: note.id, id: "AAAA", data: Data([1]), thumbnail: nil)
        try await db.storeInlineImage(noteID: note.id, id: "BBBB", data: Data([2]), thumbnail: nil)
        let controller = NoteController(note: note, database: db)
        controller.setVisibleInlineImageMarkdown("![image](tic-image://AAAA)")
        for _ in 0..<100 where controller.inlineImages["AAAA"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.inlineImages == ["AAAA": Data([1])])

        controller.setVisibleInlineImageMarkdown("![image](tic-image://BBBB)")
        #expect(controller.inlineImages["AAAA"] == nil)
        for _ in 0..<100 where controller.inlineImages["BBBB"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.inlineImages == ["BBBB": Data([2])])

        // A new image can appear after the segment first starts observing, as clipboard
        // insertion and thumbnail generation are asynchronous.
        controller.setVisibleInlineImageMarkdown("![image](tic-image://CCCC)")
        try await db.storeInlineImage(noteID: note.id, id: "CCCC", data: Data([3]), thumbnail: nil)
        for _ in 0..<100 where controller.inlineImages["CCCC"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.inlineImages == ["CCCC": Data([3])])
        controller.stop()
    }
}

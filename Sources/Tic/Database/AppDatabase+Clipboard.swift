import Foundation
import GRDB

struct ClipboardEntry: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "clipboardEntry"
    var id = UUID()
    var noteId: UUID
    var text: String
    var imageData: Data?
    var createdAt = Date()
}

struct NoteInlineImage: Identifiable, Codable, FetchableRecord, Sendable {
    var id: String
    var data: Data
}

enum ClipboardContent {
    static func imageReference(_ id: String) -> String { "![image](tic-image://\(id))" }
    /// The first line remains editable; only restore the title when it is empty or the
    /// generic placeholder produced after the user clears the note.
    static func restoringTitle(in markdown: String) -> (markdown: String, title: String)? {
        let newline = markdown.firstIndex(of: "\n")
        let firstLine = String(newline.map { markdown[..<$0] } ?? markdown[...])
        var title = firstLine.trimmingCharacters(in: .whitespaces)
        let hashes = title.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes) {
            let rest = title.dropFirst(hashes)
            if rest.isEmpty || rest.first?.isWhitespace == true {
                title = rest.trimmingCharacters(in: .whitespaces)
            }
        }
        guard title.isEmpty || title == "Untitled Note" else { return nil }
        let restored = AppLanguage.text("剪贴板便签", "Clipboard Note")
        let remainder = newline.map { String(markdown[$0...]) } ?? ""
        return ("# \(restored)" + remainder, restored)
    }
    static func entry(_ content: String) -> String {
        content + (content.hasSuffix("\n") ? "\n" : "\n\n") + "---"
    }

    static func prepending(_ content: String, to markdown: String, fallbackTitle: String = "") -> String {
        guard !content.isEmpty else { return markdown }
        // Keep the separator in the ordinary editable document, including for image entries.
        let entry = entry(content)
        if markdown.isEmpty {
            let title = fallbackTitle.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? entry : "# \(title)\n\(entry)"
        }
        guard let newline = markdown.firstIndex(of: "\n") else { return markdown + "\n" + entry }
        let title = markdown[..<newline]
        let remaining = markdown[markdown.index(after: newline)...]
        return String(title) + "\n" + entry + (remaining.isEmpty ? "" : "\n\n" + remaining)
    }
}

extension AppDatabase {
    func storeInlineImage(noteID: UUID, id: String, data: Data, thumbnail: Data?) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO noteInlineImage (id, noteId, data, thumbnail) VALUES (?, ?, ?, ?)",
                           arguments: [id, noteID, data, thumbnail])
        }
    }

    func observeInlineImages(noteID: UUID) -> AsyncValueObservation<[NoteInlineImage]> {
        ValueObservation.tracking { db in
            try NoteInlineImage.fetchAll(db, sql: "SELECT id, COALESCE(thumbnail, data) AS data FROM noteInlineImage WHERE noteId = ?",
                                         arguments: [noteID])
        }.values(in: dbQueue)
    }

    func prependClipboardContent(noteID: UUID, content: String) async throws {
        try await dbQueue.write { db in
            guard let note = try Note.filter(Note.Columns.id == noteID).fetchOne(db) else { return }
            let markdown = ClipboardContent.prepending(content, to: note.markdown, fallbackTitle: note.title)
            try db.execute(sql: "UPDATE note SET markdown = ?, updatedAt = ? WHERE id = ?",
                           arguments: [markdown, Date(), noteID])
        }
    }

    func restoreClipboardTitle(noteID: UUID) async throws {
        try await dbQueue.write { db in
            guard let note = try Note.filter(Note.Columns.id == noteID).fetchOne(db),
                  let restored = ClipboardContent.restoringTitle(in: note.markdown) else { return }
            try db.execute(sql: "UPDATE note SET markdown = ?, title = ?, updatedAt = ? WHERE id = ?",
                           arguments: [restored.markdown, restored.title, Date(), noteID])
        }
    }
}

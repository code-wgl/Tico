import Foundation
import GRDB

/// A portable single-note backup. The IDs are remapped on import so duplicates are safe.
struct NoteArchive: Codable, Sendable {
    struct InlineImage: Codable, Sendable { var id: String; var data: Data; var thumbnail: Data? }
    struct TaskImage: Codable, Sendable {
        var taskId: UUID; var data: Data
        var cropX: Double; var cropY: Double; var cropW: Double; var cropH: Double
    }
    var format: String = "tic-note"
    var version: Int = 1
    var note: Note
    var tasks: [TaskItem]
    var inlineImages: [InlineImage]
    var taskImages: [TaskImage]
}

enum NoteArchiveError: LocalizedError {
    case invalid, unsupported, missingImage, unsaved
    var errorDescription: String? {
        switch self {
        case .invalid: AppLanguage.text("文件不是有效的 Tico 便签。", "This is not a valid Tico note file.")
        case .unsupported: AppLanguage.text("此便签文件的版本暂不支持。", "This note file version is not supported.")
        case .missingImage: AppLanguage.text("有图片数据缺失，未生成不完整的备份。", "Image data is missing; an incomplete backup was not saved.")
        case .unsaved: AppLanguage.text("最新编辑尚未保存，请重试。", "The latest edits have not been saved. Please try again.")
        }
    }
}

extension AppDatabase {
    func exportNote(id: UUID) async throws -> NoteArchive {
        try await dbQueue.read { db in
            guard let note = try Note.filter(Note.Columns.id == id).fetchOne(db) else { throw NoteArchiveError.invalid }
            let tasks = try TaskItem.filter(TaskItem.Columns.noteId == id).order(TaskItem.Columns.sortIndex).fetchAll(db)
            let inlineRows = try Row.fetchAll(db, sql: "SELECT id, data, thumbnail FROM noteInlineImage WHERE noteId = ?", arguments: [id])
            let inline = inlineRows.map { NoteArchive.InlineImage(id: $0["id"], data: $0["data"], thumbnail: $0["thumbnail"]) }
            let source = note.markdown as NSString
            let expression = try NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(tic-image://([0-9A-Fa-f-]+)\)"#)
            let ids = Set(expression.matches(in: note.markdown, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range(at: 1)) })
            guard ids.isSubset(of: Set(inline.map(\.id))) else { throw NoteArchiveError.missingImage }
            let imageRows = try Row.fetchAll(db, sql: "SELECT i.taskId, i.data, i.cropX, i.cropY, i.cropW, i.cropH FROM taskImage i JOIN task t ON t.id = i.taskId WHERE t.noteId = ?", arguments: [id])
            let images = imageRows.map { NoteArchive.TaskImage(taskId: $0["taskId"], data: $0["data"], cropX: $0["cropX"], cropY: $0["cropY"], cropW: $0["cropW"], cropH: $0["cropH"]) }
            return NoteArchive(note: note, tasks: tasks, inlineImages: inline, taskImages: images)
        }
    }

    func importNote(_ archive: NoteArchive) async throws -> Note {
        guard archive.format == "tic-note" else { throw NoteArchiveError.invalid }
        guard archive.version == 1 else { throw NoteArchiveError.unsupported }
        guard Set(archive.tasks.map(\.id)).count == archive.tasks.count,
              Set(archive.inlineImages.map(\.id)).count == archive.inlineImages.count,
              Set(archive.taskImages.map(\.taskId)).count == archive.taskImages.count else { throw NoteArchiveError.invalid }
        let markdown = archive.note.markdown as NSString
        let expression = try NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(tic-image://([0-9A-Fa-f-]+)\)"#)
        let referenced = Set(expression.matches(in: archive.note.markdown, range: NSRange(location: 0, length: markdown.length)).map { markdown.substring(with: $0.range(at: 1)) })
        guard referenced.isSubset(of: Set(archive.inlineImages.map(\.id))) else { throw NoteArchiveError.missingImage }
        return try await dbQueue.write { db in
            var note = archive.note
            let originalID = note.id
            note.id = UUID()
            note.sortIndex = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM note") ?? -1) + 1
            note.isOpen = true
            note.isCollapsed = false
            note.createdAt = Date()
            note.updatedAt = Date()
            var inlineIDs: [String: String] = [:]
            for image in archive.inlineImages { inlineIDs[image.id] = UUID().uuidString }
            for (old, new) in inlineIDs { note.markdown = note.markdown.replacingOccurrences(of: "tic-image://\(old)", with: "tic-image://\(new)") }
            try note.insert(db)
            var taskIDs: [UUID: UUID] = [:]
            for (index, original) in archive.tasks.enumerated() {
                guard original.noteId == originalID else { throw NoteArchiveError.invalid }
                var task = original
                task.id = UUID(); task.noteId = note.id; task.sortIndex = index
                taskIDs[original.id] = task.id
                try task.insert(db)
            }
            for image in archive.inlineImages {
                guard let id = inlineIDs[image.id] else { throw NoteArchiveError.invalid }
                try db.execute(sql: "INSERT INTO noteInlineImage (id,noteId,data,thumbnail) VALUES (?,?,?,?)", arguments: [id, note.id, image.data, image.thumbnail])
            }
            for image in archive.taskImages {
                guard let id = taskIDs[image.taskId] else { throw NoteArchiveError.invalid }
                try db.execute(
                    sql: "INSERT INTO taskImage (taskId,data,cropX,cropY,cropW,cropH,updatedAt) VALUES (?,?,?,?,?,?,?)",
                    arguments: [id, image.data, image.cropX, image.cropY, image.cropW, image.cropH, Date()]
                )
            }
            return note
        }
    }
}

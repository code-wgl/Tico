import Foundation
import GRDB

/// A SQLite online backup contains all tables, including images and clipboard history.
struct BackupPreferences: Codable, Sendable {
    var clipboardNoteID: String?
    var clipboardCaptureEnabled: Bool
    var appLanguage: String? = nil
    var newNoteColor: String? = nil
    var newNoteGlass: Bool? = nil
    var newNoteOpacity: Double? = nil
    var newNotePinned: Bool? = nil
    var newNoteHideCompleted: Bool? = nil
}

enum FullBackupError: LocalizedError {
    case invalid, unsupported, unsafeDestination
    var errorDescription: String? {
        switch self {
        case .invalid: AppLanguage.text("备份文件无效或已损坏。", "The backup is invalid or damaged.")
        case .unsupported: AppLanguage.text("此备份来自不兼容的版本。", "This backup is from an incompatible version.")
        case .unsafeDestination: AppLanguage.text("不能覆盖正在使用的数据库。", "The active database cannot be overwritten.")
        }
    }
}

extension AppDatabase {
    /// Uses SQLite's online backup API, not a file copy of a potentially uncheckpointed WAL.
    func writeBackup(to url: URL, preferences: BackupPreferences) throws {
        let destinationPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let activePath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard ![activePath, activePath + "-wal", activePath + "-shm", activePath + "-journal"].contains(destinationPath) else {
            throw FullBackupError.unsafeDestination
        }
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tico-backup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let destination = try DatabaseQueue(path: temporary.path)
            try dbQueue.backup(to: destination)
            let metadata = try JSONEncoder().encode(preferences)
            try destination.write { db in
                try db.execute(sql: "CREATE TABLE ticoBackupMetadata (format TEXT NOT NULL, version INTEGER NOT NULL, preferences BLOB NOT NULL)")
                try db.execute(sql: "INSERT INTO ticoBackupMetadata VALUES ('tico-backup', 1, ?)", arguments: [metadata])
            }
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: url)
        }
    }

    /// Restore copies in one transaction. IDs are remapped, so existing notes remain untouched.
    func importBackup(from url: URL) throws -> (notes: [Note], preferences: BackupPreferences, clipboardID: UUID?) {
        var config = Configuration()
        config.readonly = true
        let source = try DatabaseQueue(path: url.path, configuration: config)
        let information: (BackupPreferences, [String]) = try source.read { input in
            guard try String.fetchOne(input, sql: "PRAGMA quick_check") == "ok" else { throw FullBackupError.invalid }
            guard let row = try Row.fetchOne(input, sql: "SELECT format, version, preferences FROM ticoBackupMetadata LIMIT 1"),
                  (row["format"] as String) == "tico-backup" else { throw FullBackupError.invalid }
            guard (row["version"] as Int) == 1 else { throw FullBackupError.unsupported }
            let preferences = try JSONDecoder().decode(BackupPreferences.self, from: row["preferences"] as Data)
            return (preferences, try String.fetchAll(input, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"))
        }
        let current = try dbQueue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        guard information.1.count <= current.count,
              Array(current.prefix(information.1.count)) == information.1 else { throw FullBackupError.unsupported }
        // Migrate only an isolated copy of an older backup; never modify the user's backup file.
        let stagedURL = FileManager.default.temporaryDirectory.appendingPathComponent("tico-restore-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        do {
            let staging = try DatabaseQueue(path: stagedURL.path)
            try source.backup(to: staging)
        }
        let staging = try AppDatabase(DatabaseQueue(path: stagedURL.path))
        let preferences = information.0
        return try staging.dbQueue.read { input in
            let originals = try Note.order(Note.Columns.sortIndex).fetchAll(input)
            return try dbQueue.write { output in
                var notes: [Note] = []
                var clipboardID: UUID?
                for original in originals {
                    let archive = try Self.exportNote(id: original.id, from: input)
                    let note = try Self.importNote(archive, into: output, preserveState: true)
                    if original.id.uuidString == preferences.clipboardNoteID { clipboardID = note.id }
                    let entries = try Row.fetchAll(input, sql: "SELECT text, imageData, thumbnail, createdAt FROM clipboardEntry WHERE noteId = ?", arguments: [original.id])
                    for entry in entries {
                        let text: String = entry["text"]
                        let image: Data? = entry["imageData"]
                        let thumbnail: Data? = entry["thumbnail"]
                        let created: Date = entry["createdAt"]
                        try output.execute(
                            sql: "INSERT INTO clipboardEntry (id,noteId,text,imageData,thumbnail,createdAt) VALUES (?,?,?,?,?,?)",
                            arguments: [UUID(), note.id, text, image, thumbnail, created]
                        )
                    }
                    notes.append(note)
                }
                return (notes, preferences, clipboardID)
            }
        }
    }
}

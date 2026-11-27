import Foundation
import GRDB

/// Manages only snapshots it has recorded in its private manifest. Manual backups are never pruned.
@MainActor
final class AutoBackupService {
    enum Outcome: Equatable { case disabled, alreadyBackedUp, busy, created(URL) }
    enum Failure: LocalizedError {
        case notEnoughSpace, invalidManifest
        var errorDescription: String? {
            switch self {
            case .notEnoughSpace:
                AppLanguage.text("磁盘空间不足，自动备份未创建；已有备份未受影响。", "There is not enough disk space for an automatic backup. Existing backups were kept.")
            case .invalidManifest:
                AppLanguage.text("自动备份记录损坏，已停止自动备份以保护现有文件。", "The automatic backup manifest is damaged. Existing files were kept.")
            }
        }
    }

    private struct Entry: Codable {
        var filename: String
        var day: String
        var createdAt: Date
    }
    private struct Manifest: Codable {
        var version = 1
        var entries: [Entry] = []
    }

    private let directory: URL
    private let maximumBackups: Int
    private var running = false
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    init(directory: URL, maximumBackups: Int = 7) {
        self.directory = directory
        self.maximumBackups = max(1, maximumBackups)
    }

    /// `prepare` MUST finish the current editor, frame, settings and clipboard writes before it
    /// returns the preferences to capture. `finish` resumes any capture paused by prepare, even
    /// when preparation or writing fails. Call on launch and when the app becomes active.
    func runIfDue(enabled: Bool, database: AppDatabase, now: Date = Date(),
                  prepare: @MainActor () async throws -> BackupPreferences,
                  finish: @MainActor () -> Void) async throws -> Outcome {
        guard enabled else { return .disabled }
        guard !running else { return .busy }
        running = true
        defer { running = false }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var manifest = try loadManifest()
        let calendar = Calendar.current
        let date = calendar.dateComponents([.year, .month, .day], from: now)
        let day = "\(date.year ?? 0)-\(date.month ?? 0)-\(date.day ?? 0)"
        if manifest.entries.contains(where: { $0.day == day && fm.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }) {
            return .alreadyBackedUp
        }

        var capturePaused = true
        defer { if capturePaused { finish() } }
        let preferences = try await prepare()
        // SQLite's online backup serializes with database writes; clipboard monitoring can
        // resume while a large snapshot is being written.
        finish()
        capturePaused = false
        let filename = "tico-auto-\(UUID().uuidString).ticbackup"
        let destination = directory.appendingPathComponent(filename)
        try await Task.detached {
            // Estimate a complete standalone SQLite copy, plus a modest safety margin. On an
            // unavailable capacity estimate, SQLite still fails safely without pruning old files.
            let required = try database.dbQueue.read { db -> Int64 in
                let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                let (bytes, overflow) = pages.multipliedReportingOverflow(by: size)
                guard !overflow else { throw Failure.notEnoughSpace }
                return bytes > Int64.max - 16_777_216 ? Int64.max : bytes + 16_777_216
            }
            if let available = try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               available < required { throw Failure.notEnoughSpace }
            try database.writeBackup(to: destination, preferences: preferences)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }.value

        manifest.entries.append(Entry(filename: filename, day: day, createdAt: now))
        // Register the new snapshot before deleting anything. If this write fails, retain every
        // older file; the new unregistered snapshot can be recovered manually.
        try saveManifest(manifest)
        let sorted = manifest.entries.sorted { $0.createdAt > $1.createdAt }
        var keep = Array(sorted.prefix(maximumBackups))
        for entry in sorted.dropFirst(maximumBackups) {
            do { try fm.removeItem(at: directory.appendingPathComponent(entry.filename)) }
            catch where !fm.fileExists(atPath: directory.appendingPathComponent(entry.filename).path) { continue }
            catch { keep.append(entry) }
        }
        manifest.entries = keep
        try saveManifest(manifest)
        return .created(destination)
    }

    private func loadManifest() throws -> Manifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return Manifest() }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1,
              manifest.entries.allSatisfy({ entry in
                  entry.filename.hasPrefix("tico-auto-") && entry.filename.hasSuffix(".ticbackup") &&
                  URL(fileURLWithPath: entry.filename).lastPathComponent == entry.filename &&
                  UUID(uuidString: String(entry.filename.dropFirst("tico-auto-".count).dropLast(".ticbackup".count))) != nil
              }) else { throw Failure.invalidManifest }
        return manifest
    }

    private func saveManifest(_ manifest: Manifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }
}

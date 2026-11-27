import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Tico Backup.ticbackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "ticbackup") ?? .data]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            Task { @MainActor in
                var clipboardPaused = false
                do {
                    clipboardPaused = true
                    try await self.prepareClipboardForUpdate()
                    await self.windows.flushPendingWrites()
                    let preferences = BackupPreferences(clipboardNoteID: self.clipboardNoteID?.uuidString,
                                                        clipboardCaptureEnabled: self.clipboardCaptureEnabled)
                    var savedPreferences = preferences
                    let defaults = UserDefaults.standard
                    savedPreferences.appLanguage = defaults.string(forKey: "appLanguage")
                    savedPreferences.newNoteColor = defaults.string(forKey: "newNoteColor")
                    savedPreferences.newNoteGlass = defaults.object(forKey: "newNoteGlass") as? Bool
                    savedPreferences.newNoteOpacity = defaults.object(forKey: "newNoteOpacity") as? Double
                    savedPreferences.newNotePinned = defaults.object(forKey: "newNotePinned") as? Bool
                    savedPreferences.newNoteHideCompleted = defaults.object(forKey: "newNoteHideCompleted") as? Bool
                    let database = self.database
                    let snapshotPreferences = savedPreferences
                    self.resumeClipboardCapture()
                    clipboardPaused = false
                    try await Task.detached { try database.writeBackup(to: url, preferences: snapshotPreferences) }.value
                    let alert = NSAlert()
                    alert.messageText = AppLanguage.text("备份已保存", "Backup saved")
                    alert.informativeText = AppLanguage.text(
                        "备份包含便签、任务、图片及剪贴板内容，文件未加密，请妥善保管。",
                        "Your backup contains notes, tasks, images and clipboard contents. It is not encrypted; keep it safe."
                    )
                    alert.runModal()
                } catch {
                    if clipboardPaused { self.resumeClipboardCapture() }
                    let alert = NSAlert(error: error)
                    alert.messageText = AppLanguage.text("备份失败", "Could not save backup")
                    alert.runModal()
                }
            }
        }
    }

    func restoreBackupCopies() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ticbackup") ?? .data]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let confirmation = NSAlert()
            confirmation.messageText = AppLanguage.text("恢复为便签副本？", "Restore notes as copies?")
            confirmation.informativeText = AppLanguage.text(
                "备份中的便签会作为新副本添加。备份保存了偏好设置，但恢复时不会更改当前设置。",
                "The backup's notes will be added as copies. Preferences are saved in the backup but not applied during restore."
            )
            confirmation.addButton(withTitle: AppLanguage.text("恢复副本", "Restore Copies"))
            confirmation.addButton(withTitle: AppLanguage.text("取消", "Cancel"))
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do {
                    let database = self.database
                    let result = try await Task.detached { try database.importBackup(from: url) }.value
                    let alert = NSAlert()
                    alert.messageText = AppLanguage.text("恢复完成", "Restore complete")
                    alert.informativeText = AppLanguage.text(
                        "已添加 \(result.notes.count) 张便签副本，可在便签列表中查看。",
                        "Added \(result.notes.count) note copies. Find them in the lists menu."
                    )
                    alert.runModal()
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = AppLanguage.text("恢复失败", "Could not restore backup")
                    alert.runModal()
                }
            }
        }
    }
}

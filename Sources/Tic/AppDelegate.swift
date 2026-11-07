import AppKit
import UserNotifications

/// App lifecycle owner. As a plain SwiftPM executable (no .app bundle yet) we must explicitly
/// adopt a regular activation policy so Tic gets a Dock icon and can take foreground focus.
/// All real state lives in `AppModel.shared`; this just sequences launch and the Dock menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var newNoteKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { await AppModel.shared.bootstrap() }
        installShortcutMonitor()
        // Update banners (UpdateChecker). `current()` throws without a bundle id (swift run).
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.windows.flushPendingWrites()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// ⌘N → New Note while Tic is the active app. A menu-style `MenuBarExtra` button's
    /// `keyboardShortcut` only fires while that menu is open, so we dispatch it ourselves via a
    /// local key monitor (fires whenever any Tic window is key).
    private func installShortcutMonitor() {
        newNoteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow is NotePanel, AppModel.shared.windows.handleArrangementKey(event) { return nil }
            if event.keyCode == 53,
               event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
               let dialog = event.window as? NoteClosePanel, dialog.attachedSheet == nil {
                dialog.onCancel?()
                return nil
            }
            if let panel = NSApp.keyWindow as? NotePanel,
               event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "w" {
                panel.performClose(nil)
                return nil
            }
            // A nonactivating floating panel can have the text focus while another app owns
            // the menu bar. Route standard editing keys to that text view, not that menu.
            if NSApp.keyWindow is NotePanel, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
               !editor.hasMarkedText() {
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let key = event.charactersIgnoringModifiers?.lowercased()
                if modifiers == .command {
                    switch key {
                    case "c": editor.copy(nil); return nil
                    case "x": editor.cut(nil); return nil
                    case "v": editor.paste(nil); return nil
                    case "a": editor.selectAll(nil); return nil
                    case "z": editor.undoManager?.undo(); return nil
                    default: break
                    }
                } else if modifiers == [.command, .shift], key == "z" {
                    editor.undoManager?.redo()
                    return nil
                }
            }
            guard !(NSApp.keyWindow?.firstResponder is ShortcutCaptureButton),
                  let action = ShortcutStore.shared.action(for: event) else { return event }
            switch action {
            case .newNote: AppModel.shared.newNote()
            case .search: AppModel.shared.openSearch()
            case .settings: AppModel.shared.openSettings()
            case .addTask, .collapse, .heading, .maximize:
                guard let panel = NSApp.keyWindow as? NotePanel else { return event }
                panel.onShortcut?(action)
            }
            return nil
        }
    }

    /// Click the Dock icon with no notes on screen → open the Lists palette, so the app never
    /// looks dead after every note was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if AppModel.shared.windows.openCount == 0 { AppModel.shared.openSearch() }
        return true
    }

    /// Right-click the Dock icon → New List.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New List", action: #selector(newListFromDock), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newListFromDock() {
        AppModel.shared.newNote()
    }
}

/// Update-banner delegate: show it even while Tic is frontmost (macOS hides a frontmost app's
/// notifications by default), and a click opens the update window.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let noteID = response.notification.request.content.userInfo["ticNoteID"] as? String
        await MainActor.run {
            if let noteID, let id = UUID(uuidString: noteID) {
                Task { await AppModel.shared.windows.openNoteByID(id) }
            } else {
                AppModel.shared.openUpdate()
            }
        }
    }
}

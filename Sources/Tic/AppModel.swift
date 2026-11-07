import AppKit
import CryptoKit
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// App-wide coordinator. Bridges the SwiftUI menu bar scene and the AppKit window layer (which
/// otherwise can't reach each other): it owns the shared `AppDatabase` + `NoteWindowManager`,
/// streams the live list of notes for the menu bar, and exposes the high-level actions invoked
/// from the menu bar, the Dock menu, and a note's "+" button.
@MainActor
@Observable
final class AppModel {
    private struct ClipboardCapture: Codable {
        let noteID: UUID
        let contentHash: String
        let entryHash: String
        let entryByteCount: Int
    }
    private static let lastClipboardCaptureKey = "lastClipboardCapture"
    static let shared = AppModel()

    let database: AppDatabase
    let windows: NoteWindowManager
    let updates = UpdateChecker()
    @ObservationIgnored private let mcp: MCPService
    @ObservationIgnored private var clipboardTimer: Timer?
    @ObservationIgnored private var clipboardWrite: Task<Void, Never>?
    @ObservationIgnored private var clipboardChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var lastClipboardCapture: ClipboardCapture? = {
        guard let data = UserDefaults.standard.data(forKey: AppModel.lastClipboardCaptureKey) else { return nil }
        return try? JSONDecoder().decode(ClipboardCapture.self, from: data)
    }()
    private(set) var clipboardNoteID: UUID? = UserDefaults.standard.string(forKey: "clipboardNoteID").flatMap(UUID.init(uuidString:))
    private(set) var clipboardCaptureEnabled = UserDefaults.standard.object(forKey: "clipboardCaptureEnabled") as? Bool ?? true

    /// All saved notes (ascending `sortIndex`, i.e. creation order) — drives the menu bar list.
    /// Stays in sync as notes are created, renamed, or deleted.
    private(set) var notes: [Note] = []
    private(set) var noteIDsWithTasks: Set<UUID> = []
    var recentNotes: [Note] {
        notes.filter { note in
            if noteIDsWithTasks.contains(note.id) { return true }
            let markdown = note.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if note.id == clipboardNoteID {
                let lines = markdown.components(separatedBy: .newlines)
                let heading = (lines.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#* _\t"))
                let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty && ["", "Untitled Note", "剪贴板便签", "Clipboard Note"].contains(heading) {
                    return false
                }
            }
            if !markdown.isEmpty && markdown.range(of: #"^#{1,6}\s*$"#, options: .regularExpression) == nil {
                return true
            }
            let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return !title.isEmpty && title != "Untitled Note" && title != "Untitled List"
        }
    }

    @ObservationIgnored private var notesObservation: Task<Void, Never>?
    @ObservationIgnored private var noteTasksObservation: Task<Void, Never>?
    @ObservationIgnored private var searchWindow: NSWindow?
    @ObservationIgnored private var mcpWindow: NSWindow?
    @ObservationIgnored private var updateWindow: NSWindow?
    @ObservationIgnored private var shortcutsWindow: NSWindow?

    private init() {
        // The DB lives in Application Support; fall back to in-memory so the app still runs if
        // that can't be opened for some reason.
        guard let db = (try? AppDatabase.makeShared()) ?? (try? AppDatabase.makeInMemory()) else {
            fatalError("Tic: unable to open a database")
        }
        self.database = db
        self.windows = NoteWindowManager(appDatabase: db)
        self.mcp = MCPService(database: db)
        NSLog("[Tic] Database ready at \(db.path)")
        mcp.onConnectionCountChange = { [weak self] count in
            Task { @MainActor in self?.mcpConnections = count }
        }
        // Window pokes the MCP tools need, hopped to the main actor (the service runs off it).
        mcp.windowActions = MCPTools.WindowActions(
            open: { [weak self] id in await self?.windows.openNoteByID(id) },
            close: { [weak self] id in await self?.windows.closeNoteByID(id) },
            setFrame: { [weak self] id, rect in await self?.windows.setFrame(id, to: rect) },
            focus: { [weak self] id in await self?.windows.focusNoteByID(id) },
            appendMarkdown: { [weak self] id, content in
                await self?.windows.appendMarkdown(content, to: id) ?? false
            }
        )
    }

    /// Run once after launch: open saved note panels, then start streaming the notes list.
    func bootstrap() async {
        await windows.restoreAll()
        startObservingNotes()
        await prepareClipboardNote()
        startClipboardMonitor()
        applyLaunchAtLogin(launchAtLogin)   // honor the saved preference (effective when packaged)
        if mcpEnabled { applyMCPEnabled(true) }
        // This customised build must never replace itself with the upstream project's release.
        if Bundle.main.object(forInfoDictionaryKey: "TicUpstreamUpdatesEnabled") as? Bool != false {
            updates.start()
        }
    }

    private func prepareClipboardNote() async {
        if let id = clipboardNoteID, (try? await database.note(id: id)) != nil { return }
        guard !UserDefaults.standard.bool(forKey: "clipboardNoteInitialized") else {
            clipboardNoteID = nil
            clipboardCaptureEnabled = false
            UserDefaults.standard.set(false, forKey: "clipboardCaptureEnabled")
            return
        }
        do {
            let title = AppLanguage.text("剪贴板便签", "Clipboard Note")
            let note = try await database.insertNewNote(Note(title: title, markdown: "# \(title)"))
            clipboardNoteID = note.id
            UserDefaults.standard.set(note.id.uuidString, forKey: "clipboardNoteID")
            UserDefaults.standard.set(true, forKey: "clipboardNoteInitialized")
            windows.openNote(note, makeKey: false)
        } catch { NSLog("[Tic] clipboard note creation failed: \(error)") }
    }

    func setClipboardCaptureEnabled(_ enabled: Bool) {
        clipboardCaptureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "clipboardCaptureEnabled")
        clipboardChangeCount = NSPasteboard.general.changeCount
    }

    func setClipboardNote(_ id: UUID) {
        clipboardNoteID = id
        UserDefaults.standard.set(id.uuidString, forKey: "clipboardNoteID")
        clipboardChangeCount = NSPasteboard.general.changeCount
    }

    /// A copy originating in the designated note is already present there; consume only this
    /// pasteboard generation so a later copy from another app is still captured normally.
    func ignoreClipboardCopy(from window: NSWindow?, previousChangeCount: Int) {
        guard let panel = window as? NotePanel, panel.noteID == clipboardNoteID else { return }
        let current = NSPasteboard.general.changeCount
        if current != previousChangeCount { clipboardChangeCount = current }
    }

    private func startClipboardMonitor() {
        clipboardChangeCount = NSPasteboard.general.changeCount
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureClipboardChange() }
        }
    }

    private func captureClipboardChange() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChangeCount else { return }
        clipboardChangeCount = pasteboard.changeCount
        guard clipboardCaptureEnabled, let noteID = clipboardNoteID else { return }
        let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"]
        guard !(pasteboard.types ?? []).contains(where: { privateTypes.contains($0.rawValue) }) else { return }
        let fileOrImage = pasteboard.hasPastableImage ? pasteboard.pastableImageData() : nil
        let image: Data?
        if let fileOrImage {
            image = fileOrImage
        } else if let type = pasteboard.availableType(from: [.png, .tiff]),
                  let data = pasteboard.data(forType: type) {
            image = TaskImage.normalizedData(data)
        } else {
            image = nil
        }
        let rawText = pasteboard.string(forType: .string) ?? ""
        let text = image != nil && rawText.hasPrefix("file://") ? "" : rawText
        guard !text.isEmpty || image != nil else { return }
        // Persist only hashes, never another copy of clipboard content.
        var identity = Data(SHA256.hash(data: Data(text.utf8)))
        identity.append(image == nil ? 0 : 1)
        if let image { identity.append(contentsOf: SHA256.hash(data: image)) }
        let contentHash = Data(SHA256.hash(data: identity)).base64EncodedString()
        let previous = clipboardWrite
        clipboardWrite = Task { [self, database, windows] in
            await previous?.value
            do { try await windows.restoreClipboardTitle(for: noteID) }
            catch { NSLog("[Tic] clipboard title restore failed: \(error)") }
            let markdown = try? await windows.clipboardMarkdown(for: noteID)
            if image == nil, let markdown, let newline = markdown.firstIndex(of: "\n") {
                let body = markdown[markdown.index(after: newline)...]
                let entry = ClipboardContent.entry(text)
                if body == entry || body.hasPrefix(entry + "\n\n") { return }
            }
            if let last = lastClipboardCapture, last.noteID == noteID, last.contentHash == contentHash,
               let markdown,
               let newline = markdown.firstIndex(of: "\n") {
                let body = Data(markdown[markdown.index(after: newline)...].utf8)
                if body.count >= last.entryByteCount {
                    let entry = body.prefix(last.entryByteCount)
                    let suffix = body.dropFirst(last.entryByteCount)
                    if Data(SHA256.hash(data: entry)).base64EncodedString() == last.entryHash,
                       suffix.isEmpty || suffix.starts(with: [10, 10]) { return }
                }
            }
            let thumbnail = await Task.detached { () -> Data? in
                guard let image, let thumb = TaskImage.thumbnail(image) else { return nil }
                return TaskImage.pngData(thumb)
            }.value
            do {
                var pieces: [String] = []
                if !text.isEmpty { pieces.append(text) }
                if let image {
                    let id = UUID().uuidString
                    try await database.storeInlineImage(noteID: noteID, id: id, data: image, thumbnail: thumbnail)
                    pieces.append(ClipboardContent.imageReference(id))
                }
                let content = pieces.joined(separator: "\n")
                try await windows.prependClipboardContent(content, to: noteID)
                let entry = Data(ClipboardContent.entry(content).utf8)
                let capture = ClipboardCapture(noteID: noteID, contentHash: contentHash,
                                               entryHash: Data(SHA256.hash(data: entry)).base64EncodedString(),
                                               entryByteCount: entry.count)
                lastClipboardCapture = capture
                if let data = try? JSONEncoder().encode(capture) {
                    UserDefaults.standard.set(data, forKey: Self.lastClipboardCaptureKey)
                }
            } catch { NSLog("[Tic] clipboard capture failed: \(error)") }
        }
    }

    private func startObservingNotes() {
        notesObservation?.cancel()
        noteTasksObservation?.cancel()
        noteTasksObservation = Task { [weak self, database] in
            do {
                for try await ids in database.observeNoteIDsWithTasks() { self?.noteIDsWithTasks = Set(ids) }
            } catch { NSLog("[Tic] task note observation ended: \(error)") }
        }
        notesObservation = Task { [weak self, database] in
            do {
                for try await list in database.observeNotes() {
                    self?.notes = list
                    ReminderScheduler.shared.synchronize(list)
                }
            } catch {
                NSLog("[Tic] notes observation ended: \(error)")
            }
        }
    }

    // MARK: - Actions

    /// Create and open a fresh note (cascaded). Used by every "new list" surface.
    func newNote() {
        NSApp.activate()
        Task { await windows.newNote() }
    }

    /// Open a note (or bring it to front if already open) and activate the app.
    func open(_ note: Note) {
        windows.openNote(note)
        NSApp.activate()
    }

    /// Bring all open notes to the front.
    func showAll() {
        windows.showAll()
        NSApp.activate()
    }

    /// Permanently delete a note (and its tasks, via the FK cascade). Removed from the list
    /// immediately so it can't be reopened during the async delete; the observation confirms.
    func delete(_ note: Note) {
        if clipboardNoteID == note.id {
            setClipboardCaptureEnabled(false)
            clipboardNoteID = nil
            UserDefaults.standard.removeObject(forKey: "clipboardNoteID")
        }
        notes.removeAll { $0.id == note.id }
        Task { await windows.deleteNote(note) }
    }

}

// Window presentation and application preferences.
extension AppModel {
    /// Opens the searchable "Lists" palette — a floating, centered panel that always comes to the
    /// front when called. Reuses a single instance. (A real window, so search/delete re-render
    /// reliably, unlike the menu-bar popover.)
    func openSearch() {
        if searchWindow == nil {
            searchWindow = Self.floatingPanel(width: 700, height: 440, content: ListsSearchView())
        }
        searchWindow.map(present)
    }

    /// Import a saved Tic archive (or a UTF-8 Markdown/text document) as a separate note.
    func importNote() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.json, .plainText, .init(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = AppLanguage.text("导入", "Import")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    let data = try Data(contentsOf: url)
                    let note: Note
                    if url.pathExtension.lowercased() == "json" {
                        let archive = try JSONDecoder().decode(NoteArchive.self, from: data)
                        note = try await self.database.importNote(archive)
                    } else {
                        guard let markdown = String(data: data, encoding: .utf8) else { throw NoteArchiveError.invalid }
                        let archive = try NotePortableFormat.archive(markdown: markdown, fallbackTitle: url.deletingPathExtension().lastPathComponent)
                        note = try await self.database.importNote(archive)
                    }
                    self.windows.openNote(note)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = AppLanguage.text("导入失败", "Could not import the note")
                    alert.runModal()
                }
            }
        }
    }

    /// A borderless-looking floating panel hosting `content` — the shared shell of the Lists palette,
    /// the MCP setup window and the update window. Created once and reused.
    private static func floatingPanel(width: CGFloat, height: CGFloat, content: some View) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: LocalizedRoot { content })
        return panel
    }

    /// Brings a panel up centered on the pointer's display and on top, every time it's called.
    private func present(_ window: NSWindow) {
        centerOnActiveDisplay(window)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Dead-centre of the display the pointer is on. `NSWindow.center()` isn't that: it sits above
    /// centre, and on whichever display the reused panel was last shown.
    private func centerOnActiveDisplay(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        guard let area = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame
        else { return }
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
    }

    /// Closes the Lists palette (Escape / pick a list / its close button).
    func dismissSearch() {
        searchWindow?.orderOut(nil)
    }

    /// Opens the "AI Agents (MCP)" setup window (the toggle + per-client install snippets). A single
    /// reused, centered, floating panel — same treatment as the Lists palette.
    func openMCPSetup() {
        if mcpWindow == nil { mcpWindow = Self.floatingPanel(width: 680, height: 460, content: MCPSetupView()) }
        mcpWindow.map(present)
    }

    func dismissMCPSetup() {
        mcpWindow?.orderOut(nil)
    }

    func openSettings() {
        if shortcutsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 400)
            window.contentView = NSHostingView(rootView: LocalizedRoot { SettingsView() })
            shortcutsWindow = window
            centerOnActiveDisplay(window)
        }
        shortcutsWindow?.title = AppLanguage.text("设置", "Settings")
        shortcutsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens the update window (what's new since this version, then Update Now / Later) from the
    /// menu item or the banner. Opening it counts as having seen the update.
    func openUpdate() {
        guard updates.available != nil else { return }
        updates.markSeen()
        if updateWindow == nil { updateWindow = Self.floatingPanel(width: 460, height: 440, content: UpdateView()) }
        updateWindow.map(present)
    }

    func dismissUpdate() {
        updateWindow?.orderOut(nil)
        updates.clearFailure()
    }

    // MARK: - MCP (AI agents)

    private static let mcpEnabledKey = "mcpEnabled"

    /// Whether AI agents may drive Tic over MCP. Off by default and remembered; the socket exists
    /// only while this is on, so a client spawning `Tic --mcp` meanwhile fails fast with a hint.
    private(set) var mcpEnabled: Bool = UserDefaults.standard.bool(forKey: AppModel.mcpEnabledKey)

    /// Agents connected right now (the MCP window's status line).
    private(set) var mcpConnections = 0

    var mcpSocketPath: String { mcp.socketPath }

    func setMCPEnabled(_ enabled: Bool) {
        mcpEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.mcpEnabledKey)
        applyMCPEnabled(enabled)
    }

    private func applyMCPEnabled(_ enabled: Bool) {
        guard enabled else { return mcp.stop() }
        do {
            try mcp.start()
            NSLog("[Tic] MCP listening at \(mcp.socketPath)")
        } catch {
            NSLog("[Tic] MCP failed to start: \(error)")
            mcpEnabled = false
        }
    }

    // MARK: - Launch at login

    private static let launchAtLoginKey = "launchAtLogin"

    /// The user's "open at login" preference (drives the menu checkmark). Stored & @Observable so
    /// the menu updates the tick live; persisted so it survives relaunch. The actual `SMAppService`
    /// registration only takes effect for a packaged `.app` (a bare `swift run` executable can't
    /// be a login item).
    private(set) var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: AppModel.launchAtLoginKey)

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled   // @Observable → the menu checkmark updates immediately
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginKey)
        applyLaunchAtLogin(enabled)
    }

    /// Reconciles the actual login-item registration with the saved preference.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let status) where status != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break
            }
        } catch {
            NSLog("[Tic] Launch at Login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}

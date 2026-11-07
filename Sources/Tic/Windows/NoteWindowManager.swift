import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the live `NotePanel`s — one per note — and keeps their on-screen frames in sync with
/// the database. Acts as each panel's window delegate.
@MainActor
final class NoteWindowManager: NSObject, NSWindowDelegate {
    private let appDatabase: AppDatabase
    private var panels: [UUID: NotePanel] = [:]
    private var controllers: [UUID: NoteController] = [:]
    private var pendingFrameSaves: [UUID: Task<Void, Never>] = [:]
    /// Height a note had before it was rolled up, so it restores to the right size on expand.
    private var expandedHeights: [UUID: CGFloat] = [:]
    private var expandedWidths: [UUID: CGFloat] = [:]
    private var collapsedRestoreFrames: [UUID: (compact: CGRect, expanded: CGRect)] = [:]
    private var restoreFrames: [UUID: CGRect] = [:]
    private var changingMaximize = false
    /// Each open note's frame as saved in the DB — the last spot the user chose. Only user drags and
    /// resizes update it; a placement we or macOS make (display unplugged, launch rescue) never does,
    /// so a note parked on the laptop at home still returns to its monitor at the office.
    private var savedFrames: [UUID: CGRect] = [:]
    /// True while `place` moves a panel, so its own `windowDidMove` isn't persisted.
    private var placing = false
    /// Frame saves are dropped until this instant after a display change: macOS moves windows off a
    /// vanished display at about the same time as the notification, in either order.
    private var suppressSavesUntil = Date.distantPast
    /// The one image window, reused for whichever image was opened last.
    private var imageWindow: NSWindow?
    /// The note whose image the image window is showing, so closing that note closes it too.
    private var imageWindowNoteID: UUID?
    private var closeDialogs: [UUID: NSPanel] = [:]
    private var selectedNoteIDs: [UUID] = []
    private var selectionAnchorID: UUID?
    private var selectionOutlines: [UUID: NoteSelectionOutline] = [:]
    private var selectionEventMonitor: Any?
    private var areaSelectionPanel: NoteSelectionPanel?
    private var arrangementUndo: (before: [UUID: CGRect], after: [UUID: CGRect], undone: Bool)?

    init(appDatabase: AppDatabase) {
        self.appDatabase = appDatabase
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: - Opening notes

    /// Opens a floating panel for every note that was on screen at last quit (called at launch).
    func restoreAll() async {
        do {
            let notes = try await appDatabase.openNotes()
            for note in notes { openNote(note, makeKey: false) }   // launch: show, don't steal focus
            NSLog("[Tic] restored \(notes.count) note panel(s)")
        } catch {
            NSLog("[Tic] restoreAll failed: \(error)")
        }
    }

    /// Shows the panel for a note, creating it if necessary. `makeKey` brings it to key (so an
    /// interactive open from the menu bar focuses the note and dismisses the .window popover);
    /// pass `false` for launch restore so we don't yank focus.
    @discardableResult
    func openNote(_ note: Note, makeKey: Bool = true) -> NotePanel {
        if let existing = panels[note.id] {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        if !note.isOpen {
            Task { [appDatabase] in try? await appDatabase.updateNoteOpen(id: note.id, isOpen: true) }
        }
        let controller = NoteController(note: note, database: appDatabase)
        controllers[note.id] = controller
        controller.start()

        let panel = NotePanel(note: note, content: AnyView(LocalizedRoot { NoteView(controller: controller) }))
        panels[note.id] = panel
        savedFrames[note.id] = CGRect(x: note.frameX, y: note.frameY, width: note.frameW, height: note.frameH)

        // Live-window side effects. Weak captures so the closures never keep the panel alive
        // past close (windowWillClose nils the controller, releasing them).
        controller.onApplyBehavior = { [weak panel] floatOnTop, showOnAllSpaces in
            panel?.apply(floatOnTop: floatOnTop, showOnAllSpaces: showOnAllSpaces)
        }
        controller.onClose = { [weak panel, appDatabase] in
            // Only the user's X marks a note closed (quit doesn't), so launch restores what was visible.
            Task { try? await appDatabase.updateNoteOpen(id: note.id, isOpen: false) }
            panel?.close()   // triggers windowWillClose → teardown; does NOT delete the note
        }
        controller.onPresentCloseConfirmation = { [weak self, weak controller, weak panel] hiddenCount, done in
            guard let self, let controller, let panel else { done(); return }
            self.presentCloseConfirmation(for: controller, parent: panel, hiddenCount: hiddenCount, onDismiss: done)
        }
        controller.onSetCollapsed = { [weak self, weak panel] collapsed in
            guard let self, let panel else { return }
            self.setCollapsed(panel, collapsed: collapsed, animate: true)
        }
        controller.onNewNote = { [weak self] in
            Task { await self?.newNote() }
        }
        controller.onToggleMaximize = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.toggleMaximize(panel)
        }
        controller.onDelete = { [weak controller] in
            guard let note = controller?.note else { return }
            AppModel.shared.delete(note)
        }
        controller.onOpenImage = { [weak self, weak controller, weak panel] taskId in
            guard let self, let controller, let panel else { return }
            self.showImageWindow(controller: controller, taskId: taskId, from: panel)
        }
        panel.onPasteImage = { [weak controller] data in
            controller?.stageImage(data)
        }
        panel.onCloseConfirmation = { [weak controller] in
            controller?.requestCloseConfirmation()
        }
        panel.onSelectionClick = { [weak self] modifiers in self?.selectNote(note.id, modifiers: modifiers) }
        panel.shouldSelectWithShift = { [weak self, weak controller] in
            guard let self else { return false }
            return !self.selectedNoteIDs.isEmpty || (self.selectionAnchorID != nil && self.selectionAnchorID != note.id)
                || controller?.note.isCollapsed == true
        }
        panel.onOrdinaryClick = { [weak self] in
            self?.clearSelection()
            self?.selectionAnchorID = note.id
        }
        panel.shouldPreserveSelectionForDrag = { [weak self] in
            guard let self else { return false }
            return self.selectedNoteIDs.count > 1 && self.selectedNoteIDs.contains(note.id)
        }
        panel.onGroupDrag = { [weak self, weak panel] event in
            guard let self, let panel else { return false }
            return self.dragSelectedNotes(from: panel, event: event)
        }
        panel.onSelectionContextMenu = { [weak self, weak panel] event in
            guard let self, let panel else { return false }
            return self.showSelectionContextMenu(for: panel, event: event)
        }
        panel.onShortcut = { [weak controller] action in
            guard let controller else { return }
            switch action {
            case .addTask: controller.requestAddTask()
            case .collapse: controller.toggleCollapsed()
            case .heading: controller.requestHeading()
            case .maximize: controller.toggleMaximize()
            default: break
            }
        }
        panel.onHeaderDragEnded = { [weak self, weak panel] in
            guard let self, let panel else { return }
            if self.controllers[panel.noteID]?.note.isCollapsed != true {
                if let previous = self.collapsedRestoreFrames[panel.noteID] {
                    let expected = self.controllers[panel.noteID]?.isMaximized == true
                        ? (panel.screen ?? NSScreen.main)?.visibleFrame ?? previous.expanded
                        : previous.expanded
                    if !Self.framesMatch(panel.frame, expected) {
                        self.collapsedRestoreFrames[panel.noteID] = nil
                        self.storeCompactAnchor(nil, for: panel.noteID)
                    }
                }
                self.scheduleFrameSave(for: panel, userAction: true)
                return
            }
            if let screen = panel.screen {
                let target = Self.snappedToBottom(panel.frame, visibleFrame: screen.visibleFrame)
                if target != panel.frame { panel.setFrame(target, display: true, animate: true) }
            }
            self.scheduleFrameSave(for: panel, userAction: true)
        }
        panel.onCompactResizeEnded = { [weak self, weak panel] in
            guard let self, let panel else { return }
            if let screen = panel.screen {
                let target = Self.snappedToBottom(panel.frame, visibleFrame: screen.visibleFrame)
                if target != panel.frame { panel.setFrame(target, display: true, animate: false) }
            }
            self.rememberCompactSize(panel)
            self.scheduleFrameSave(for: panel, userAction: true)
        }

        panel.restoringPlacement = true
        place(panel)
        if !note.isCollapsed, let compact = storedCompactAnchor(note.id) {
            collapsedRestoreFrames[note.id] = (compact: compact, expanded: panel.frame)
        }
        if makeKey {
            panel.makeKeyAndOrderFront(nil)   // become key → the menu bar popover resigns/dismisses
        } else {
            panel.orderFront(nil)
        }

        // A note saved in the rolled-up state opens rolled up (keeping its expanded height).
        if note.isCollapsed {
            setCollapsed(panel, collapsed: true, animate: false, restoring: true)
        }
        panel.restoringPlacement = false
        panel.delegate = self   // only now: the placement and roll-up above aren't user moves to persist
        return panel
    }

    private func presentCloseConfirmation(for controller: NoteController, parent: NotePanel, hiddenCount: Int, onDismiss: @escaping () -> Void) {
        let id = controller.noteID
        if let existing = closeDialogs[id] { existing.makeKeyAndOrderFront(nil); return }
        let dialog = NoteClosePanel(contentRect: NSRect(x: 0, y: 0, width: 264, height: 300),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        dialog.titleVisibility = .hidden
        dialog.titlebarAppearsTransparent = true
        dialog.standardWindowButton(.closeButton)?.isHidden = true
        dialog.isFloatingPanel = true
        dialog.level = .modalPanel
        dialog.isOpaque = false
        dialog.backgroundColor = .clear
        dialog.hasShadow = true
        dialog.isReleasedWhenClosed = false
        let dismiss = { [weak self, weak dialog, weak parent] in
            guard let dialog else { return }
            parent?.removeChildWindow(dialog)
            dialog.orderOut(nil)
            self?.closeDialogs[id] = nil
            onDismiss()
        }
        dialog.onCancel = dismiss
        let content = NoteCloseConfirmationView(
            hiddenTasksCount: hiddenCount,
            onSave: { [weak self, weak controller, weak dialog] in
                guard let self, let controller, let dialog else { return }
                self.saveCopy(of: controller, from: dialog) { success in
                    if success { dismiss() }
                }
            },
            onHide: { [weak controller] in dismiss(); controller?.requestClose() },
            onDelete: { [weak controller] in dismiss(); controller?.requestDelete() },
            onCancel: dismiss
        )
        let hosting = NSHostingView(rootView: LocalizedRoot { content })
        let size = hosting.fittingSize
        dialog.setContentSize(NSSize(width: 264, height: size.height))
        dialog.contentView = hosting
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        dialog.setFrameOrigin(NSPoint(x: visible.midX - 132, y: visible.midY - size.height / 2))
        closeDialogs[id] = dialog
        parent.addChildWindow(dialog, ordered: .above)
        dialog.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func saveCopy(of controller: NoteController, from dialog: NSWindow, completion: @escaping (Bool) -> Void) {
        let save = NSSavePanel()
        save.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        save.nameFieldStringValue = (controller.note.title.isEmpty ? "Tico Note" : controller.note.title.replacingOccurrences(of: "/", with: "-")) + ".md"
        save.canCreateDirectories = true
        let formatSelector = NoteExportFormatSelector(panel: save)
        save.beginSheetModal(for: dialog) { [weak self, weak controller] response in
            guard response == .OK, let url = save.url, let self, let controller else { completion(false); return }
            let format = formatSelector.selected
            Task { @MainActor in
                do {
                    await controller.flushPendingMarkdown()
                    let archive = try await self.appDatabase.exportNote(id: controller.noteID)
                    guard archive.note.markdown == (await controller.currentClipboardMarkdown()),
                          archive.tasks == controller.tasks else { throw NoteArchiveError.unsaved }
                    try NotePortableFormat.data(for: archive, format: format).write(to: url, options: .atomic)
                    completion(true)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = AppLanguage.text("另存失败", "Could not save the note")
                    alert.runModal()
                    completion(false)
                }
            }
        }
    }

    /// Creates a fresh note (cascaded so it doesn't sit exactly on top of the last) and opens it.
    /// The DB assigns a unique, monotonic `sortIndex`; the cascade offset derives from that index
    /// (not the open-panel count), so placement and ordering stay stable after closes/deletes.
    func newNote() async {
        do {
            let defaults = UserDefaults.standard
            let chosenColor = defaults.string(forKey: "newNoteColor").flatMap(NoteColor.init(rawValue:))
                ?? NoteColor.allCases.randomElement() ?? .yellow
            let opacity = (defaults.object(forKey: "newNoteOpacity") as? NSNumber)?.doubleValue ?? 1
            let inserted = try await appDatabase.insertNewNote(
                Note(title: "Untitled Note", color: chosenColor,
                     material: defaults.bool(forKey: "newNoteGlass") ? .glass : .solid,
                     backgroundOpacity: min(1, max(0.3, opacity)), markdown: "# ",
                     floatOnTop: defaults.bool(forKey: "newNotePinned"),
                     hideCompleted: defaults.bool(forKey: "newNoteHideCompleted"))
            )
            let step = Double(inserted.sortIndex % 8) * 28
            var note = inserted
            note.frameX = 180 + step
            note.frameY = 320 - step
            try? await appDatabase.updateNoteFrame(
                id: note.id, x: note.frameX, y: note.frameY,
                width: note.frameW, height: note.frameH
            )
            openNote(note, makeKey: false)
            await focusNoteByID(note.id)
            controllers[note.id]?.requestMarkdownFocus()
        } catch {
            NSLog("[Tic] newNote failed: \(error)")
        }
    }

    /// Brings every open note to the front (menu-bar "Show All").
    func showAll() {
        for panel in panels.values { panel.orderFront(nil) }
    }

    private func selectNote(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        guard let target = panels[id] else { return }
        if modifiers.contains(.shift), let anchor = selectionAnchorID, let anchorPanel = panels[anchor],
           anchorPanel.screen == target.screen {
            let ordered = notesInReadingOrder(on: target.screen)
            if let from = ordered.firstIndex(of: anchor), let to = ordered.firstIndex(of: id) {
                let range = Array(ordered[min(from, to)...max(from, to)])
                if modifiers.contains(.command) {
                    for noteID in range where !selectedNoteIDs.contains(noteID) { selectedNoteIDs.append(noteID) }
                } else { selectedNoteIDs = range }
            }
        } else if selectedNoteIDs.contains(id) {
            selectedNoteIDs.removeAll { $0 == id }
            if selectionAnchorID == id { selectionAnchorID = selectedNoteIDs.last }
        } else {
            selectedNoteIDs.append(id)
            selectionAnchorID = id
        }
        updateSelectionOutlines()
        if !selectedNoteIDs.isEmpty {
            NSApp.activate()
            panels[id]?.makeKeyAndOrderFront(nil)
            startSelectionMonitor()
        } else { stopSelectionMonitor() }
    }

    /// Rows read from top to bottom; notes sharing a row read left to right.
    private func notesInReadingOrder(on screen: NSScreen?) -> [UUID] {
        let visible = panels.values.filter { $0.isVisible && $0.screen == screen }
            .sorted { $0.frame.maxY > $1.frame.maxY }
        var rows: [[NotePanel]] = []
        for panel in visible {
            if let index = rows.firstIndex(where: { abs(($0.first?.frame.maxY ?? 0) - panel.frame.maxY) <= 28 }) {
                rows[index].append(panel)
            } else { rows.append([panel]) }
        }
        return rows.flatMap { $0.sorted { $0.frame.minX < $1.frame.minX }.map(\.noteID) }
    }

    private func showSelectionContextMenu(for panel: NotePanel, event: NSEvent) -> Bool {
        guard selectedNoteIDs.contains(panel.noteID) else {
            if !selectedNoteIDs.isEmpty { clearSelection() }
            return false
        }
        let menu = NSMenu()
        let arrange = NSMenuItem(title: AppLanguage.text("智能整理便签", "Arrange Notes"),
                                 action: #selector(arrangeSelectionFromMenu(_:)), keyEquivalent: "")
        arrange.target = self
        let selected = selectedNoteIDs.compactMap { panels[$0] }
        arrange.isEnabled = NSScreen.screens.contains { screen in selected.filter { $0.screen == screen }.count > 1 }
        menu.autoenablesItems = false
        menu.addItem(arrange)
        menu.addItem(.separator())
        let clear = NSMenuItem(title: AppLanguage.text("取消选择", "Clear Selection"),
                               action: #selector(clearSelectionFromMenu(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        guard let view = panel.contentView else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return true
    }

    @objc private func arrangeSelectionFromMenu(_ sender: Any?) { arrangeSelectedNotes() }
    @objc private func clearSelectionFromMenu(_ sender: Any?) { clearSelection() }

    func selectNotesInArea() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        clearSelection()
        let panel = NoteSelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NoteSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.selection = { [weak self, weak panel] rect in
            guard let self else { return }
            panel?.orderOut(nil)
            self.areaSelectionPanel = nil
            if rect.width >= 3 && rect.height >= 3 {
                self.selectedNoteIDs = self.panels.values.filter { $0.isVisible && $0.frame.intersects(rect) }
                    .sorted { $0.frame.minX < $1.frame.minX }.map(\.noteID)
                self.selectionAnchorID = self.selectedNoteIDs.first
            }
            self.updateSelectionOutlines()
            if !self.selectedNoteIDs.isEmpty { self.startSelectionMonitor() }
        }
        view.cancel = { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.areaSelectionPanel = nil
            self?.clearSelection()
        }
        panel.contentView = view
        areaSelectionPanel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func updateSelectionOutlines() {
        selectedNoteIDs.removeAll { panels[$0]?.isVisible != true }
        for (id, outline) in selectionOutlines where !selectedNoteIDs.contains(id) {
            outline.removeFromSuperview()
            selectionOutlines[id] = nil
        }
        for id in selectedNoteIDs where selectionOutlines[id] == nil {
            guard let content = panels[id]?.contentView else { continue }
            let outline = NoteSelectionOutline(frame: content.bounds)
            outline.isCollapsed = controllers[id]?.note.isCollapsed == true
            outline.autoresizingMask = [.width, .height]
            content.addSubview(outline, positioned: .above, relativeTo: nil)
            selectionOutlines[id] = outline
        }
    }

    /// Selection remains active until the user chooses a context action or cancels.
    private func startSelectionMonitor() {
        guard selectionEventMonitor == nil else { return }
        selectionEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                self.clearSelection()
                return nil
            }
            return event
        }
    }

    private func stopSelectionMonitor() {
        if let monitor = selectionEventMonitor { NSEvent.removeMonitor(monitor) }
        selectionEventMonitor = nil
    }

    private func clearSelection() {
        selectedNoteIDs.removeAll()
        selectionAnchorID = nil
        updateSelectionOutlines()
        stopSelectionMonitor()
    }

    /// Move the selected panels as one unit, without changing their size or relative spacing.
    private func dragSelectedNotes(from panel: NotePanel, event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              selectedNoteIDs.count > 1, selectedNoteIDs.contains(panel.noteID) else { return false }
        let group = selectedNoteIDs.compactMap { panels[$0] }.filter(\.isVisible)
        guard group.count > 1 else { return false }
        let frames = Dictionary(uniqueKeysWithValues: group.map { ($0.noteID, $0.frame) })
        let originalAnchors = collapsedRestoreFrames
        let start = NSEvent.mouseLocation
        var moved = false
        var delta = NSPoint.zero
        while let next = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            let offset = NSPoint(x: current.x - start.x, y: current.y - start.y)
            if !moved && hypot(offset.x, offset.y) < 3 { continue }
            if !moved {
                moved = true
                arrangementUndo = nil
                for item in group where restoreFrames.removeValue(forKey: item.noteID) != nil {
                    controllers[item.noteID]?.setMaximized(false)
                }
            }
            delta = offset
            for item in group {
                guard let initial = frames[item.noteID] else { continue }
                item.setFrameOrigin(NSPoint(x: initial.minX + delta.x, y: initial.minY + delta.y))
            }
        }
        if moved {
            for item in group {
                if let anchor = originalAnchors[item.noteID], controllers[item.noteID]?.note.isCollapsed != true {
                    let compact = anchor.compact.offsetBy(dx: delta.x, dy: delta.y)
                    let expanded = anchor.expanded.offsetBy(dx: delta.x, dy: delta.y)
                    collapsedRestoreFrames[item.noteID] = (compact: compact, expanded: expanded)
                    storeCompactAnchor(compact, for: item.noteID)
                }
                scheduleFrameSave(for: item, userAction: true)
            }
        }
        return true
    }

    private func arrangeSelectedNotes() {
        let selected = selectedNoteIDs.compactMap { panels[$0] }
        clearSelection()
        guard selected.count > 1 else { return }
        var before: [UUID: CGRect] = [:]
        var after: [UUID: CGRect] = [:]
        for screen in NSScreen.screens {
            let group = selected.filter { $0.screen == screen }
            guard group.count > 1 else { continue }
            let unselectedPinned = panels.values.filter {
                $0.isVisible && $0.level == .floating && !selected.contains($0) && $0.frame.intersects(screen.visibleFrame)
            }.map(\.frame)
            guard let result = SmartNoteLayout.arrange(group.map(\.frame), in: screen.visibleFrame, avoiding: unselectedPinned) else { continue }
            for (panel, target) in zip(group, result) where panel.frame != target {
                before[panel.noteID] = panel.frame
                after[panel.noteID] = target
            }
        }
        guard !before.isEmpty else { return }
        applyArrangement(after)
        arrangementUndo = (before, after, false)
    }

    private func applyArrangement(_ frames: [UUID: CGRect]) {
        for (id, rect) in frames {
            guard let panel = panels[id] else { continue }
            if controllers[id]?.note.isCollapsed != true {
                collapsedRestoreFrames[id] = nil
                storeCompactAnchor(nil, for: id)
            }
            panel.setFrame(rect, display: true, animate: false)
            if controllers[id]?.note.isCollapsed == true { rememberCompactSize(panel) }
        }
    }

    /// Arrangement is one action across windows. A subsequent editing key returns undo to the editor.
    func handleArrangementKey(_ event: NSEvent) -> Bool {
        guard let entry = arrangementUndo else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let isUndo = key == "z" && flags == .command
        let isRedo = key == "z" && flags == [.command, .shift]
        guard isUndo || isRedo else { arrangementUndo = nil; return false }
        guard (isUndo && !entry.undone) || (isRedo && entry.undone) else { return false }
        let expected = entry.undone ? entry.before : entry.after
        guard expected.allSatisfy({ id, frame in panels[id].map { Self.framesMatch($0.frame, frame) } == true }) else {
            arrangementUndo = nil
            return false
        }
        applyArrangement(entry.undone ? entry.after : entry.before)
        arrangementUndo = (entry.before, entry.after, !entry.undone)
        return true
    }

    private func toggleMaximize(_ panel: NotePanel) {
        guard let controller = controllers[panel.noteID], let screen = panel.screen ?? NSScreen.main else { return }
        let target: CGRect
        if let previous = restoreFrames.removeValue(forKey: panel.noteID) {
            target = previous
            controller.setMaximized(false)
        } else {
            restoreFrames[panel.noteID] = panel.frame
            target = screen.visibleFrame
            controller.setMaximized(true)
        }
        changingMaximize = true
        panel.setFrame(target, display: true, animate: true)
        changingMaximize = false
    }

    /// Permanently deletes a note: closes its window if open (existing teardown), then removes
    /// the row (its tasks go with it via the FK cascade).
    func deleteNote(_ note: Note) async {
        do {
            try await appDatabase.deleteNote(id: note.id)
            panels[note.id]?.close()   // only tear down once the row is actually gone
            UserDefaults.standard.removeObject(forKey: collapsedHeightKey(note.id))
            UserDefaults.standard.removeObject(forKey: collapsedWidthKey(note.id))
            storeCompactAnchor(nil, for: note.id)
        } catch {
            NSLog("[Tic] deleteNote failed: \(error)")
        }
    }

    /// Rolls up keeping the top edge fixed; a bar at the screen bottom expands upward.
    private func setCollapsed(_ panel: NotePanel, collapsed: Bool, animate: Bool, restoring: Bool = false) {
        let id = panel.noteID
        selectionOutlines[id]?.isCollapsed = collapsed
        let current = panel.frame
        panel.isRolling = true
        let collapsedHeight = storedCollapsedHeight(id)

        let targetHeight: CGFloat
        let targetWidth: CGFloat
        let bottomAnchored = panel.screen.map {
            abs(current.minY - $0.visibleFrame.minY) <= 1
        } == true
        let beforeMaximize = collapsed ? restoreFrames.removeValue(forKey: id) : nil
        if collapsed {
            // A maximized frame is only a temporary presentation, not the size to restore
            // when the note is expanded again.
            let normalFrame = beforeMaximize ?? current
            controllers[id]?.setMaximized(false)
            expandedHeights[id] = normalFrame.height
            expandedWidths[id] = normalFrame.width
            targetHeight = collapsedHeight
            targetWidth = storedCollapsedWidth(id) ?? normalFrame.width
            panel.styleMask = NotePanel.collapsedStyle
            panel.contentMinSize = NSSize(width: NoteLayout.minimumCollapsedWidth, height: NoteLayout.minimumCollapsedHeight)
            panel.minSize = NSSize(width: NoteLayout.minimumCollapsedWidth, height: NoteLayout.minimumCollapsedHeight)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else {
            targetHeight = expandedHeights[id] ?? max(current.height, 240)
            targetWidth = max(expandedWidths[id] ?? current.width, 200)
            expandedHeights[id] = nil
            expandedWidths[id] = nil
            panel.styleMask = NotePanel.expandedStyle
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentMinSize = NSSize(width: 200, height: 160)
            panel.minSize = NSSize(width: 200, height: 160)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        // A saved collapsed frame encodes the compact bar's top edge, even when the saved
        // expanded rectangle happens to touch the screen bottom. Reconstruct that edge on launch.
        var newFrame = Self.resizedFrame(current, height: targetHeight, keepBottom: bottomAnchored && !restoring)
        newFrame.size.width = targetWidth
        if collapsed {
            if let previous = collapsedRestoreFrames.removeValue(forKey: id),
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(previous.compact) }) {
                newFrame = previous.compact
            } else if let normal = beforeMaximize {
                // Collapsing directly from maximized without a prior compact frame.
                let wasBottom = panel.screen.map { abs(normal.minY - $0.visibleFrame.minY) <= 1 } == true
                newFrame = Self.resizedFrame(normal, height: targetHeight, keepBottom: wasBottom)
                newFrame.size.width = targetWidth
            }
            storeCompactAnchor(nil, for: id)
        } else {
            if let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame {
                newFrame = Self.constrainedToVisibleFrame(newFrame, visibleFrame: visibleFrame)
                let neighboringFrames = panels.values.compactMap { other -> CGRect? in
                    guard other !== panel, other.isVisible,
                          other.frame.intersects(visibleFrame) else { return nil }
                    return other.frame
                }
                newFrame = Self.avoidingOtherNotes(newFrame, visibleFrame: visibleFrame, noteFrames: neighboringFrames)
            }
            collapsedRestoreFrames[id] = (compact: current, expanded: newFrame)
            storeCompactAnchor(current, for: id)
        }
        panel.setFrame(newFrame, display: true, animate: animate)
        panel.isRolling = false
    }

    private func collapsedHeightKey(_ id: UUID) -> String { "collapsedHeight.\(id.uuidString)" }
    private func collapsedWidthKey(_ id: UUID) -> String { "collapsedWidth.\(id.uuidString)" }
    private func compactAnchorKey(_ id: UUID) -> String { "compactAnchor.\(id.uuidString)" }

    private func storeCompactAnchor(_ frame: CGRect?, for id: UUID) {
        let key = compactAnchorKey(id)
        guard let frame else { UserDefaults.standard.removeObject(forKey: key); return }
        UserDefaults.standard.set([Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)], forKey: key)
    }

    private func storedCompactAnchor(_ id: UUID) -> CGRect? {
        guard let values = UserDefaults.standard.array(forKey: compactAnchorKey(id)) as? [Double],
              values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func storedCollapsedWidth(_ id: UUID) -> CGFloat? {
        (UserDefaults.standard.object(forKey: collapsedWidthKey(id)) as? NSNumber)
            .map { max(CGFloat($0.doubleValue), NoteLayout.minimumCollapsedWidth) }
    }

    private func storedCollapsedHeight(_ id: UUID) -> CGFloat {
        max((UserDefaults.standard.object(forKey: collapsedHeightKey(id)) as? NSNumber)
            .map { CGFloat($0.doubleValue) } ?? NoteLayout.collapsedHeight, NoteLayout.minimumCollapsedHeight)
    }

    nonisolated static func resizedFrame(_ frame: CGRect, height: CGFloat, keepBottom: Bool) -> CGRect {
        CGRect(x: frame.minX, y: keepBottom ? frame.minY : frame.maxY - height,
               width: frame.width, height: height)
    }

    nonisolated static func constrainedToVisibleFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        return CGRect(x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
                      y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
                      width: width, height: height)
    }

    /// Prefer the nearest on-screen placement that avoids other visible notes. If the display is too
    /// crowded, keep the size and choose the position with the least covered area instead.
    nonisolated static func avoidingOtherNotes(_ frame: CGRect, visibleFrame: CGRect, noteFrames: [CGRect]) -> CGRect {
        let obstacles = noteFrames.filter { $0.intersects(visibleFrame) && !$0.isEmpty }
        guard obstacles.contains(where: { $0.intersects(frame) }) else { return frame }
        let gap: CGFloat = 4
        let xCandidates = [frame.minX] + obstacles.flatMap { [$0.minX - frame.width - gap, $0.maxX + gap] }
        let yCandidates = [frame.minY] + obstacles.flatMap { [$0.minY - frame.height - gap, $0.maxY + gap] }
        var best = frame
        var bestOverlap = CGFloat.greatestFiniteMagnitude
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for x in xCandidates {
            for y in yCandidates {
                let candidate = constrainedToVisibleFrame(CGRect(x: x, y: y, width: frame.width, height: frame.height), visibleFrame: visibleFrame)
                let overlap = obstacles.reduce(CGFloat.zero) { total, obstacle in
                    let intersection = candidate.intersection(obstacle)
                    return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
                }
                let distance = abs(candidate.minX - frame.minX) + abs(candidate.minY - frame.minY)
                if overlap < bestOverlap || (overlap == bestOverlap && distance < bestDistance) {
                    best = candidate
                    bestOverlap = overlap
                    bestDistance = distance
                }
            }
        }
        return best
    }

    private nonisolated static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    /// Snap only a nearby bar that overlaps the display horizontally, including a slight overshoot.
    nonisolated static func snappedToBottom(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        guard frame.maxX > visibleFrame.minX, frame.minX < visibleFrame.maxX,
              abs(frame.minY - visibleFrame.minY) <= 24 else { return frame }
        var result = frame
        result.origin.y = visibleFrame.minY
        return result
    }

    /// Puts a panel where its saved frame says, as long as some connected display shows it; otherwise
    /// parks it on the main display (nearest edge, same size). Runs at open and on every display
    /// change, so unplugging a monitor parks its notes and plugging it back returns them to the exact
    /// spot. Frames are global coordinates spanning all displays (as Stickies stores them), and this
    /// never persists: the saved frame stays the user's.
    private func place(_ panel: NotePanel) {
        guard let saved = savedFrames[panel.noteID], let main = NSScreen.main else { return }
        let collapsedHeight = controllers[panel.noteID]?.note.isCollapsed == true
            ? storedCollapsedHeight(panel.noteID) : nil
        // Dock and menu-bar areas are still part of a connected screen. A note intentionally
        // placed there should not be treated as lost and moved to the currently active display.
        let target = Self.placement(for: saved, screens: NSScreen.screens.map(\.frame),
                                    main: main.visibleFrame, collapsedHeight: collapsedHeight,
                                    collapsedWidth: collapsedHeight == nil ? nil : storedCollapsedWidth(panel.noteID))
        let wasRestoring = panel.restoringPlacement
        panel.restoringPlacement = true
        placing = true
        if panel.styleMask.contains(.titled) {
            panel.setFrame(target, display: true, animate: false)
        } else {
            // A compact panel keeps its live height while saved holds its expanded height.
            panel.setFrameOrigin(NSPoint(x: target.minX, y: target.maxY - panel.frame.height))
        }
        placing = false
        panel.restoringPlacement = wasRestoring
    }

    /// Preserve notes that still have a reachable piece on a connected display. Otherwise move
    /// them onto the main display; the saved frame remains available if that display returns.
    nonisolated static func placement(
        for saved: CGRect, screens: [CGRect], main: CGRect, collapsedHeight: CGFloat? = nil,
        collapsedWidth: CGFloat? = nil
    ) -> CGRect {
        if let collapsedHeight {
            let bar = CGRect(x: saved.minX, y: saved.maxY - collapsedHeight,
                             width: collapsedWidth ?? saved.width, height: collapsedHeight)
            if screens.contains(where: {
                let overlap = $0.intersection(bar)
                return !overlap.isNull && overlap.width >= min(8, bar.width) && overlap.height >= min(4, bar.height)
            }) { return saved }
        }
        if collapsedHeight == nil && screens.contains(where: {
            let overlap = $0.intersection(saved)
            return !overlap.isNull && overlap.width >= min(24, saved.width) && overlap.height >= min(12, saved.height)
        }) { return saved }
        var frame = saved
        frame.origin.x = min(max(saved.minX, main.minX), main.maxX - saved.width)
        frame.origin.y = min(max(saved.minY, main.minY), main.maxY - saved.height)
        return frame
    }

    /// A display was plugged in, unplugged, or rearranged. macOS shoves windows off a vanished display
    /// onto a remaining one, which must not be saved as the user's choice: drop the moves it caused
    /// (already pending or still to come) and re-place every note from its saved frame.
    @objc private func screensDidChange() {
        // ponytail: a 2s blanket, since macOS moves windows within the same reconfiguration; a user drag
        // inside it is dropped — make it precise if that ever shows.
        suppressSavesUntil = Date().addingTimeInterval(2)
        for task in pendingFrameSaves.values { task.cancel() }
        pendingFrameSaves.removeAll()
        for panel in panels.values { place(panel) }
    }

    /// True when at least an 80×80 corner of `frame` lies on one of `screens` (enough to grab).
    nonisolated static func isVisible(_ frame: CGRect, onAnyOf screens: [CGRect]) -> Bool {
        screens.contains { screen in
            let overlap = screen.intersection(frame)
            return overlap.width >= 80 && overlap.height >= 80
        }
    }

    // MARK: - Image window

    /// Shows a task's image in the image window, creating the window on first use. It takes the note's
    /// window level, so it opens above a float-on-top note, and activates the app so it comes up in front
    /// (notes are non-activating panels).
    private func showImageWindow(controller: NoteController, taskId: UUID, from panel: NotePanel) {
        let window = imageWindow ?? ImageWindow()
        imageWindow = window
        imageWindowNoteID = controller.noteID
        let text = controller.tasks.first(where: { $0.id == taskId })?.text ?? ""
        window.title = text.split(separator: "\n").first.map(String.init) ?? "Image"
        window.contentView = NSHostingView(rootView: LocalizedRoot {
            ImageViewer(controller: controller, taskId: taskId) { [weak window] in window?.close() }
        })
        window.level = panel.level
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var openCount: Int { panels.count }

    // MARK: - Actions for external writers (MCP)

    /// Surfaces a note's panel, opening it from the DB if it wasn't on screen. Used when an agent
    /// creates a note or writes to a closed one — so the user sees the work. Uses
    /// `orderFrontRegardless` so a `.normal`-level note appears above other apps even while Tic is in
    /// the background, but does **not** activate Tic — the user's keyboard focus stays where it was.
    func openNoteByID(_ id: UUID) async {
        if let panel = panels[id] { panel.orderFrontRegardless(); return }
        guard let note = try? await appDatabase.note(id: id) else { return }
        let panel = openNote(note, makeKey: false)
        panel.orderFrontRegardless()
    }

    /// Brings a note fully to the foreground: activates Tic and makes the note key, so it lands in
    /// front and ready to type in. The explicit "jump to this note" (the `focus_note` MCP tool),
    /// stronger than `openNoteByID` — this one does take focus.
    func focusNoteByID(_ id: UUID) async {
        let panel: NotePanel
        if let existing = panels[id] {
            panel = existing
        } else if let note = try? await appDatabase.note(id: id) {
            panel = openNote(note, makeKey: false)
        } else {
            return
        }
        // A background app's plain activate() is refused by macOS focus-stealing prevention, so use
        // the assertive form (deprecated on 14 but still the only thing that reliably pulls focus
        // forward from another app). This is opt-in (focus_note / focus:true), never a plain write.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Hides a note's panel (the agent equivalent of the header X): marks it closed and closes the
    /// window if it's open. A no-op beyond the DB write when nothing is on screen.
    func closeNoteByID(_ id: UUID) async {
        try? await appDatabase.updateNoteOpen(id: id, isOpen: false)
        panels[id]?.close()   // → windowWillClose tears down the controller/panel
    }

    func prependClipboardContent(_ content: String, to id: UUID) async throws {
        if let controller = controllers[id] {
            await controller.prependClipboardContent(content)
        } else {
            try await appDatabase.prependClipboardContent(noteID: id, content: content)
        }
    }

    func appendMarkdown(_ content: String, to id: UUID) async -> Bool {
        if let controller = controllers[id] {
            await controller.appendMarkdownContent(content)
            return true
        }
        do {
            guard let note = try await appDatabase.note(id: id) else { return false }
            let separator = note.markdown.isEmpty ? "" : "\n\n"
            try await appDatabase.updateNoteMarkdown(id: id, markdown: note.markdown + separator + content, title: note.title)
            return true
        } catch { return false }
    }

    func clipboardMarkdown(for id: UUID) async throws -> String? {
        if let controller = controllers[id] { return await controller.currentClipboardMarkdown() }
        return try await appDatabase.note(id: id)?.markdown
    }

    func restoreClipboardTitle(for id: UUID) async throws {
        if let controller = controllers[id] { await controller.restoreClipboardTitle() }
        else { try await appDatabase.restoreClipboardTitle(noteID: id) }
    }

    /// Moves/resizes a note. If its panel is live, set the frame (the debounced save persists it,
    /// exactly like a user drag); otherwise persist the frame so `place` uses it when next opened.
    func setFrame(_ id: UUID, to rect: CGRect) async {
        if let panel = panels[id] {
            if controllers[id]?.note.isCollapsed != true {
                collapsedRestoreFrames[id] = nil
                storeCompactAnchor(nil, for: id)
            }
            panel.setFrame(rect, display: true, animate: false)   // fires didMove/didResize → save
            scheduleFrameSave(for: panel, userAction: true)
        } else {
            savedFrames[id] = rect
            try? await appDatabase.updateNoteFrame(
                id: id, x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height
            )
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { scheduleFrameSave(notification) }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave(notification) }

    func windowWillMove(_ notification: Notification) { clearMaximizedForUserChange(notification) }
    func windowWillStartLiveResize(_ notification: Notification) {
        clearMaximizedForUserChange(notification)
    }

    private func clearMaximizedForUserChange(_ notification: Notification) {
        guard !changingMaximize, let panel = notification.object as? NotePanel,
              restoreFrames.removeValue(forKey: panel.noteID) != nil else { return }
        controllers[panel.noteID]?.setMaximized(false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel, !panel.isRolling, !changingMaximize else { return }
        if controllers[panel.noteID]?.note.isCollapsed == true {
            rememberCompactSize(panel)
        } else if let previous = collapsedRestoreFrames[panel.noteID] {
            // Resizing changes the expanded size, not the compact position chosen by the user.
            // Refresh the comparison frame so a later header click does not discard that anchor.
            collapsedRestoreFrames[panel.noteID] = (compact: previous.compact, expanded: panel.frame)
        }
        scheduleFrameSave(for: panel, userAction: true)
    }

    private func rememberCompactSize(_ panel: NotePanel) {
        UserDefaults.standard.set(Double(panel.frame.height), forKey: collapsedHeightKey(panel.noteID))
        UserDefaults.standard.set(Double(panel.frame.width), forKey: collapsedWidthKey(panel.noteID))
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        closeDialogs.removeValue(forKey: panel.noteID)?.orderOut(nil)
        if imageWindowNoteID == panel.noteID { imageWindow?.close() }
        pendingFrameSaves[panel.noteID]?.cancel()
        pendingFrameSaves[panel.noteID] = nil
        expandedHeights[panel.noteID] = nil
        expandedWidths[panel.noteID] = nil
        collapsedRestoreFrames[panel.noteID] = nil
        restoreFrames[panel.noteID] = nil
        savedFrames[panel.noteID] = nil
        controllers[panel.noteID]?.stop()
        controllers[panel.noteID] = nil
        panels[panel.noteID] = nil
        selectedNoteIDs.removeAll { $0 == panel.noteID }
        if selectionAnchorID == panel.noteID { selectionAnchorID = selectedNoteIDs.last }
        selectionOutlines.removeValue(forKey: panel.noteID)?.removeFromSuperview()
        updateSelectionOutlines()
        if selectedNoteIDs.isEmpty { stopSelectionMonitor() }
    }

    /// Debounced frame persistence — drag/resize fire continuously, so we save only after the
    /// gesture settles (300ms idle).
    private func scheduleFrameSave(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        scheduleFrameSave(for: panel, userAction: false)
    }

    private func scheduleFrameSave(for panel: NotePanel, userAction: Bool) {
        // Not a user move: our own placement, or macOS relocating windows around a display change.
        if placing || (!userAction && Date() < suppressSavesUntil) { return }
        let id = panel.noteID
        let live = panel.frame

        // While rolled up, the window is at its collapsed height. Still persist position/width,
        // but keep the EXPANDED height in the DB and reconstruct the expanded top (collapse keeps
        // the top edge fixed) — otherwise a move/resize done while collapsed is lost on relaunch.
        let collapsed = controllers[id]?.note.isCollapsed == true
        let height = collapsed ? (expandedHeights[id] ?? live.height) : live.height
        let x = live.origin.x
        let y = collapsed ? (live.maxY - height) : live.origin.y
        let width = collapsed ? (expandedWidths[id] ?? live.width) : live.width
        savedFrames[id] = CGRect(x: x, y: y, width: width, height: height)

        pendingFrameSaves[id]?.cancel()
        pendingFrameSaves[id] = Task { [appDatabase] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            try? await appDatabase.updateNoteFrame(id: id, x: x, y: y, width: width, height: height)
        }
    }

    /// Finish debounced writes before quitting or replacing the app.
    func flushPendingWrites() async {
        let frameSaves = Array(pendingFrameSaves.values)
        let openControllers = Array(controllers.values)
        for task in frameSaves { await task.value }
        for controller in openControllers { await controller.flushPendingMarkdown() }
    }
}

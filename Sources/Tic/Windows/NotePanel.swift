import AppKit
import SwiftUI

/// A single sticky note window. A titled panel with a hidden, transparent title bar gives us
/// rounded corners, a system shadow, and edge resizing for free, while `fullSizeContentView`
/// lets the SwiftUI content cover the whole surface. `nonactivatingPanel` keeps clicking a note
/// from yanking the whole app forward — it behaves like a desktop sticky.
final class NotePanel: NSPanel {
    let noteID: UUID
    var onHeaderDragEnded: (() -> Void)?
    var onCompactResizeEnded: (() -> Void)?
    var onShortcut: ((NoteShortcutAction) -> Void)?
    var onCloseConfirmation: (() -> Void)?
    var onSelectionClick: ((NSEvent.ModifierFlags) -> Void)?
    var shouldSelectWithShift: (() -> Bool)?
    var onOrdinaryClick: (() -> Void)?
    var onSelectionContextMenu: ((NSEvent) -> Bool)?
    var shouldPreserveSelectionForDrag: (() -> Bool)?
    var onGroupDrag: ((NSEvent) -> Bool)?
    private var selectionClickInProgress = false
    var isRolling = false
    var restoringPlacement = false
    static let expandedStyle: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
    // Compact notes use our edge tracking; AppKit's resizable style imposes a much taller minimum.
    static let collapsedStyle: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

    init(note: Note, content: AnyView) {
        self.noteID = note.id

        let rect = NSRect(x: note.frameX, y: note.frameY, width: note.frameW, height: note.frameH)
        super.init(
            contentRect: rect,
            styleMask: Self.expandedStyle,
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The window is dragged only by its header (a WindowMoveArea), NOT the whole body —
        // otherwise starting a task-row drag would move the window instead of reordering.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false            // stay visible when another app is focused
        isOpaque = false
        backgroundColor = .clear             // let the SwiftUI background (incl. glass) show through
        hasShadow = true
        isReleasedWhenClosed = false         // the window manager owns the lifetime
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 200, height: 160)

        // Hide the traffic-light buttons; notes get their own controls in the header.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        apply(floatOnTop: note.floatOnTop, showOnAllSpaces: note.showOnAllSpaces)
    }

    /// Applies the float-on-top and show-on-all-Spaces behaviours to the live window.
    func apply(floatOnTop: Bool, showOnAllSpaces: Bool) {
        level = floatOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
        if showOnAllSpaces { behavior.insert(.canJoinAllSpaces) }
        collectionBehavior = behavior
    }

    /// Borderless/utility panels don't become key by default; we need it for text editing.
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        restoringPlacement ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if (modifiers == .command || (modifiers.contains(.shift) && !modifiers.contains(.option)
                && !modifiers.contains(.control) && shouldSelectWithShift?() == true)), let onSelectionClick {
                selectionClickInProgress = true
                onSelectionClick(modifiers)
                return
            }
            if modifiers.isEmpty {
                let point = contentView?.convert(event.locationInWindow, from: nil) ?? .zero
                var hit = contentView?.hitTest(point)
                var onMoveArea = false
                while let view = hit {
                    if view is WindowMoveArea.MoveView { onMoveArea = true; break }
                    hit = view.superview
                }
                // SwiftUI can return its hosting view instead of the represented move view.
                // The expanded handle occupies the top 14 points; a compact note is all handle.
                let compact = !styleMask.contains(.titled)
                if compact || event.locationInWindow.y >= contentLayoutRect.maxY - 14 {
                    onMoveArea = true
                }
                let groupSelected = shouldPreserveSelectionForDrag?() == true
                if onMoveArea && groupSelected {
                    let rect = contentView?.bounds ?? .zero
                    let vertical = min(6, max(2, rect.height * 0.32))
                    let horizontal = min(10, rect.width / 4)
                    let compactEdge = compact && (point.x <= horizontal || point.x >= rect.width - horizontal
                        || point.y <= vertical || point.y >= rect.height - vertical)
                    if event.clickCount == 1 && !compactEdge && onGroupDrag?(event) == true { return }
                } else { onOrdinaryClick?() }
            }
        }
        if selectionClickInProgress && (event.type == .leftMouseUp || event.type == .leftMouseDragged) {
            if event.type == .leftMouseUp { selectionClickInProgress = false }
            return
        }
        if event.type == .rightMouseDown, onSelectionContextMenu?(event) == true { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            // A nonactivating panel can receive a click while it is still behind another app.
            // Raise only this note and keep the event intact for editing, dragging and controls.
            if childWindows?.contains(where: { $0 is NoteClosePanel && $0.isVisible }) != true {
                orderFrontRegardless()
            }
        }
        super.sendEvent(event)
    }

    override func performClose(_ sender: Any?) {
        onCloseConfirmation?()
    }

    /// Escape may dismiss an editor popover or composition, but must not close the note.
    override func cancelOperation(_ sender: Any?) {}

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        let duration = super.animationResizeTime(newFrame)
        return isRolling ? duration * 0.5 : duration
    }

    // MARK: - Paste

    /// Hands over a pasted image, which waits in the note's quick-add. Reached when nothing in the note
    /// is being edited — a focused editor handles ⌘V itself, earlier in the responder chain. Set by
    /// `NoteWindowManager`.
    var onPasteImage: ((Data) -> Void)?

    @objc func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.pastableImageData() { onPasteImage?(data) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.hasPastableImage }
        return super.validateUserInterfaceItem(item)
    }
}

/// A separate confirmation window needs its own Escape handling; it is not a note panel.
final class NoteClosePanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

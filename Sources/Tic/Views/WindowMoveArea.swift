import SwiftUI
import AppKit

/// A transparent layer that lets the user drag the window by this region (the note's title-bar
/// handle) and reports double-clicks (for roll-up). Used because whole-window background dragging
/// is disabled on the panel — so dragging a task row reorders it instead of moving the window.
struct WindowMoveArea: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}
    var allowCompactResize = false

    func makeNSView(context: Context) -> NSView {
        MoveView(onDoubleClick: onDoubleClick, allowCompactResize: allowCompactResize)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MoveView)?.onDoubleClick = onDoubleClick
        (nsView as? MoveView)?.allowCompactResize = allowCompactResize
    }

    final class MoveView: NSView {
        var onDoubleClick: () -> Void
        var allowCompactResize: Bool {
            didSet {
                if allowCompactResize { window?.acceptsMouseMovedEvents = true }
                if allowCompactResize != oldValue { window?.invalidateCursorRects(for: self) }
            }
        }
        private var tracking: NSTrackingArea?

        init(onDoubleClick: @escaping () -> Void, allowCompactResize: Bool) {
            self.onDoubleClick = onDoubleClick
            self.allowCompactResize = allowCompactResize
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if allowCompactResize { window?.acceptsMouseMovedEvents = true }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard allowCompactResize else { return }
            let vertical = min(6, max(2, bounds.height * 0.32))
            let horizontal = min(10, bounds.width / 4)
            addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: vertical), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: 0, y: bounds.height - vertical, width: bounds.width, height: vertical), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: 0, y: 0, width: horizontal, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.width - horizontal, y: 0, width: horizontal, height: bounds.height), cursor: .resizeLeftRight)
        }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            window?.invalidateCursorRects(for: self)
        }

        override func mouseMoved(with event: NSEvent) {
            guard allowCompactResize else { return }
            let edge = compactEdges(at: convert(event.locationInWindow, from: nil))
            if edge.left || edge.right { NSCursor.resizeLeftRight.set() }
            else if edge.bottom || edge.top { NSCursor.resizeUpDown.set() }
            else { NSCursor.arrow.set() }
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

        override func mouseExited(with event: NSEvent) {
            if allowCompactResize { NSCursor.arrow.set() }
        }

        private struct CompactEdges {
            let left: Bool
            let right: Bool
            let bottom: Bool
            let top: Bool
        }

        private func compactEdges(at point: NSPoint) -> CompactEdges {
            let vertical = min(6, max(2, bounds.height * 0.32))
            let horizontal = min(10, bounds.width / 4)
            return CompactEdges(left: point.x <= horizontal, right: point.x >= bounds.width - horizontal,
                                bottom: point.y <= vertical, top: point.y >= bounds.height - vertical)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
                return
            }
            let panel = window as? NotePanel
            if allowCompactResize, let panel, resizeCompactPanel(panel, from: event) { return }
            if panel?.onGroupDrag?(event) == true { return }
            window?.performDrag(with: event)   // returns after the window-move drag loop
            panel?.onHeaderDragEnded?()
        }

        private func resizeCompactPanel(_ panel: NotePanel, from event: NSEvent) -> Bool {
            let point = convert(event.locationInWindow, from: nil)
            let edges = compactEdges(at: point)
            guard edges.left || edges.right || edges.bottom || edges.top else { return false }
            let initial = panel.frame
            let mouse = NSEvent.mouseLocation
            while let next = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let now = NSEvent.mouseLocation
                let dx = now.x - mouse.x, dy = now.y - mouse.y
                var frame = initial
                if edges.left {
                    frame.origin.x = min(initial.maxX - NoteLayout.minimumCollapsedWidth, initial.minX + dx)
                    frame.size.width = initial.maxX - frame.minX
                } else if edges.right {
                    frame.size.width = max(NoteLayout.minimumCollapsedWidth, initial.width + dx)
                }
                if edges.bottom {
                    frame.origin.y = min(initial.maxY - NoteLayout.minimumCollapsedHeight, initial.minY + dy)
                    frame.size.height = initial.maxY - frame.minY
                } else if edges.top {
                    frame.size.height = max(NoteLayout.minimumCollapsedHeight, initial.height + dy)
                }
                panel.setFrame(frame, display: true, animate: false)
            }
            panel.onCompactResizeEnded?()
            return true
        }
    }
}

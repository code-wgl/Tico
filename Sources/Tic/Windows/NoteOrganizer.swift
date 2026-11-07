import AppKit

/// A temporary screen-sized selection surface, shown only after the user chooses area selection.
final class NoteSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (contentView as? NoteSelectionView)?.cancel?() }
}

final class NoteSelectionView: NSView {
    var selection: ((CGRect) -> Void)?
    var cancel: (() -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    override var isFlipped: Bool { false }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start, let window else { cancel?(); return }
        let end = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        selection?(window.convertToScreen(rect))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()
        let hint = AppLanguage.text("拖动框选便签，右键选择整理 · Esc 取消", "Drag to select notes, then right-click to arrange · Esc to cancel") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = hint.size(withAttributes: attributes)
        let box = NSRect(x: bounds.midX - size.width / 2 - 12, y: bounds.maxY - size.height - 42,
                         width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        hint.draw(at: NSPoint(x: box.minX + 12, y: box.minY + 6), withAttributes: attributes)
        guard let start, let current else { return }
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()
    }
}

/// A non-interactive outline allows selecting a note without obscuring its contents.
final class NoteSelectionOutline: NSView {
    var isCollapsed = false { didSet { if oldValue != isCollapsed { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let radius = min(isCollapsed ? 3.5 : 12, rect.height / 2, rect.width / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

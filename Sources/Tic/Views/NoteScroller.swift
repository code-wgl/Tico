import AppKit
import SwiftUI

/// Keep the system's scrolling and hit testing, but draw a quieter, thinner thumb.
final class NoteScroller: NSScroller {
    var thumbColor: NSColor = .secondaryLabelColor
    private weak var observedClipView: NSClipView?
    private var lastOrigin: NSPoint = .zero
    private var hideWork: DispatchWorkItem?
    private var showsThumb = false
    private var trackingThumb = false

    func observeScrolling(in scroll: NSScrollView) {
        let clip = scroll.contentView
        guard observedClipView !== clip else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        observedClipView = clip
        lastOrigin = clip.bounds.origin
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        guard let clip = observedClipView, clip.bounds.origin != lastOrigin else { return }
        lastOrigin = clip.bounds.origin
        showsThumb = true
        needsDisplay = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard !trackingThumb else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.showsThumb = false
            self?.needsDisplay = true
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    override func mouseDown(with event: NSEvent) {
        trackingThumb = true
        hideWork?.cancel()
        super.mouseDown(with: event)
        trackingThumb = false
        scheduleHide()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        showsThumb ? super.hitTest(point) : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsThumb else { return }
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let bar = NSRect(x: bounds.maxX - 5, y: knob.minY + 2,
                         width: 3, height: max(0, knob.height - 4))
        thumbColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

@MainActor func styleNoteScroller(_ scroll: NSScrollView, color: Color) {
    scroll.scrollerStyle = .overlay
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let scroller: NoteScroller
    if let existing = scroll.verticalScroller as? NoteScroller {
        scroller = existing
    } else {
        scroller = NoteScroller(frame: scroll.verticalScroller?.frame ?? .zero)
        scroll.verticalScroller = scroller
    }
    scroller.thumbColor = NSColor(color)
    scroller.observeScrolling(in: scroll)
    scroller.needsDisplay = true
}

struct NoteScrollerInstaller: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> InstallerView { InstallerView() }
    func updateNSView(_ view: InstallerView, context: Context) {
        view.color = color
        view.install()
    }

    final class InstallerView: NSView {
        var color: Color = .secondary

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        func install() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                styleNoteScroller(scroll, color: self.color)
            }
        }
    }
}

struct NoteConfirmationButtonStyle: ButtonStyle {
    let primary: Bool
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(primary ? Color.white : destructive ? Color.red : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(primary ? Color.accentColor : destructive ? Color.red.opacity(0.16) : Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

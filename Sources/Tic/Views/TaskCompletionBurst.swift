import AppKit
import QuartzCore
import SwiftUI

/// A short, non-interactive celebration placed over the clicked checkbox, not over the whole note.
@MainActor
enum TaskCompletionBurst {
    static func show(in anchor: NSView, at point: NSPoint) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let content = anchor.window?.contentView else { return }
        let center = content.convert(anchor.convert(point, to: nil), from: nil)
        let size: CGFloat = 52
        let overlay = BurstOverlay(frame: NSRect(x: center.x - size / 2, y: center.y - size / 2,
                                                  width: size, height: size))
        overlay.wantsLayer = true
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        guard let root = overlay.layer else { overlay.removeFromSuperview(); return }
        let colors: [NSColor] = [.systemBlue, .systemPink, .systemOrange, .systemPurple, .systemTeal, .systemYellow]
        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            let start = CGPoint(x: size / 2, y: size / 2)
            let finish = CGPoint(x: start.x + cos(angle) * 18, y: start.y + sin(angle) * 18)
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: index.isMultiple(of: 2) ? 4 : 3, height: 4)
            dot.position = start
            dot.cornerRadius = 1.5
            dot.backgroundColor = colors[index].cgColor
            root.addSublayer(dot)

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: start)
            move.toValue = NSValue(point: finish)
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.45, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.55
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            dot.add(group, forKey: "celebrate")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak overlay] in
            overlay?.removeFromSuperview()
        }
    }

    private final class BurstOverlay: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Bridges a SwiftUI checkbox to the same transient AppKit overlay used by Markdown checkboxes.
struct TaskCompletionBurstAnchor: NSViewRepresentable {
    let trigger: Int

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        TaskCompletionBurst.show(in: view, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    func makeCoordinator() -> Coordinator { Coordinator(trigger: trigger) }

    final class Coordinator {
        var lastTrigger: Int
        init(trigger: Int) { lastTrigger = trigger }
    }
}

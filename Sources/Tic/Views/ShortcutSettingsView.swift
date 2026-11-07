import AppKit
import Observation
import SwiftUI

enum NoteShortcutAction: String, CaseIterable, Identifiable {
    case newNote, search, settings, addTask, collapse, heading, maximize
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newNote: "New note"
        case .search: "Search notes"
        case .settings: "Settings"
        case .addTask: "Add task"
        case .collapse: "Collapse or expand note"
        case .heading: "Toggle heading"
        case .maximize: "Fill screen or restore"
        }
    }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .newNote: ShortcutBinding(45, .command, "N")
        case .search: ShortcutBinding(3, [.command, .shift], "F")
        case .settings: ShortcutBinding(43, .command, ",")
        case .addTask: ShortcutBinding(17, [.command, .shift], "T")
        case .collapse: ShortcutBinding(46, [.command, .shift], "M")
        case .heading: ShortcutBinding(4, [.command, .shift], "H")
        case .maximize: ShortcutBinding(32, [.command, .shift], "U")
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt
    let keyLabel: String
    init(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
        self.keyLabel = label
    }
    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + keyLabel
    }
}

@MainActor @Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let key = "keyboardShortcuts"
    private static let supported: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    private var overrides: [String: ShortcutBinding]
    var message = ""

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            overrides = stored
        } else { overrides = [:] }
    }
    func binding(for action: NoteShortcutAction) -> ShortcutBinding {
        overrides[action.rawValue] ?? action.defaultBinding
    }
    func action(for event: NSEvent) -> NoteShortcutAction? {
        let modifiers = event.modifierFlags.intersection(Self.supported).rawValue
        return NoteShortcutAction.allCases.first {
            let binding = binding(for: $0)
            return binding.keyCode == event.keyCode && binding.modifiers == modifiers
        }
    }
    func record(_ event: NSEvent, for action: NoteShortcutAction) {
        let modifiers = event.modifierFlags.intersection(Self.supported)
        guard modifiers.contains(.command) || modifiers.contains(.control) else {
            message = "Use Command or Control with a key."
            return
        }
        let reservedCodes: Set<UInt16> = [0, 6, 7, 8, 9, 12, 13] // ⌘A/Z/X/C/V/Q/W
        if modifiers == .command && reservedCodes.contains(event.keyCode) {
            message = "That shortcut is reserved for standard editing or window actions."
            return
        }
        let label: String
        switch event.keyCode {
        case 36, 76: label = "↩"
        case 48: label = "⇥"
        case 51: label = "⌫"
        default:
            guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
                  let scalar = chars.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) else {
                message = "Choose a letter, number, punctuation, Return, Tab, or Delete."
                return
            }
            label = chars.uppercased()
        }
        let candidate = ShortcutBinding(event.keyCode, modifiers, label)
        if let other = NoteShortcutAction.allCases.first(where: {
            $0 != action && binding(for: $0).keyCode == candidate.keyCode
                && binding(for: $0).modifiers == candidate.modifiers
        }) {
            message = "Already used by \(other.title)."
            return
        }
        overrides[action.rawValue] = candidate
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: Self.key) }
        message = "Shortcut updated."
    }
    func reset() {
        overrides = [:]
        UserDefaults.standard.removeObject(forKey: Self.key)
        message = "Defaults restored."
    }
}

struct ShortcutSettingsView: View {
    private var store: ShortcutStore { .shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            Text("Click a shortcut, then press a new combination. Shortcuts work while Tico is active.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(NoteShortcutAction.allCases) { action in
                        HStack {
                            Text(LocalizedStringKey(action.title))
                            Spacer()
                            ShortcutRecorder(label: store.binding(for: action).display) { event in
                                store.record(event, for: action)
                            }.frame(width: 145, height: 26)
                        }
                    }
                }
            }
            HStack {
                Text(LocalizedStringKey(store.message)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { store.reset() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var label: String
    var onRecord: (NSEvent) -> Void
    func makeNSView(context: Context) -> ShortcutCaptureButton {
        let button = ShortcutCaptureButton()
        button.target = button
        button.action = #selector(ShortcutCaptureButton.beginRecording(_:))
        return button
    }
    func updateNSView(_ view: ShortcutCaptureButton, context: Context) {
        view.normalTitle = label
        view.onRecord = onRecord
        if !view.recording { view.title = label }
    }
}

final class ShortcutCaptureButton: NSButton {
    var normalTitle = ""
    var onRecord: ((NSEvent) -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording(_ sender: Any?) {
        window?.makeFirstResponder(self)
        recording = true
        title = "Press shortcut…"
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        recording = false
        if event.keyCode != 53 { onRecord?(event) }
        title = normalTitle
        window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func resignFirstResponder() -> Bool {
        recording = false
        title = normalTitle
        return super.resignFirstResponder()
    }
}

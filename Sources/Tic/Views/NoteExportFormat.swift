import AppKit
import UniformTypeIdentifiers

enum NoteExportFormat: Int {
    case markdown, text, json
    var fileExtension: String { switch self { case .markdown: "md"; case .text: "txt"; case .json: "json" } }
    var type: UTType { switch self { case .markdown: UTType(filenameExtension: "md") ?? .plainText; case .text: .plainText; case .json: .json } }
}

@MainActor final class NoteExportFormatSelector: NSObject {
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hint = NSTextField(wrappingLabelWithString: "")
    var selected: NoteExportFormat { NoteExportFormat(rawValue: popup.indexOfSelectedItem) ?? .markdown }

    init(panel: NSSavePanel) {
        self.panel = panel
        super.init()
        popup.addItems(withTitles: ["Markdown (.md)", "Text (.txt)", "JSON (.json)"])
        popup.target = self
        popup.action = #selector(changed)
        popup.selectItem(at: 0)
        popup.controlSize = .small
        popup.widthAnchor.constraint(equalToConstant: 165).isActive = true
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 240
        let label = NSTextField(labelWithString: AppLanguage.text("格式：", "Format:"))
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let hintIndent = NSView()
        hintIndent.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let hintRow = NSStackView(views: [hintIndent, hint])
        hintRow.orientation = .horizontal
        hintRow.alignment = .top
        hintRow.spacing = 0
        let stack = NSStackView(views: [row, hintRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 38, bottom: 6, right: 20)
        panel.accessoryView = stack
        updatePanel()
    }

    @objc private func changed() { updatePanel() }
    private func updatePanel() {
        guard let panel else { return }
        let format = selected
        panel.allowedContentTypes = [format.type]
        let name = panel.nameFieldStringValue as NSString
        let suffix = name.pathExtension.lowercased()
        let base = ["md", "txt", "json"].contains(suffix) ? name.deletingPathExtension : (name as String)
        panel.nameFieldStringValue = base + "." + format.fileExtension
        switch format {
        case .markdown: hint.stringValue = AppLanguage.text("保留文字、任务和图片；图片以嵌入方式保存。", "Keeps text, tasks, and embedded images.")
        case .text: hint.stringValue = AppLanguage.text("纯文字不包含图片和便签外观。", "Plain text omits images and appearance.")
        case .json: hint.stringValue = AppLanguage.text("完整备份，保留图片、任务和便签外观。", "Full backup, including images, tasks and appearance.")
        }
    }
}

import SwiftUI
import AppKit

/// Native macOS sidebar and grouped forms for application preferences.
struct SettingsView: View {
    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general, notes, clipboard, shortcuts, advanced, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: AppLanguage.text("通用", "General")
            case .notes: AppLanguage.text("便签", "Notes")
            case .clipboard: AppLanguage.text("剪贴板", "Clipboard")
            case .shortcuts: AppLanguage.text("键盘快捷键", "Keyboard Shortcuts")
            case .advanced: AppLanguage.text("高级", "Advanced")
            case .about: AppLanguage.text("关于", "About")
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape.fill"
            case .notes: "note.text"
            case .clipboard: "doc.on.clipboard"
            case .shortcuts: "keyboard"
            case .advanced: "slider.horizontal.3"
            case .about: "info.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .general: .gray
            case .notes: .orange
            case .clipboard: .blue
            case .shortcuts: .indigo
            case .advanced: .purple
            case .about: .teal
            }
        }
        var keywords: String {
            switch self {
            case .general: "language login 语言 登录 启动"
            case .notes: "color glass opacity pin default 颜色 毛玻璃 透明度 置顶 默认"
            case .clipboard: "copy capture note 复制 收集 便签"
            case .shortcuts: "keyboard shortcut 键盘 快捷键"
            case .advanced: "mcp agent 智能体 连接"
            case .about: "version 版本"
            }
        }
    }

    @State private var selection: SettingsSection? = .general
    @State private var search = ""
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("newNoteColor") private var newColor = "random"
    @AppStorage("newNoteGlass") private var newGlass = false
    @AppStorage("newNoteOpacity") private var newOpacity = 1.0
    @AppStorage("newNotePinned") private var newPinned = false
    @AppStorage("newNoteHideCompleted") private var newHideCompleted = false
    private var model: AppModel { .shared }
    private var shortcutStore: ShortcutStore { .shared }
    private var sections: [SettingsSection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { ($0.title + " " + $0.keywords).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SettingsSearchField(text: $search, placeholder: AppLanguage.text("搜索设置", "Search settings"))
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
                List(sections, selection: $selection) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.icon).foregroundStyle(section.tint)
                    }
                    .tag(section)
                }
                .listStyle(.sidebar)
                .overlay {
                    if sections.isEmpty {
                        Text(AppLanguage.text("没有匹配的设置", "No matching settings"))
                            .foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 205, max: 270)
        } detail: {
            if sections.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    settingsHeader
                    Form {
                        switch selection ?? .general {
                        case .general: general
                        case .notes: notes
                        case .clipboard: clipboard
                        case .shortcuts: shortcuts
                        case .advanced: advanced
                        case .about: about
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: formHeight)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.72),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle((selection ?? .general).title)
            }
        }
        .onChange(of: search) { _, _ in
            if let selected = selection, !sections.contains(selected), let first = sections.first { selection = first }
        }
    }

    private var settingsHeader: some View {
        let section = selection ?? .general
        return HStack(spacing: 13) {
            Image(systemName: section.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(section.tint)
                .frame(width: 42, height: 42)
                .background(section.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.title2.weight(.semibold))
                Text(sectionDescription(section)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var formHeight: CGFloat {
        switch selection ?? .general {
        case .general, .advanced, .clipboard: 155
        case .notes: 350
        case .shortcuts: 460
        case .about: 120
        }
    }

    private func sectionDescription(_ section: SettingsSection) -> String {
        switch section {
        case .general: AppLanguage.text("语言与启动设置", "Language and startup")
        case .notes: AppLanguage.text("新建便签的外观与行为", "Appearance and behavior for new notes")
        case .clipboard: AppLanguage.text("管理剪贴板内容收集", "Manage clipboard capture")
        case .shortcuts: AppLanguage.text("自定义常用操作的快捷键", "Customize keyboard shortcuts")
        case .advanced: AppLanguage.text("连接本机智能体", "Connect local agents")
        case .about: AppLanguage.text("应用信息", "Application information")
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            Picker(AppLanguage.text("语言", "Language"), selection: $language) {
                Text("Follow System").tag("system")
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            Toggle(AppLanguage.text("登录时启动", "Launch at login"), isOn: Binding(
                get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
        } header: {
            Text(AppLanguage.text("通用", "General"))
        }
    }

    @ViewBuilder private var notes: some View {
        Section {
            Picker(AppLanguage.text("默认颜色", "Default color"), selection: $newColor) {
                Text(AppLanguage.text("随机", "Random")).tag("random")
                ForEach(NoteColor.allCases) { color in Text(color.localizedName).tag(color.rawValue) }
            }
            Toggle(AppLanguage.text("毛玻璃背景", "Glass background"), isOn: $newGlass).toggleStyle(.switch)
            LabeledContent(AppLanguage.text("背景不透明度", "Background opacity")) {
                HStack {
                    Slider(value: $newOpacity, in: 0.3...1, step: 0.05)
                        .accessibilityLabel(Text(AppLanguage.text("背景不透明度", "Background opacity")))
                    Text("\(Int((newOpacity * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }.frame(maxWidth: 220)
            }
        } header: {
            Text(AppLanguage.text("外观", "Appearance"))
        }
        Section {
            Toggle(AppLanguage.text("新便签置顶", "Pin new notes"), isOn: $newPinned).toggleStyle(.switch)
            Toggle(AppLanguage.text("隐藏已完成任务", "Hide completed tasks"), isOn: $newHideCompleted).toggleStyle(.switch)
        } header: {
            Text(AppLanguage.text("行为", "Behavior"))
        } footer: {
            Text(AppLanguage.text("这些设置仅应用于新建便签。", "These settings apply to newly created notes."))
        }
    }

    @ViewBuilder private var clipboard: some View {
        Section {
            Picker(AppLanguage.text("剪贴板便签", "Clipboard note"), selection: Binding(
                get: { model.clipboardNoteID?.uuidString ?? "" },
                set: { if let id = UUID(uuidString: $0) { model.setClipboardNote(id) } })) {
                Text("Select a note").tag("")
                ForEach(model.notes) { note in
                    Text(verbatim: note.title.isEmpty ? "Untitled Note" : note.title).tag(note.id.uuidString)
                }
            }
            Toggle(AppLanguage.text("自动收集剪贴板", "Capture clipboard"), isOn: Binding(
                get: { model.clipboardCaptureEnabled }, set: { model.setClipboardCaptureEnabled($0) }))
                .toggleStyle(.switch).disabled(model.clipboardNoteID == nil)
        } header: {
            Text(AppLanguage.text("剪贴板", "Clipboard"))
        } footer: {
            Text(AppLanguage.text("复制的文字和图片会添加到所选便签中。", "Copied text and images are added to the selected note."))
        }
    }

    @ViewBuilder private var shortcuts: some View {
        Section {
            ForEach(NoteShortcutAction.allCases) { action in
                LabeledContent(AppLanguage.text(translation(for: action), action.title)) {
                    ShortcutRecorder(label: shortcutStore.binding(for: action).display) { shortcutStore.record($0, for: action) }
                        .frame(width: 120, height: 26)
                }
            }
        } header: {
            Text(AppLanguage.text("键盘快捷键", "Keyboard Shortcuts"))
        } footer: {
            HStack {
                Text(LocalizedStringKey(shortcutStore.message))
                Spacer()
                Button("Restore Defaults") { shortcutStore.reset() }
            }
        }
    }
    private func translation(for action: NoteShortcutAction) -> String {
        switch action {
        case .newNote: "新建便签"
        case .search: "搜索便签"
        case .settings: "设置"
        case .addTask: "添加任务"
        case .collapse: "收起或展开便签"
        case .heading: "切换标题"
        case .maximize: "放大或恢复"
        }
    }

    @ViewBuilder private var advanced: some View {
        Section {
            Toggle(AppLanguage.text("允许 MCP 连接", "Allow MCP connections"), isOn: Binding(
                get: { model.mcpEnabled }, set: { model.setMCPEnabled($0) })).toggleStyle(.switch)
            LabeledContent(AppLanguage.text("连接配置", "Connection setup")) {
                Button(AppLanguage.text("打开…", "Open…")) { model.openMCPSetup() }
            }
        } header: {
            Text("MCP")
        } footer: {
            Text(AppLanguage.text("开启后，可通过 MCP 连接本机智能体。", "Enable MCP to connect local agents."))
        }
    }

    @ViewBuilder private var about: some View {
        Section {
            LabeledContent(AppLanguage.text("版本", "Version")) {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Tico")
        }
    }
}

/// AppKit search field keeps the system search icon, clear button and keyboard behavior.
private struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField
        init(_ parent: SettingsSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}

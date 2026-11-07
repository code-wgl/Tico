import SwiftUI

/// The hover-reveal control strip + editable title for a sticky note. Controls fade in/out via
/// `isRevealed` (driven by `NoteView`'s hover over the whole note), so the affordances stay
/// hidden until the pointer is on the note — keeping the small note uncluttered.
struct NoteHeaderView: View {
    @Bindable var controller: NoteController
    let theme: NoteTheme
    let isRevealed: Bool
    var toolbarOnly = false
    var onAddTask: () -> Void = {}
    var onClose: () -> Void = {}

    @State private var showColorPopover = false
    @State private var showCompletedPopover = false
    @State private var showClearConfirm = false
    @State private var hoverClose = false
    @AppStorage("appLanguage") private var language = "system"

    private var note: Note { controller.note }

    var body: some View {
        if toolbarOnly {
            controlStrip
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        } else {
            WindowMoveArea { controller.toggleCollapsed() }
                .frame(height: 14)
                .help("Drag to move · double-click to collapse")
        }
    }

    // MARK: - Control strip

    private enum ToolbarItem: Hashable { case newNote, addTask, color, completed, clear, collapse }

    private var controlStrip: some View {
        HStack(spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 3) {
                    newNoteButton
                    addTaskButton
                    colorButton
                    completedButton
                    if controller.completedCount > 0 { clearButton }
                    collapseButton
                }.fixedSize()
                HStack(spacing: 3) {
                    newNoteButton
                    addTaskButton
                    colorButton
                    overflowMenu(shown: [.newNote, .addTask, .color])
                }.fixedSize()
                HStack(spacing: 3) {
                    colorButton
                    overflowMenu(shown: [.color])
                }.fixedSize()
                overflowMenu(shown: []).fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Rectangle().fill(theme.secondary.opacity(0.35)).frame(width: 1, height: 14)
                maximizeButton
                floatButton
                closeButton
            }.fixedSize()
        }
        .frame(height: 22)
        .animation(.easeInOut(duration: 0.15), value: isRevealed)
        .animation(.easeInOut(duration: 0.15), value: controller.completedCount > 0)
        .confirmationDialog(
            label("删除 \(controller.completedCount) 条已完成任务？此操作无法撤销。",
                  "Delete \(controller.completedCount) completed task\(controller.completedCount == 1 ? "" : "s")? "
                    + "This can't be undone."),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { controller.clearCompleted() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var addTaskButton: some View {
        iconButton(systemName: "plus.circle", isActive: false, help: shortcutHelp("添加任务", .addTask), action: onAddTask)
    }

    private func overflowMenu(shown: Set<ToolbarItem>) -> some View {
        Menu {
            if !shown.contains(.newNote) { Button(label("新建便签", "New note")) { controller.requestNewNote() } }
            if !shown.contains(.addTask) { Button(label("添加任务", "Add task"), action: onAddTask) }
            if !shown.contains(.color) {
                Menu(label("便签颜色", "Note color")) {
                    ForEach(NoteColor.allCases) { color in
                        Button(color.localizedName) { controller.setColor(color) }
                    }
                    Divider()
                    Button(note.material == .glass ? label("切换为纯色", "Switch to solid") : label("切换为玻璃效果", "Switch to glass")) { controller.toggleMaterial() }
                    Menu(label("不透明度", "Opacity")) {
                        ForEach([30, 50, 70, 85, 100], id: \.self) { value in
                            Button("\(value)%") { controller.setBackgroundOpacity(Double(value) / 100) }
                        }
                    }
                }
            }
            if !shown.contains(.completed) {
                Toggle(label("隐藏已完成任务", "Hide completed"), isOn: Binding(
                    get: { note.hideCompleted }, set: { _ in controller.toggleHideCompleted() }
                ))
                Toggle(label("已完成任务移到底部", "Move completed to bottom"), isOn: Binding(
                    get: { note.moveCompletedToBottom }, set: { _ in controller.toggleMoveCompletedToBottom() }
                ))
            }
            if controller.completedCount > 0 && !shown.contains(.clear) {
                Button(label("清理已完成任务", "Clean up completed tasks")) { showClearConfirm = true }
            }
            if !shown.contains(.collapse) { Button(label("收起便签", "Collapse")) { controller.toggleCollapsed() } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .toolbarTooltip(label("更多操作", "More actions"), trailing: true)
    }

    private var newNoteButton: some View {
        iconButton(systemName: "plus.square.on.square", isActive: false, help: shortcutHelp("新建便签", .newNote)) {
            controller.requestNewNote()
        }
    }

    private var colorButton: some View {
        Button {
            showColorPopover.toggle()
        } label: {
            Circle()
                .fill(theme.accent)
                .frame(width: 13, height: 13)
                .overlay(Circle().strokeBorder(theme.secondary.opacity(0.4), lineWidth: 1))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .toolbarTooltip(label("颜色与背景", "Color and background"))
        .popover(isPresented: $showColorPopover, arrowEdge: .bottom) { colorPicker }
    }

    private var colorPicker: some View {
        let columns = Array(repeating: GridItem(.fixed(26), spacing: 8), count: 4)
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(NoteColor.allCases) { swatch in
                    Button {
                        controller.setColor(swatch)
                    } label: {
                        Circle()
                            .fill(swatch.fill)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(
                                    swatch == note.color ? swatch.accent : Color.black.opacity(0.12),
                                    lineWidth: swatch == note.color ? 2.5 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(swatch.localizedName)
                }
            }
            Divider()
            Toggle(label("毛玻璃", "Glass"), isOn: Binding(
                get: { note.material == .glass },
                set: { enabled in if enabled != (note.material == .glass) { controller.toggleMaterial() } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            Divider()
            HStack {
                Text(label("不透明度", "Opacity"))
                Spacer()
                Text("\(Int((note.backgroundOpacity ?? 1) * 100))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            Slider(value: Binding(get: { note.backgroundOpacity ?? 1 }, set: { controller.setBackgroundOpacity($0) }),
                   in: 0.3...1, step: 0.05)
                .controlSize(.small)
                .accessibilityLabel(Text(label("不透明度", "Opacity")))
        }
        .padding(12)
    }

    private var completedButton: some View {
        let isActive = note.hideCompleted || note.moveCompletedToBottom
        return Button {
            showCompletedPopover.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? theme.accent : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolbarTooltip(label("已完成任务选项", "Completed task options"), trailing: true)
        .popover(isPresented: $showCompletedPopover, arrowEdge: .bottom) { completedOptionsMenu }
    }

    /// The two per-note display toggles. `note` is `private(set)`, so each `Toggle` writes through the
    /// controller's toggle method (the binding's incoming value is ignored — the method flips + persists).
    private var completedOptionsMenu: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(label("隐藏已完成任务", "Hide completed"), isOn: Binding(
                get: { note.hideCompleted },
                set: { _ in controller.toggleHideCompleted() }
            ))
            Toggle(label("已完成任务移到底部", "Move completed to bottom"), isOn: Binding(
                get: { note.moveCompletedToBottom },
                set: { _ in controller.toggleMoveCompletedToBottom() }
            ))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
        .tint(theme.accent)
        .padding(14)
        .frame(width: 240)
    }

    private var clearButton: some View {
        // A "tidy up" wand rather than a trash can — this clears finished items, it isn't a delete.
        iconButton(systemName: "wand.and.sparkles", isActive: false, help: label("清理已完成任务", "Clean up completed tasks")) {
            showClearConfirm = true
        }
    }

    private var collapseButton: some View {
        iconButton(systemName: "chevron.down", isActive: false, help: shortcutHelp("收起便签", .collapse)) {
            controller.toggleCollapsed()
        }
    }

    private var maximizeButton: some View {
        iconButton(systemName: controller.isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   isActive: false, help: shortcutHelp(controller.isMaximized ? "恢复大小" : "放大便签", .maximize)) {
            controller.toggleMaximize()
        }
    }

    private var floatButton: some View {
        let isFloating = note.floatOnTop
        return iconButton(
            systemName: isFloating ? "pin.fill" : "pin",
            isActive: isFloating,
            help: isFloating ? label("取消置顶", "Unpin") : label("置顶", "Keep on top")
        ) {
            controller.toggleFloatOnTop()
        }
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hoverClose ? Color.red : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverClose = $0 }
        .toolbarTooltip(label("关闭便签", "Close note"), trailing: true)
    }

    private func shortcutHelp(_ title: String, _ action: NoteShortcutAction) -> String {
        let english: String
        switch action {
        case .newNote: english = "New note"
        case .addTask: english = "Add task"
        case .collapse: english = "Collapse"
        case .maximize: english = controller.isMaximized ? "Restore size" : "Fill screen"
        default: english = action.title
        }
        return "\(label(title, english))  \(ShortcutStore.shared.binding(for: action).display)"
    }

    private func label(_ chinese: String, _ english: String) -> String {
        AppLanguage.locale(for: language).language.languageCode?.identifier == "zh" ? chinese : english
    }

    private func iconButton(
        systemName: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? theme.accent : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolbarTooltip(help, trailing: systemName.contains("arrow.") || systemName.hasPrefix("pin") || systemName == "chevron.down")
    }
}

private struct ToolbarTooltip: ViewModifier {
    let text: String
    let trailing: Bool
    @State private var hovering = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: trailing ? .topTrailing : .topLeading) {
                if visible {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .offset(y: text.contains("\n") ? -52 : -30)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(visible ? 1 : 0)
            .onHover { hovering = $0; if !$0 { visible = false } }
            .task(id: hovering) {
                guard hovering else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                visible = true
            }
            .accessibilityHint(Text(text))
    }
}

private extension View {
    func toolbarTooltip(_ text: String, trailing: Bool = false) -> some View {
        modifier(ToolbarTooltip(text: text, trailing: trailing))
    }
}

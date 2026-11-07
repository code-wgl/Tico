import SwiftUI

enum SlashCommand: String, CaseIterable, Identifiable {
    case task, heading, bullet, number, quote, code, time

    var id: String { rawValue }
    var title: String {
        switch self {
        case .task: AppLanguage.text("添加任务", "Add task")
        case .heading: AppLanguage.text("标题", "Heading")
        case .bullet: AppLanguage.text("项目列表", "Bulleted list")
        case .number: AppLanguage.text("编号列表", "Numbered list")
        case .quote: AppLanguage.text("引用", "Quote")
        case .code: AppLanguage.text("代码块", "Code block")
        case .time: AppLanguage.text("时间提醒", "Reminder")
        }
    }
    var icon: String {
        switch self {
        case .task: "checkmark.circle"
        case .heading: "textformat.size"
        case .bullet: "list.bullet"
        case .number: "list.number"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .time: "clock.badge"
        }
    }
    var replacement: String {
        switch self {
        case .task: "- [ ] "
        case .heading: "# "
        case .bullet: "- "
        case .number: "1. "
        case .quote: "> "
        case .code: "```\n\n```"
        case .time: ""
        }
    }
}

struct SlashCommandMenu: View {
    @AppStorage("appLanguage") private var language = "system"
    let commands: [SlashCommand]
    let selected: Int
    var choose: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppLanguage.locale(for: language).language.languageCode?.identifier == "zh" ? "功能" : "Commands")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 4)
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button { choose(command) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: command.icon).frame(width: 18)
                        Text(verbatim: command.title)
                        Spacer(minLength: 4)
                        Text("/\(command.rawValue)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(index == selected ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial)
    }
}

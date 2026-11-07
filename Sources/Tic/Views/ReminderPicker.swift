import SwiftUI

struct ReminderPicker: View {
    @State private var date: Date
    let save: (Date) -> Void
    let remove: (() -> Void)?

    init(date: Date = Date().addingTimeInterval(3600), save: @escaping (Date) -> Void, remove: (() -> Void)? = nil) {
        _date = State(initialValue: max(date, Date()))
        self.save = save
        self.remove = remove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLanguage.text("设置提醒时间", "Set reminder"))
                .font(.headline)
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            HStack {
                if let remove {
                    Button(AppLanguage.text("移除提醒", "Remove reminder"), action: remove)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(remove == nil ? AppLanguage.text("添加提醒", "Add reminder") : AppLanguage.text("保存", "Save")) { save(date) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

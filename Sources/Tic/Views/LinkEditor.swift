import SwiftUI

/// Small native popover for adding a Markdown link to selected text.
struct LinkEditor: View {
    @State private var address: String
    @State private var invalid = false
    @FocusState private var addressFocused: Bool
    let editing: Bool
    let save: (String) -> Void
    let cancel: () -> Void

    init(initialURL: String, editing: Bool, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _address = State(initialValue: initialURL)
        self.editing = editing
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing ? AppLanguage.text("编辑链接", "Edit Link") : AppLanguage.text("添加链接", "Add Link"))
                .font(.headline)
            TextField(AppLanguage.text("输入网址", "Enter a URL"), text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit(submit)
                .accessibilityLabel(Text(AppLanguage.text("网址", "URL")))
            if invalid {
                Text(AppLanguage.text("请输入有效的网址或邮件地址。", "Enter a valid web or email address."))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(AppLanguage.text("取消", "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(editing ? AppLanguage.text("保存", "Save") : AppLanguage.text("添加", "Add"), action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { addressFocused = true }
    }

    private func submit() {
        guard let url = normalizedAddress(address) else { invalid = true; return }
        save(url)
    }

    private func normalizedAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let candidate = trimmed.contains(":") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased(),
              let url = components.url else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else { return nil }
        } else if scheme == "mailto" {
            guard components.path.contains("@") else { return nil }
        } else { return nil }
        // Markdown uses parentheses as delimiters; preserve URLs containing them as escaped bytes.
        return url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }
}

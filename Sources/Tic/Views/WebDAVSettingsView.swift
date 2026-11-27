import SwiftUI

/// Credentials stay in Keychain; preferences contain only the endpoint and account name.
struct WebDAVSettingsView: View {
    @AppStorage("webdavURL") private var savedURL = ""
    @AppStorage("webdavUsername") private var savedUsername = ""
    @AppStorage("webdavEnabled") private var enabled = false
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    let status: String?
    let onSync: @MainActor () -> Void
    let hasConflict: Bool
    let onResolve: @MainActor () -> Void

    var body: some View {
        Section {
            TextField(AppLanguage.text("WebDAV 目录 HTTPS 地址", "WebDAV directory HTTPS URL"), text: $url)
                .textContentType(.URL)
            TextField(AppLanguage.text("用户名", "Username"), text: $username)
                .textContentType(.username)
            SecureField(AppLanguage.text("密码或应用专用密码", "Password or app-specific password"), text: $password)
            Text(AppLanguage.text(
                "密码安全保存在系统钥匙串；修改地址或账号时请重新输入密码。",
                "Your password is stored in Keychain. Re-enter it when changing the address or account."
            ))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(AppLanguage.text("验证并保存", "Verify and Save")) { verifyAndSave() }
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            Toggle(AppLanguage.text("启用云同步", "Enable Cloud Sync"), isOn: $enabled)
                .disabled(savedURL.isEmpty || savedUsername.isEmpty || busy)
            Text(AppLanguage.text(
                "启用后，所有便签、任务和图片都会上传到此 WebDAV；剪贴板便签可能包含敏感内容。请只使用可信的私人服务器。",
                "When enabled, all notes, tasks and images are uploaded to this WebDAV server. " +
                "Clipboard notes may contain sensitive content. Use only a trusted private server."
            ))
                .font(.caption).foregroundStyle(.secondary)
            Text(AppLanguage.text(
                "传输使用 HTTPS，但云端内容未端到端加密，服务器可读取。" +
                "应用会定期上传；为保护正在编辑的内容，接收更改需要关闭便签或重启应用。",
                "HTTPS protects data in transit, but the server can read stored content. " +
                "Changes upload periodically; close notes or restart the app to receive updates safely."
            ))
                .font(.caption).foregroundStyle(.secondary)
            Text(AppLanguage.text(
                "同步功能仍在测试中，建议保留本地备份。遇到冲突时可选择版本，其他内容会保存为副本。",
                "Sync is experimental; keep a local backup. " +
                "When a conflict occurs, choose a version and the other content is preserved as a copy."
            ))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(AppLanguage.text("立即同步", "Sync Now")) { onSync() }
                    .disabled(!enabled || busy)
                if hasConflict {
                    Button(AppLanguage.text("解决冲突", "Resolve Conflict")) { onResolve() }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        } header: {
            Text(AppLanguage.text("WebDAV 云同步", "WebDAV Cloud Sync"))
        }
        .onAppear { url = savedURL; username = savedUsername }
    }

    private func verifyAndSave() {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputPassword = password
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let endpoint = URL(string: address) else { throw WebDAVError.invalidConfiguration }
                let configuration = try WebDAVConfiguration(baseURL: endpoint, username: account)
                let secret: String
                if inputPassword.isEmpty {
                    guard address == savedURL, account == savedUsername, let stored = try WebDAVCredentials.load() else {
                        throw WebDAVError.missingPassword
                    }
                    secret = stored
                } else { secret = inputPassword }
                let client = try WebDAVClient(configuration: configuration, password: secret)
                try await client.verifyAuthentication()
                try WebDAVCredentials.save(secret)
                if address != savedURL || account != savedUsername { enabled = false }
                savedURL = address
                savedUsername = account
                password = ""
                message = AppLanguage.text("连接验证成功。开启同步后才会上传数据。", "Connection verified. Data is uploaded only after sync is enabled.")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

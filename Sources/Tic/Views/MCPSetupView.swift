import AppKit
import SwiftUI

/// The "AI Agents (MCP)" setup window: a master toggle with live status on top, a client list on the
/// left, and the selected client's copy-paste install snippet on the right. Built like the Lists
/// palette (an NSPanel hosting SwiftUI, owned by `AppModel`). All install snippets spawn the same
/// `Tic --mcp`, so this is really just presenting one command nine ways.
struct MCPSetupView: View {
    @State private var model = AppModel.shared
    @State private var selection: String
    @State private var copied = false
    @AppStorage("appLanguage") private var language = "system"

    private let executablePath: String
    private let clients: [MCPClient]
    private let inApplications: Bool

    init() {
        let exe = Bundle.main.executableURL?.path ?? "Tic"
        executablePath = exe
        clients = MCPClients.all(executablePath: exe)
        inApplications = (Bundle.main.bundleURL.path.hasPrefix("/Applications"))
        _selection = State(initialValue: clients.first?.id ?? "")
    }

    private var selectedClient: MCPClient {
        clients.first { $0.id == selection } ?? clients[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                clientList
                Divider().opacity(0.5)
                detail
            }
        }
        .frame(width: 680, height: 460)
        .background(.regularMaterial)
        .ignoresSafeArea()               // else the hidden title bar leaves a blank strip on top
        .onExitCommand { model.dismissMCPSetup() }
    }

    // MARK: - Header: title, toggle, status

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Agents (MCP)").font(.system(size: 17, weight: .semibold))
                    Text("Let Claude, Cursor and friends draft and tick your lists.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.dismissMCPSetup() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).help("Close (Esc)")
            }
            HStack(spacing: 12) {
                Toggle("Enable MCP server", isOn: Binding(
                    get: { model.mcpEnabled },
                    set: { model.setMCPEnabled($0) }
                ))
                .toggleStyle(.switch)
                Spacer()
                statusBadge
            }
        }
        .padding(18)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(model.mcpEnabled ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(statusText).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        let chinese = AppLanguage.locale(for: language).language.languageCode?.identifier == "zh"
        guard model.mcpEnabled else { return chinese ? "已关闭" : "Off" }
        let n = model.mcpConnections
        return chinese ? (n == 0 ? "运行中 · 无连接" : "运行中 · \(n) 个连接")
                       : (n == 0 ? "Running · no agents connected" : "Running · \(n) connected")
    }

    // MARK: - Client list

    private var clientList: some View {
        List(clients, selection: $selection) { client in
            Text(client.name).tag(client.id)
        }
        .listStyle(.sidebar)
        .frame(width: 190)
    }

    // MARK: - Detail: snippet + actions

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(selectedClient.detail)).font(.callout).foregroundStyle(.secondary)

            ScrollView {
                Text(selectedClient.snippet)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                if let link = selectedClient.deeplink {
                    Button { open(link) } label: { Label("Add to \(selectedClient.name)", systemImage: "arrow.down.app") }
                        .buttonStyle(.borderedProminent)
                }
                Button { copy() } label: {
                    Label(LocalizedStringKey(copied ? "Copied" : "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                if let path = selectedClient.configPath {
                    Button { openConfig(path) } label: { Label("Open config file", systemImage: "folder") }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }

            if !inApplications {
                Label("Tico isn't in /Applications — this command's path changes if you move the app.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: selection) { _, _ in copied = false }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedClient.snippet, forType: .string)
        copied = true
    }

    /// Opens a client install deeplink (Cursor / VS Code).
    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    /// Opens the client's config file, or reveals its folder in Finder if the file doesn't exist yet.
    private func openConfig(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: expanded) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}

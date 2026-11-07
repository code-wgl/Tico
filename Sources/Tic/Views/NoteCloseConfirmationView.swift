import SwiftUI

/// Sized independently of the note so the choices remain usable even for very narrow notes.
struct NoteCloseConfirmationView: View {
    let hiddenTasksCount: Int
    let onSave: () -> Void
    let onHide: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 38, height: 38)
                .padding(.bottom, 12)
            Text(AppLanguage.text("关闭这个便签？", "Close this note?"))
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 6)
            Text(AppLanguage.text("隐藏后可从最近记录重新打开；删除会永久移除便签及任务。", "Hidden notes can be reopened from Recents. Deleting permanently removes the note and its tasks."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, hiddenTasksCount > 0 ? 7 : 12)
            if hiddenTasksCount > 0 {
                Text(AppLanguage.text("仍有 \(hiddenTasksCount) 条已完成任务被隐藏，删除时会一并移除。", "\(hiddenTasksCount) completed task(s) are hidden and will also be deleted."))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }
            VStack(spacing: 6) {
                action(AppLanguage.text("隐藏", "Hide"), color: .accentColor, foreground: .white, action: onHide)
                action(AppLanguage.text("删除便签", "Delete Note"), color: Color.red.opacity(0.18), foreground: .red, action: onDelete)
                action(AppLanguage.text("另存为…", "Save As…"), color: Color.primary.opacity(0.08), foreground: .primary, action: onSave)
                action(AppLanguage.text("取消", "Cancel"), color: Color.primary.opacity(0.08), foreground: .primary, action: onCancel)
            }
        }
        .padding(16)
        .frame(width: 264, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.35)))
        .onExitCommand(perform: onCancel)
    }

    private func action(_ title: String, color: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(foreground)
                .frame(maxWidth: .infinity).frame(height: 29)
                .background(color, in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

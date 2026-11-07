import CryptoKit
import Foundation
import UserNotifications

/// Reminders are plain, editable text in Markdown; the scheduler mirrors them into macOS.
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    private let prefix = "tic-reminder-"
    private var lastContent: [UUID: String] = [:]
    private var pendingUpdate: Task<Void, Never>?

    static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        return formatter
    }

    func synchronize(_ notes: [Note]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.markdown) })
        guard content != lastContent else { return }
        lastContent = content
        let previous = pendingUpdate
        pendingUpdate = Task {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let requests = await center.pendingNotificationRequests()
            let old = requests.filter { $0.identifier.hasPrefix(prefix) }
            var desired: [String: (Date, String, UUID)] = [:]
            guard let regex = try? NSRegularExpression(pattern: #"⏰\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"#) else {
                NSLog("[Tic] invalid reminder expression")
                return
            }
            let formatter = Self.formatter()
            for note in notes {
                var inCode = false
                for (index, line) in note.markdown.components(separatedBy: "\n").enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
                    guard !inCode, line.range(of: #"^\s*[-*+] \[[xX]\]"#, options: .regularExpression) == nil else { continue }
                    let text = line as NSString
                    for match in regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
                        guard let date = formatter.date(from: text.substring(with: match.range(at: 1))), date > Date() else { continue }
                        let identity = "\(note.id.uuidString):\(index):\(match.range.location):\(line)"
                        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                        let body = text.replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        desired[prefix + digest] = (date, body.isEmpty ? note.title : body, note.id)
                    }
                }
            }
            let obsolete = old.map(\.identifier).filter { desired[$0] == nil }
            center.removePendingNotificationRequests(withIdentifiers: obsolete)
            let existing = Set(old.map(\.identifier))
            for (identifier, (date, text, noteID)) in desired where !existing.contains(identifier) {
                let content = UNMutableNotificationContent()
                content.title = AppLanguage.text("便签提醒", "Note Reminder")
                content.body = text
                content.sound = .default
                content.userInfo = ["ticNoteID": noteID.uuidString]
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                do { try await center.add(UNNotificationRequest(identifier: identifier, content: content,
                              trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))) }
                catch { NSLog("[Tic] reminder scheduling failed: \(error)") }
            }
        }
    }
}

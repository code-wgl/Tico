import SwiftUI

enum AppLanguage {
    static func locale(for setting: String) -> Locale {
        switch setting {
        case "zh-Hans": Locale(identifier: "zh-Hans")
        case "en": Locale(identifier: "en")
        default:
            Locale(identifier: (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh") ? "zh-Hans" : "en")
        }
    }

    static var isChinese: Bool {
        let setting = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        return locale(for: setting).language.languageCode?.identifier == "zh"
    }

    static func text(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }
}

struct LocalizedRoot<Content: View>: View {
    @AppStorage("appLanguage") private var language = "system"
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().environment(\.locale, AppLanguage.locale(for: language))
    }
}

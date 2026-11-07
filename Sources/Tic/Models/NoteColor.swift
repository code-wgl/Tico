import SwiftUI

/// The colour theme of a sticky note. Stored as its raw string in SQLite, mapped to concrete
/// SwiftUI colours here so the rest of the app stays theme-agnostic.
enum NoteColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case pink
    case blue
    case green
    case purple
    case graphite
    case orange
    case coral
    case mint
    case teal
    case cream
    case white

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    /// Explicitly resolve the selected app language, including in detached popovers.
    var localizedName: String {
        switch self {
        case .yellow: AppLanguage.text("黄色", "Yellow")
        case .pink: AppLanguage.text("粉色", "Pink")
        case .blue: AppLanguage.text("蓝色", "Blue")
        case .green: AppLanguage.text("绿色", "Green")
        case .purple: AppLanguage.text("紫色", "Purple")
        case .graphite: AppLanguage.text("石墨色", "Graphite")
        case .orange: AppLanguage.text("橙色", "Orange")
        case .coral: AppLanguage.text("珊瑚色", "Coral")
        case .mint: AppLanguage.text("薄荷色", "Mint")
        case .teal: AppLanguage.text("青绿色", "Teal")
        case .cream: AppLanguage.text("奶油色", "Cream")
        case .white: AppLanguage.text("白色", "White")
        }
    }

    // MARK: - Paper

    /// The note's paper fill (used for solid notes and as a faint tint behind glass).
    var fill: Color {
        switch self {
        case .yellow:   return Color(red: 1.00, green: 0.90, blue: 0.46)
        case .pink:     return Color(red: 1.00, green: 0.78, blue: 0.84)
        case .blue:     return Color(red: 0.70, green: 0.86, blue: 1.00)
        case .green:    return Color(red: 0.76, green: 0.93, blue: 0.74)
        case .purple:   return Color(red: 0.84, green: 0.79, blue: 0.97)
        case .graphite: return Color(red: 0.86, green: 0.87, blue: 0.90)
        case .orange: return Color(red: 1.00, green: 0.83, blue: 0.67)
        case .coral: return Color(red: 1.00, green: 0.76, blue: 0.73)
        case .mint: return Color(red: 0.75, green: 0.93, blue: 0.85)
        case .teal: return Color(red: 0.69, green: 0.91, blue: 0.92)
        case .cream: return Color(red: 0.98, green: 0.94, blue: 0.79)
        case .white: return Color(red: 0.96, green: 0.96, blue: 0.97)
        }
    }

    /// A deeper shade of the theme for soft accents (title underline, quick-add bar tint).
    var accent: Color {
        switch self {
        case .yellow:   return Color(red: 0.78, green: 0.62, blue: 0.10)
        case .pink:     return Color(red: 0.82, green: 0.36, blue: 0.50)
        case .blue:     return Color(red: 0.18, green: 0.48, blue: 0.78)
        case .green:    return Color(red: 0.26, green: 0.58, blue: 0.30)
        case .purple:   return Color(red: 0.46, green: 0.36, blue: 0.74)
        case .graphite: return Color(red: 0.40, green: 0.42, blue: 0.46)
        case .orange: return Color(red: 0.75, green: 0.39, blue: 0.16)
        case .coral: return Color(red: 0.78, green: 0.33, blue: 0.31)
        case .mint: return Color(red: 0.24, green: 0.59, blue: 0.43)
        case .teal: return Color(red: 0.17, green: 0.53, blue: 0.56)
        case .cream: return Color(red: 0.65, green: 0.53, blue: 0.29)
        case .white: return Color(red: 0.47, green: 0.49, blue: 0.54)
        }
    }

    // MARK: - Solid-note inks (tuned per theme)
    //
    // Each ink is a deep, slightly-desaturated tone of the hue rather than one flat near-black.
    // A hue-matched deep tone reads crisper on its pastel than pure black while clearing WCAG AA.

    private var solidTitleInk: Color {
        switch self {
        case .yellow, .orange, .cream: return Color(red: 0.20, green: 0.16, blue: 0.02)
        case .pink, .coral: return Color(red: 0.30, green: 0.10, blue: 0.16)
        case .blue, .teal: return Color(red: 0.06, green: 0.16, blue: 0.30)
        case .green, .mint: return Color(red: 0.08, green: 0.22, blue: 0.10)
        case .purple:   return Color(red: 0.20, green: 0.12, blue: 0.36)
        case .graphite, .white: return Color(red: 0.10, green: 0.11, blue: 0.14)
        }
    }

    private var solidTaskInk: Color {
        switch self {
        case .yellow, .orange, .cream: return Color(red: 0.24, green: 0.19, blue: 0.04)
        case .pink, .coral: return Color(red: 0.27, green: 0.12, blue: 0.17)
        case .blue, .teal: return Color(red: 0.08, green: 0.18, blue: 0.32)
        case .green, .mint: return Color(red: 0.10, green: 0.24, blue: 0.12)
        case .purple:   return Color(red: 0.22, green: 0.14, blue: 0.38)
        case .graphite, .white: return Color(red: 0.14, green: 0.15, blue: 0.18)
        }
    }

    /// Secondary / placeholder / empty-state text. Muting is baked in — do NOT add extra opacity.
    private var solidSecondaryInk: Color {
        switch self {
        case .yellow, .orange, .cream: return Color(red: 0.42, green: 0.35, blue: 0.12)
        case .pink, .coral: return Color(red: 0.50, green: 0.28, blue: 0.34)
        case .blue, .teal: return Color(red: 0.24, green: 0.36, blue: 0.50)
        case .green, .mint: return Color(red: 0.26, green: 0.40, blue: 0.26)
        case .purple:   return Color(red: 0.40, green: 0.32, blue: 0.55)
        case .graphite, .white: return Color(red: 0.40, green: 0.42, blue: 0.47)
        }
    }

    private var solidCompletedInk: Color {
        switch self {
        case .yellow, .orange, .cream: return Color(red: 0.46, green: 0.40, blue: 0.20)
        case .pink, .coral: return Color(red: 0.55, green: 0.34, blue: 0.40)
        case .blue, .teal: return Color(red: 0.34, green: 0.45, blue: 0.58)
        case .green, .mint: return Color(red: 0.36, green: 0.48, blue: 0.36)
        case .purple:   return Color(red: 0.48, green: 0.42, blue: 0.62)
        case .graphite, .white: return Color(red: 0.48, green: 0.50, blue: 0.55)
        }
    }

    private var solidCheckbox: Color {
        switch self {
        case .yellow, .orange, .cream: return Color(red: 0.78, green: 0.62, blue: 0.10)
        case .pink, .coral: return Color(red: 0.78, green: 0.30, blue: 0.45)
        case .blue, .teal: return Color(red: 0.13, green: 0.42, blue: 0.72)
        case .green, .mint: return Color(red: 0.18, green: 0.50, blue: 0.24)
        case .purple:   return Color(red: 0.42, green: 0.30, blue: 0.72)
        case .graphite, .white: return Color(red: 0.30, green: 0.40, blue: 0.78)
        }
    }

    // MARK: - Role resolution (solid vs glass)
    //
    // Glass uses semantic, appearance-adaptive system colours (they invert over light/dark
    // backdrops and ride the material's vibrancy); solid uses the tuned inks above.

    enum Surface { case solid, glass }
    enum InkRole { case title, task, secondary, completed, checkbox }

    func color(_ role: InkRole, on surface: Surface) -> Color {
        switch surface {
        case .solid:
            switch role {
            case .title:     return solidTitleInk
            case .task:      return solidTaskInk
            case .secondary: return solidSecondaryInk
            case .completed: return solidCompletedInk
            case .checkbox:  return solidCheckbox
            }
        case .glass:
            switch role {
            case .title:     return .primary
            case .task:      return .primary
            case .secondary: return .secondary
            case .completed: return .secondary
            case .checkbox:  return accent   // stays chromatic so the theme is still identifiable
            }
        }
    }
}

/// A resolved palette for a note, so views ask for a role (`theme.task`) without branching on
/// whether the note is solid or glass.
struct NoteTheme: Equatable {
    let color: NoteColor
    let surface: NoteColor.Surface

    var isGlass: Bool { surface == .glass }

    var fill: Color { color.fill }
    var accent: Color { color.accent }
    var title: Color { color.color(.title, on: surface) }
    var task: Color { color.color(.task, on: surface) }
    var secondary: Color { color.color(.secondary, on: surface) }
    var completed: Color { color.color(.completed, on: surface) }
    var checkbox: Color { color.color(.checkbox, on: surface) }
}

import SwiftUI
import Testing
@testable import Tic

@Suite("NoteColor")
struct NoteColorTests {
    @Test("provides the supported themes")
    func cases() {
        #expect(Set(NoteColor.allCases.map(\.rawValue)) == Set([
            "yellow", "pink", "blue", "green", "purple", "graphite",
            "orange", "coral", "mint", "teal", "cream", "white"
        ]))
    }

    @Test("solid surface resolves distinct, tuned inks per role")
    func solidRoles() {
        let color = NoteColor.yellow
        #expect(color.color(.title, on: .solid) != color.color(.secondary, on: .solid))
        #expect(color.color(.task, on: .solid) != color.color(.completed, on: .solid))
    }

    @Test("glass surface falls back to adaptive system colors")
    func glassRoles() {
        let color = NoteColor.blue
        #expect(color.color(.title, on: .glass) == .primary)
        #expect(color.color(.task, on: .glass) == .primary)
        #expect(color.color(.secondary, on: .glass) == .secondary)
    }
}

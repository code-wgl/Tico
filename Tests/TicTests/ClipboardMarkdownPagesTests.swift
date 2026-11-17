import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Tic

@Suite("Clipboard note paging")
struct ClipboardMarkdownPagesTests {
    @Test("pages cover the original note without omitting or duplicating content")
    func roundTrip() throws {
        let text = "# Clipboard\n" + String(repeating: "item 🧑🏽‍💻 and text\n---\n", count: 2_000)
        let source = text as NSString
        var range = try #require(ClipboardMarkdownPages.first(in: text))
        var joined = ""
        repeat {
            joined += source.substring(with: range)
            if NSMaxRange(range) == source.length { break }
            let following = ClipboardMarkdownPages.next(in: text, from: NSMaxRange(range))
            #expect(following.location == NSMaxRange(range))
            #expect(following.length > 0)
            range = following
        } while true
        #expect(joined == text)
    }

    @Test("a long line is divided only at composed character boundaries")
    func emojiBoundary() throws {
        let text = String(repeating: "🧑🏽‍💻", count: 5_000)
        let first = try #require(ClipboardMarkdownPages.first(in: text))
        let source = text as NSString
        #expect(source.substring(with: first) + source.substring(from: NSMaxRange(first)) == text)
        #expect(NSMaxRange(first) == NSMaxRange(source.rangeOfComposedCharacterSequence(at: NSMaxRange(first) - 1)))
        let second = ClipboardMarkdownPages.next(in: text, from: NSMaxRange(first))
        let previous = ClipboardMarkdownPages.previous(in: text, before: second.location)
        #expect(NSMaxRange(previous) == second.location)
    }

    @Test("editing a page leaves content and inline image references outside it intact")
    func editPage() throws {
        let text = "# Clipboard\n" + String(repeating: "entry\n---\n", count: 4_000)
            + "![image](tic-image://ABCD-1234)\nlast item"
        let first = try #require(ClipboardMarkdownPages.first(in: text))
        let second = ClipboardMarkdownPages.next(in: text, from: NSMaxRange(first))
        let source = text as NSString
        let edited = ClipboardMarkdownPages.replacing(second, in: text, with: "Edited 📝\n")
        #expect(edited == source.substring(to: second.location) + "Edited 📝\n" + source.substring(from: NSMaxRange(second)))
        #expect(edited.hasSuffix("![image](tic-image://ABCD-1234)\nlast item"))
    }

    @Test("a clipboard capture before an older segment preserves that segment and the new capture")
    func captureWhileViewingOlderPage() throws {
        let old = "# Clipboard\n" + String(repeating: "record 📝\n---\n", count: 3_000)
        let first = try #require(ClipboardMarkdownPages.first(in: old))
        let page = ClipboardMarkdownPages.next(in: old, from: NSMaxRange(first))
        let new = ClipboardContent.prepending("new capture", to: old)
        let adjusted = MarkdownEditingTextView.adjustSelection(page, from: old, to: new)
        let oldText = (old as NSString).substring(with: page)
        #expect((new as NSString).substring(with: adjusted) == oldText)
        let edited = ClipboardMarkdownPages.replacing(adjusted, in: new, with: "edited older segment\n")
        #expect(edited.contains("new capture"))
        #expect(edited.hasSuffix((new as NSString).substring(from: NSMaxRange(adjusted))))
    }

    @Test("clipboard capture during composition keeps the pending input and bounds later pages")
    func captureDuringComposition() throws {
        let old = "# Clipboard\n" + (0..<5_000).map { "entry-\($0)\n" }.joined()
        let oldRange = try #require(ClipboardMarkdownPages.first(in: old))
        let oldPage = (old as NSString).substring(with: oldRange)
        let newer = ClipboardContent.prepending("new capture", to: old)
        let expanded = try #require(ClipboardMarkdownPages.afterExternalChange(
            oldRange, old: old, new: newer, composing: true
        ))
        let target = (newer as NSString).substring(with: expanded)
        let local = (oldPage as NSString).replacingCharacters(in: NSRange(location: 100, length: 0), with: "COMPOSED")
        let merged = MarkdownEditingTextView.mergeExternalChange(base: oldPage, target: target, local: local)
        #expect(merged.contains("COMPOSED"))
        #expect(merged.contains("new capture"))
        let full = ClipboardMarkdownPages.replacing(expanded, in: newer, with: merged)
        #expect(full.hasSuffix((newer as NSString).substring(from: NSMaxRange(expanded))))
        let bounded = try #require(ClipboardMarkdownPages.afterExternalChange(
            NSRange(location: 0, length: (merged as NSString).length), old: full, new: full, composing: false
        ))
        #expect(bounded.length <= ClipboardMarkdownPages.pageSize + 1)
    }

    @Test("a capture crossing the paging threshold retains the current editor during an image paste")
    func captureCrossesPagingThresholdDuringImage() throws {
        let old = "# Clipboard\n" + String(repeating: "text\n", count: 1_500)
        #expect(ClipboardMarkdownPages.first(in: old) == nil)
        let newer = ClipboardContent.prepending(String(repeating: "new\n", count: 2_000), to: old)
        let originalRange = NSRange(location: 0, length: (old as NSString).length)
        let expanded = try #require(ClipboardMarkdownPages.afterExternalChange(
            originalRange, old: old, new: newer, composing: true
        ))
        #expect(expanded.location == 0)
        #expect(expanded.length == (newer as NSString).length)
        #expect(ClipboardMarkdownPages.first(in: newer) != nil)
    }

    @MainActor
    @Test("changing segments clears the editor's own undo and redo history")
    func segmentUndoIsolation() throws {
        _ = NSApplication.shared
        let view = MarkdownEditingTextView(frame: .zero)
        let undo = try #require(view.undoManager)
        let coordinator = MarkdownNoteEditor(text: .constant("first"), textColor: .black).makeCoordinator()
        var oldPageUndoCount = 0
        undo.registerUndo(withTarget: view) { _ in oldPageUndoCount += 1 }
        #expect(undo.canUndo)
        coordinator.prepareSegment(view, generation: 1)
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)
        undo.undo()
        #expect(oldPageUndoCount == 0)
        var newPageUndoCount = 0
        undo.registerUndo(withTarget: view) { _ in newPageUndoCount += 1 }
        undo.undo()
        #expect(newPageUndoCount == 1)
    }
}

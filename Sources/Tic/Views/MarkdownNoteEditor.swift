import AppKit
import SwiftUI
import UserNotifications
import Markdown

private struct MarkdownTableVisual {
    let rows: [NSRange]
    let columnWidths: [CGFloat]
    let allRows: [NSRange]
    let cells: [[NSRange]]
    let sticky: Bool
    let stickyMarker: NSRange?
}

private struct MarkdownTableInsertionHandle: Equatable {
    let anchor: Int
    let action: String
    let center: NSPoint
    let lineStart: NSPoint
    let lineEnd: NSPoint
}

private let stickyTableMarker = "<!-- tic:sticky-header -->"

private struct OrderedListMarker {
    let marker: NSRange
    let digits: NSRange
    let number: Int
    let depth: Int
    let group: Int
    let delimiter: String

    var label: String {
        switch depth % 3 {
        case 1:
            var n = number
            var value = ""
            while n > 0 {
                n -= 1
                value = String(UnicodeScalar(97 + n % 26)!) + value
                n /= 26
            }
            return value + delimiter
        case 2:
            guard number > 0 && number < 4000 else { return "\(number)" + delimiter }
            var remaining = number
            var result = ""
            for (value, symbol) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
                while remaining >= value { result += symbol; remaining -= value }
            }
            return result + delimiter
        default: return "\(number)" + delimiter
        }
    }
}

/// Resolve numbering independently for each parent, while keeping Markdown numeric on disk.
private func orderedListMarkers(in source: NSString) -> [OrderedListMarker] {
    guard source.length > 0 else { return [] }
    var fence = MarkdownFenceScanner()
    var stack: [(indent: Int, ordered: Bool, number: Int)] = []
    var group = 0
    var result: [OrderedListMarker] = []
    source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
        guard let line else { return }
        if fence.consume(line) { stack.removeAll(); group += 1; return }
        guard !fence.isInside else { return }
        let text = line as NSString
        guard let match = MarkdownEditingTextView.listLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else {
            stack.removeAll(); group += 1; return
        }
        let indent = match.range(at: 1).length
        let raw = text.substring(with: match.range(at: 2))
        let ordered = Int(raw.dropLast()) != nil
        while let last = stack.last, last.indent > indent { stack.removeLast() }
        if let last = stack.last, last.indent == indent {
            if last.ordered == ordered {
                if ordered { stack[stack.count - 1].number += 1 }
            } else {
                stack[stack.count - 1] = (indent, ordered, 1)
            }
        } else {
            // Preserve an intentionally chosen starting number for a top-level list.
            let start = stack.isEmpty && ordered ? (Int(raw.dropLast()) ?? 1) : 1
            stack.append((indent, ordered, start))
        }
        guard ordered, let item = stack.last else { return }
        let marker = NSRange(location: range.location + indent, length: match.range.length - indent)
        let digits = NSRange(location: range.location + match.range(at: 2).location, length: match.range(at: 2).length - 1)
        result.append(OrderedListMarker(marker: marker, digits: digits, number: item.number, depth: stack.count - 1, group: group, delimiter: String(raw.suffix(1))))
    }
    return result
}

/// Tracks matching CommonMark fenced-code delimiters without confusing a shorter or
/// differently shaped fence inside the code with its closing delimiter.
private struct MarkdownFenceScanner {
    private var open: (character: Character, count: Int)?
    var isInside: Bool { open != nil }

    mutating func consume(_ line: String) -> Bool {
        let spaces = line.prefix(while: { $0 == " " }).count
        guard spaces <= 3 else { return false }
        let text = line.dropFirst(spaces)
        guard let first = text.first, first == "`" || first == "~" else { return false }
        let count = text.prefix(while: { $0 == first }).count
        guard count >= 3 else { return false }
        let rest = text.dropFirst(count)
        if let open {
            guard open.character == first, count >= open.count,
                  rest.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            self.open = nil
        } else {
            guard first != "`" || !rest.contains("`") else { return false }
            open = (first, count)
        }
        return true
    }
}

enum MarkdownInlineFormat: Equatable {
    case bold, italic, boldItalic, strikethrough, code
    var marker: String {
        switch self {
        case .bold: "**"
        case .italic: "*"
        case .boldItalic: "***"
        case .strikethrough: "~~"
        case .code: "`"
        }
    }
}

/// Editable Markdown source rendered inline without a separate preview screen.
struct MarkdownNoteEditor: NSViewRepresentable {
    @Binding var text: String
    var textColor: Color
    var paperColor: Color = .white
    var inlineImages: [String: Data] = [:]
    var focusRequest = 0
    var taskInsertRequest = 0
    var separateCompletedTasks = false
    var hideCompletedTasks = false
    var trackAnimatedContentHeight = false
    var onFocusHandled: () -> Void = {}
    var onAddTask: () -> Void = {}
    var onPasteImage: (Data, @escaping (String, Data) -> Void) -> Void = { _, _ in }
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownEditorScrollView()
        scroll.onContentHeightChange = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onContentHeightChange($0)
        }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        styleNoteScroller(scroll, color: textColor)
        let view = MarkdownEditingTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        _ = view.layoutManager
        view.drawsBackground = false
        view.isRichText = true
        view.allowsUndo = true
        // Markdown delimiters and embedded HTML must stay byte-for-byte stable.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 4, height: 2)
        view.delegate = context.coordinator
        view.separateCompletedTasks = separateCompletedTasks
        view.hideCompletedTasks = hideCompletedTasks
        view.trackAnimatedContentHeight = trackAnimatedContentHeight
        view.refreshTaskStyle = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.applyStyle(to: view)
            (view.enclosingScrollView as? MarkdownEditorScrollView)?.reportContentHeight()
        }
        view.onAddTask = { [weak coordinator = context.coordinator] in coordinator?.parent.onAddTask() }
        view.onPasteImage = { [weak coordinator = context.coordinator] data, completion in
            coordinator?.parent.onPasteImage(data, completion)
        }
        view.setMarkdownSource(text, images: inlineImages)
        scroll.documentView = view
        context.coordinator.applyStyle(to: view)
        scroll.reportContentHeight()
        context.coordinator.focusIfRequested(view)
        context.coordinator.insertTaskIfRequested(view)
        if separateCompletedTasks { DispatchQueue.main.async { [weak view] in view?.separateAllTaskGroups() } }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        styleNoteScroller(scroll, color: textColor)
        guard let view = scroll.documentView as? MarkdownEditingTextView else { return }
        let startSeparating = separateCompletedTasks && !view.separateCompletedTasks
        view.separateCompletedTasks = separateCompletedTasks
        view.hideCompletedTasks = hideCompletedTasks
        view.trackAnimatedContentHeight = trackAnimatedContentHeight
        let current = view.markdownSource()
        if view.hasMarkedText(), current != text {
            if context.coordinator.pendingExternal == nil {
                context.coordinator.pendingExternal = (context.coordinator.lastCommittedSource, text)
            } else {
                context.coordinator.pendingExternal?.target = text
            }
        } else if current != text || view.knownImageIDs != Set(inlineImages.keys) {
            let selection = view.sourceSelection()
            let adjusted = MarkdownEditingTextView.adjustSelection(selection, from: current, to: text)
            view.setMarkdownSource(text, images: inlineImages)
            view.setSourceSelection(adjusted)
            context.coordinator.lastCommittedSource = text
        }
        context.coordinator.applyStyle(to: view)
        (scroll as? MarkdownEditorScrollView)?.reportContentHeight()
        context.coordinator.focusIfRequested(view)
        context.coordinator.insertTaskIfRequested(view)
        if startSeparating { DispatchQueue.main.async { [weak view] in view?.separateAllTaskGroups() } }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        private static let inlinePatterns: [(NSRegularExpression, MarkdownInlineFormat)] = [
            (#"`([^`\n]+)`"#, .code),
            (#"(?<!\\)(?<!\*)\*\*\*([^*\n]+)\*\*\*(?!\*)"#, .boldItalic),
            (#"(?<![\\\w_])___([^_\n]+)___(?![\w_])"#, .boldItalic),
            (#"(?<![\\*])\*\*([^*\n]+)\*\*(?!\*)"#, .bold),
            (#"(?<![\\\w_])__([^_\n]+)__(?![\w_])"#, .bold),
            (#"(?<![\\*])\*([^*\n]+)\*(?!\*)"#, .italic),
            (#"(?<![\\\w_])_([^_\n]+)_(?![\w_])"#, .italic),
            (#"(?<!\\)~~([^~\n]+)~~"#, .strikethrough)
        ].compactMap { pattern, format in (try? NSRegularExpression(pattern: pattern)).map { ($0, format) } }
        private static let linkPattern = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^\s)]+|mailto:[^\s)]+)\)"#)
        var parent: MarkdownNoteEditor
        var lastFocusRequest = 0
        var lastTaskInsertRequest = 0
        var lastCommittedSource: String
        var pendingExternal: (base: String, target: String)?
        private var taskCaretAdjustmentScheduled = false
        private var adjustingTaskCaret = false
        init(_ parent: MarkdownNoteEditor) { self.parent = parent; self.lastCommittedSource = parent.text }

        func focusIfRequested(_ view: MarkdownEditingTextView) {
            if parent.focusRequest == 0 { lastFocusRequest = 0; return }
            guard parent.focusRequest != lastFocusRequest else { return }
            lastFocusRequest = parent.focusRequest
            view.requestFocusWhenReady { [weak self] in self?.parent.onFocusHandled() }
        }

        func insertTaskIfRequested(_ view: MarkdownEditingTextView) {
            guard parent.taskInsertRequest != lastTaskInsertRequest else { return }
            lastTaskInsertRequest = parent.taskInsertRequest
            DispatchQueue.main.async { [weak view] in view?.insertMarkdownTask() }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? MarkdownEditingTextView else { return }
            guard !view.isApplyingCompletionFrame else { return }
            guard !view.hasMarkedText() else { return }
            let sortAfterEdit = !view.isTogglingCompletion && view.cancelCompletionAnimationForEdit()
            var source = view.markdownSource()
            if let pending = pendingExternal {
                pendingExternal = nil
                let merged = MarkdownEditingTextView.mergeExternalChange(base: pending.base, target: pending.target, local: source)
                if merged != source {
                    let selection = view.sourceSelection()
                    let adjusted = MarkdownEditingTextView.adjustSelection(selection, from: source, to: merged)
                    view.setMarkdownSource(merged, images: parent.inlineImages)
                    view.setSourceSelection(adjusted)
                    source = merged
                }
            }
            lastCommittedSource = source
            parent.text = source
            applyStyle(to: view)
            (view.enclosingScrollView as? MarkdownEditorScrollView)?.reportContentHeight()
            view.scheduleSlashMenuUpdate()
            if sortAfterEdit && view.separateCompletedTasks {
                DispatchQueue.main.async { [weak view] in view?.separateAllTaskGroups() }
            }
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelection: NSRange,
                      toCharacterRange newSelection: NSRange) -> NSRange {
            guard let view = textView as? MarkdownEditingTextView, !view.hasMarkedText() else { return newSelection }
            view.synchronizeTaskRangesIfNeeded()
            if newSelection.length > 0 {
                var start = newSelection.location
                var end = NSMaxRange(newSelection)
                for marker in view.reminderRanges {
                    if start > marker.location && start < NSMaxRange(marker) { start = marker.location }
                    if end > marker.location && end < NSMaxRange(marker) { end = NSMaxRange(marker) }
                }
                return NSRange(location: start, length: end - start)
            }
            if let reminder = view.reminderRanges.first(where: { newSelection.location > $0.location && newSelection.location < NSMaxRange($0) }) {
                return NSRange(location: newSelection.location < oldSelection.location ? reminder.location : NSMaxRange(reminder), length: 0)
            }
            guard oldSelection.length == 0 else { return newSelection }
            if let hidden = view.hiddenTaskRanges.first(where: { NSLocationInRange(newSelection.location, $0) }) {
                let forward = newSelection.location >= oldSelection.location
                var position = forward ? NSMaxRange(hidden) : max(0, hidden.location - 1)
                while let other = view.hiddenTaskRanges.first(where: { NSLocationInRange(position, $0) }) {
                    let next = forward ? NSMaxRange(other) : max(0, other.location - 1)
                    if next == position { return oldSelection }
                    position = next
                }
                return NSRange(location: min(position, (view.string as NSString).length), length: 0)
            }
            guard
                  let marker = view.taskMarkerCoveringCaret(newSelection.location) else { return newSelection }
            let lineStart = (view.string as NSString).lineRange(for: NSRange(location: marker.location, length: 0)).location
            if newSelection.location < oldSelection.location, lineStart > 0 {
                return NSRange(location: lineStart - 1, length: 0)
            }
            return NSRange(location: NSMaxRange(marker), length: 0)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let view = textView as? MarkdownEditingTextView, !view.editingTaskStructure else { return true }
            view.synchronizeTaskRangesIfNeeded()
            return !view.hiddenTaskRanges.contains { NSIntersectionRange(affectedCharRange, $0).length > 0 }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? MarkdownEditingTextView else { return }
            view.synchronizeTaskRangesIfNeeded()
            // Marker characters are visually replaced by a circle. A caret inside them would
            // appear on top of the circle, so snap it to the beginning of the task text.
            let selection = view.selectedRange()
            if !view.hasMarkedText(), !adjustingTaskCaret, !taskCaretAdjustmentScheduled,
               selection.length == 0,
               view.taskMarkerCoveringCaret(selection.location) != nil {
                // Selection notifications can arrive while TextKit is still mutating storage.
                // Never set a selection recursively from inside that notification.
                taskCaretAdjustmentScheduled = true
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self else { return }
                    self.taskCaretAdjustmentScheduled = false
                    guard let view, !view.hasMarkedText(), view.selectedRange() == selection,
                          let marker = view.taskMarkerCoveringCaret(selection.location) else { return }
                    self.adjustingTaskCaret = true
                    defer { self.adjustingTaskCaret = false }
                    view.setSelectedRange(NSRange(location: NSMaxRange(marker), length: 0))
                }
            }
            let active = view.separatorRanges.first(where: { view.isEditingSeparator($0) })
            let activeFence = view.codeFenceRanges.first(where: { view.isEditingSeparator($0) })
            if active != view.activeSeparatorRange || activeFence != view.activeCodeFenceRange { applyStyle(to: view) }
            view.scheduleSlashMenuUpdate()
        }

        func applyStyle(to view: NSTextView) {
            guard !view.hasMarkedText(), let storage = view.textStorage else { return }
            let bodyFont = NSFont.preferredFont(forTextStyle: .body)
            let full = NSRange(location: 0, length: storage.length)
            let source = view.string as NSString
            var attachments: [(NSRange, NSTextAttachment)] = []
            storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
                if let attachment = value as? NSTextAttachment { attachments.append((range, attachment)) }
            }
            storage.beginEditing()
            storage.setAttributes([.font: bodyFont, .foregroundColor: NSColor(parent.textColor)], range: full)
            for (range, attachment) in attachments { storage.addAttribute(.attachment, value: attachment, range: range) }
            var fence = MarkdownFenceScanner()
            var separatorRanges: [NSRange] = []
            var codeFenceRanges: [NSRange] = []
            var tableVisuals: [MarkdownTableVisual] = []
            var quoteRanges: [NSRange] = []
            var taskMarkers: [(range: NSRange, checked: Bool)] = []
            var bulletMarkers: [NSRange] = []
            let orderedMarkers = orderedListMarkers(in: source)
            let orderedByLocation = Dictionary(uniqueKeysWithValues: orderedMarkers.map { ($0.marker.location, $0) })
            var reminderRanges: [NSRange] = []
            var hiddenTaskRanges: [NSRange] = []
            let taskRegex = MarkdownEditingTextView.taskLineRegex
            let reminderRegex = try? NSRegularExpression(pattern: #"⏰\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}"#)
            source.enumerateSubstrings(in: full, options: .byLines) { line, range, _, _ in
                guard let line else { return }
                if fence.consume(line) {
                    codeFenceRanges.append(range)
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.firstLineHeadIndent = 10
                    paragraph.headIndent = 10
                    paragraph.tailIndent = -10
                    if fence.isInside { paragraph.paragraphSpacingBefore = 12 }
                    else { paragraph.paragraphSpacing = 12 }
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: source.paragraphRange(for: range))
                    storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular),
                                           .foregroundColor: NSColor.secondaryLabelColor], range: range)
                    if let editor = view as? MarkdownEditingTextView, !editor.isEditingSeparator(range) {
                        let text = line as NSString
                        var start = 0
                        while start < text.length && text.character(at: start) == 32 { start += 1 }
                        if start < text.length {
                            let delimiter = text.character(at: start)
                            var end = start
                            while end < text.length && text.character(at: end) == delimiter { end += 1 }
                            self.hideMarker(NSRange(location: range.location + start, length: end - start), in: storage)
                        }
                    }
                    return
                }
                if fence.isInside {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.firstLineHeadIndent = 10
                    paragraph.headIndent = 10
                    paragraph.tailIndent = -10
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: source.paragraphRange(for: range))
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular), range: range)
                    return
                }
                if let regex = reminderRegex {
                    for match in regex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                        reminderRanges.append(NSRange(location: range.location + match.range.location, length: match.range.length))
                    }
                }
                if let match = taskRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    let indent = match.range(at: 1).length
                    let marker = NSRange(location: range.location + indent, length: match.range.length - indent)
                    let checked = (line as NSString).substring(with: match.range(at: 2)) != " "
                    taskMarkers.append((marker, checked))
                    let awaitingHide = (view as? MarkdownEditingTextView)?.isTaskAwaitingHide(at: range.location) == true
                    if checked && self.parent.hideCompletedTasks && !awaitingHide {
                        let lineRange = source.lineRange(for: range)
                        let hiddenStyle = NSMutableParagraphStyle()
                        hiddenStyle.minimumLineHeight = 0.1
                        hiddenStyle.maximumLineHeight = 0.1
                        storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1),
                                               .foregroundColor: NSColor.clear,
                                               .kern: 0,
                                               .paragraphStyle: hiddenStyle], range: lineRange)
                        hiddenTaskRanges.append(lineRange)
                        return
                    }
                    // Collapse the hidden Markdown syntax to a tiny width, then reserve one
                    // fixed gutter on its first glyph. This stays identical for [ ] and [x].
                    let markerFont = NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular)
                    storage.addAttributes([.foregroundColor: NSColor.clear, .font: markerFont], range: marker)
                    let spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
                    let indentKern = max(0, 10 - spaceWidth)
                    if indent > 0 {
                        // Two Markdown spaces form one visual nesting step, matching document editors.
                        let indentation = NSRange(location: range.location, length: indent)
                        storage.addAttribute(.kern, value: indentKern, range: indentation)
                    }
                    // Checked and unchecked Markdown markers have different glyph widths. Give
                    // both the same gutter so sibling text and wrapped lines stay aligned.
                    let measuredMarkerWidth = (source.substring(with: marker) as NSString)
                        .size(withAttributes: [.font: markerFont]).width
                    let markerWidth = max(20, bodyFont.pointSize * 1.55)
                    if marker.length > 0 {
                        storage.addAttribute(.kern, value: markerWidth - measuredMarkerWidth,
                                             range: NSRange(location: marker.location, length: 1))
                    }
                    // Continuation lines align with the task text, not the circle gutter.
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.headIndent = CGFloat(indent) * (spaceWidth + indentKern) + markerWidth
                    paragraph.minimumLineHeight = view.layoutManager?.defaultLineHeight(for: bodyFont) ?? bodyFont.pointSize
                    paragraph.lineSpacing = 2
                    paragraph.paragraphSpacing = 2
                    storage.addAttribute(.paragraphStyle, value: paragraph,
                                         range: source.paragraphRange(for: range))
                } else if let match = MarkdownEditingTextView.listLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    let indent = match.range(at: 1).length
                    let marker = NSRange(location: range.location + indent, length: match.range.length - indent)
                    let value = (line as NSString).substring(with: match.range(at: 2))
                    let spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
                    let indentKern = max(0, 10 - spaceWidth)
                    if indent > 0 {
                        storage.addAttribute(.kern, value: indentKern, range: NSRange(location: range.location, length: indent))
                    }
                    let markerWidth: CGFloat
                    if ["-", "+", "*"].contains(value) {
                        bulletMarkers.append(marker)
                        let markerFont = NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular)
                        storage.addAttributes([.foregroundColor: NSColor.clear, .font: markerFont], range: marker)
                        markerWidth = max(20, bodyFont.pointSize * 1.55)
                        let measured = (source.substring(with: marker) as NSString).size(withAttributes: [.font: markerFont]).width
                        storage.addAttribute(.kern, value: markerWidth - measured, range: NSRange(location: marker.location, length: 1))
                    } else {
                        let markerFont = NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular)
                        storage.addAttributes([.foregroundColor: NSColor.clear, .font: markerFont], range: marker)
                        let label = orderedByLocation[marker.location]?.label ?? value
                        markerWidth = max(20, (label as NSString).size(withAttributes: [.font: bodyFont]).width + 7)
                        let measured = (source.substring(with: marker) as NSString).size(withAttributes: [.font: markerFont]).width
                        storage.addAttribute(.kern, value: markerWidth - measured, range: NSRange(location: marker.location, length: 1))
                    }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.headIndent = CGFloat(indent) * (spaceWidth + indentKern) + markerWidth
                    paragraph.minimumLineHeight = view.layoutManager?.defaultLineHeight(for: bodyFont) ?? bodyFont.pointSize
                    paragraph.lineSpacing = 2
                    paragraph.paragraphSpacing = 2
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: source.paragraphRange(for: range))
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.range(of: #"^(?:-\s*-\s*-(?:\s*-)*|\*\s*\*\s*\*(?:\s*\*)*|_\s*_\s*_(?:\s*_)*)$"#, options: .regularExpression) != nil {
                    separatorRanges.append(range)
                    if let editor = view as? MarkdownEditingTextView, !editor.isEditingSeparator(range) {
                        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                    }
                    return
                }
                let hashes = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                    let size: CGFloat = hashes == 1 ? 20 : hashes == 2 ? 17 : 15
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: range)
                    if hashes == 1 {
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.paragraphSpacingBefore = 5
                        paragraph.paragraphSpacing = 7
                        storage.addAttribute(.paragraphStyle, value: paragraph,
                                             range: source.paragraphRange(for: range))
                    }
                    if (line as NSString).length > hashes + 1 {
                        self.hideMarker(NSRange(location: range.location, length: hashes + 1), in: storage)
                    }
                } else if line.hasPrefix("> ") {
                    quoteRanges.append(range)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.firstLineHeadIndent = 12
                    paragraph.headIndent = 12
                    paragraph.lineSpacing = 2
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: source.paragraphRange(for: range))
                    if (line as NSString).length > 2 { self.hideMarker(NSRange(location: range.location, length: 2), in: storage) }
                }
                self.applyInlineStyles(to: storage, source: source, range: range, bodyFont: bodyFont)
            }
            self.applyTableStyles(to: storage, source: source, bodyFont: bodyFont, view: view, visuals: &tableVisuals)
            self.applySavedTextStyles(to: storage, source: source, bodyFont: bodyFont)
            storage.endEditing()
            if let editor = view as? MarkdownEditingTextView {
                editor.separatorRanges = separatorRanges
                editor.codeFenceRanges = codeFenceRanges
                editor.tableVisuals = tableVisuals
                editor.tableVisualSource = view.string
                editor.quoteRanges = quoteRanges
                editor.taskMarkers = taskMarkers
                editor.bulletMarkers = bulletMarkers
                editor.orderedMarkers = orderedMarkers
                editor.reminderRanges = reminderRanges
                editor.hiddenTaskRanges = hiddenTaskRanges
                editor.structuralRangeSource = view.string
                if let layout = editor.layoutManager, let container = editor.textContainer, !attachments.isEmpty {
                    // Reset glyphs through TextKit when visibility changes. Setting not-shown to
                    // false directly turns attachment glyphs into visible control symbols.
                    for (range, _) in attachments { layout.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil) }
                    layout.ensureLayout(for: container)
                    for (range, _) in attachments where hiddenTaskRanges.contains(where: { NSIntersectionRange(range, $0).length > 0 }) {
                        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                        for glyph in glyphs.location..<NSMaxRange(glyphs) { layout.setNotShownAttribute(true, forGlyphAt: glyph) }
                    }
                }
                editor.taskColor = NSColor(parent.textColor)
                editor.tablePaperColor = NSColor(parent.paperColor)
                editor.activeSeparatorRange = separatorRanges.first(where: { editor.isEditingSeparator($0) })
                editor.activeCodeFenceRange = codeFenceRanges.first(where: { editor.isEditingSeparator($0) })
                editor.separatorColor = NSColor(parent.textColor).withAlphaComponent(0.28)
                editor.needsDisplay = true
            }
            view.typingAttributes = [.font: bodyFont, .foregroundColor: NSColor(parent.textColor)]
        }

        private func hideMarker(_ range: NSRange, in storage: NSTextStorage) {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 0.1)], range: range)
        }

        /// Use the CommonMark/GFM parser to identify tables, leaving their source editable.
        private func applyTableStyles(to storage: NSTextStorage, source: NSString, bodyFont: NSFont, view: NSTextView,
                                      visuals: inout [MarkdownTableVisual]) {
            guard source.length > 0, source.range(of: "|").location != NSNotFound else { return }
            var lines: [NSRange] = []
            source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { _, range, _, _ in
                lines.append(range)
            }
            let document = Document(parsing: source as String)
            var tables: [Markdown.Table] = []
            func collect(_ node: any Markup) {
                if let table = node as? Markdown.Table { tables.append(table); return }
                for child in node.children { collect(child) }
            }
            collect(document)
            for table in tables {
                guard let range = table.range else { continue }
                let first = range.lowerBound.line - 1
                let last = range.upperBound.line - (range.upperBound.column == 1 ? 2 : 1)
                guard first >= 0, first + 1 < lines.count, last >= first else { continue }
                let end = min(last, lines.count - 1)
                let columns = table.maxColumnCount
                guard columns > 0, columns <= 12 else { continue }
                var rows: [(range: NSRange, pipes: [Int], cells: [NSRange])] = []
                var widths = [CGFloat](repeating: 0, count: columns)
                var allRows: [NSRange] = []
                var allCells: [[NSRange]] = []
                var stickyMarker: NSRange?
                let markerIndex = first >= 2 && source.substring(with: lines[first - 1]).isEmpty ? first - 2 : first - 1
                if markerIndex >= 0 && source.substring(with: lines[markerIndex]).trimmingCharacters(in: .whitespaces) == stickyTableMarker {
                    stickyMarker = NSRange(location: lines[markerIndex].location, length: lines[first].location - lines[markerIndex].location)
                    let hidden = NSMutableParagraphStyle()
                    hidden.minimumLineHeight = 0.1
                    hidden.maximumLineHeight = 0.1
                    storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 0.1), .paragraphStyle: hidden], range: stickyMarker!)
                }
                for rowIndex in first...end {
                    let row = lines[rowIndex]
                    let text = source.substring(with: row) as NSString
                    var pipes: [Int] = []
                    var escaped = false
                    var codeRun = 0
                    for i in 0..<text.length {
                        let char = text.character(at: i)
                        if char == 96 && !escaped { codeRun = codeRun == 0 ? 1 : 0 }
                        if char == 124 && !escaped && codeRun == 0 { pipes.append(i) }
                        if char == 92 { escaped.toggle() } else { escaped = false }
                    }
                    var edges = [-1] + pipes + [text.length]
                    if pipes.first == 0 { edges.removeFirst() }
                    if pipes.last == text.length - 1 { edges.removeLast() }
                    guard edges.count >= 2 else { continue }
                    var cells: [NSRange] = []
                    for column in 0..<min(columns, edges.count - 1) {
                        let start = edges[column] + 1
                        let cell = NSRange(location: row.location + start, length: max(0, edges[column + 1] - start))
                        cells.append(cell)
                        let value = source.substring(with: cell) as NSString
                        let font = rowIndex == first ? NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask) : bodyFont
                        widths[column] = max(widths[column], value.size(withAttributes: [.font: font]).width)
                    }
                    allRows.append(row)
                    allCells.append(cells)
                    if rowIndex != first + 1 { rows.append((row, pipes, cells)) }
                }
                let padding = view.textContainer?.lineFragmentPadding ?? 0
                let available = view.bounds.width - view.textContainerOrigin.x - view.textContainerInset.width - padding * 2
                guard rows.count >= 1, available > 0 else { continue }
                let columnWidth = floor(available / CGFloat(columns))
                // Extremely wide cells retain editable Markdown rather than overlapping adjacent cells.
                guard columnWidth >= 36, widths.allSatisfy({ $0 + 12 <= columnWidth }) else { continue }
                let markerFont = NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular)
                for (rowIndex, row) in rows.enumerated() {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.minimumLineHeight = (view.layoutManager?.defaultLineHeight(for: bodyFont) ?? bodyFont.pointSize) + 12
                    paragraph.maximumLineHeight = paragraph.minimumLineHeight
                    if row.pipes.first != 0 { paragraph.firstLineHeadIndent = 8; paragraph.headIndent = 8 }
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: source.paragraphRange(for: row.range))
                    if rowIndex == 0 {
                        let bold = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
                        for cell in row.cells where cell.length > 0 { storage.addAttribute(.font, value: bold, range: cell) }
                    }
                    for pipe in row.pipes {
                        storage.addAttributes([.foregroundColor: NSColor.clear, .font: markerFont],
                                              range: NSRange(location: row.range.location + pipe, length: 1))
                    }
                    if row.pipes.first == 0 {
                        storage.addAttribute(.kern, value: 8, range: NSRange(location: row.range.location, length: 1))
                    }
                    for (column, cell) in row.cells.enumerated() where column < widths.count && column + 1 < row.cells.count {
                        let pipe = NSMaxRange(cell)
                        guard pipe < NSMaxRange(row.range), source.character(at: pipe) == 124 else { continue }
                        let font = rowIndex == 0 ? NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask) : bodyFont
                        let width = (source.substring(with: cell) as NSString).size(withAttributes: [.font: font]).width
                        let spacer = cell.length > 0 ? pipe - 1 : pipe
                        storage.addAttribute(.kern, value: max(0, columnWidth - width), range: NSRange(location: spacer, length: 1))
                    }
                }
                let divider = lines[first + 1]
                let collapsed = NSMutableParagraphStyle()
                collapsed.minimumLineHeight = 0.1
                collapsed.maximumLineHeight = 0.1
                storage.addAttributes([.foregroundColor: NSColor.clear, .font: markerFont, .paragraphStyle: collapsed],
                                      range: source.paragraphRange(for: divider))
                visuals.append(MarkdownTableVisual(rows: rows.map(\.range), columnWidths: Array(repeating: columnWidth, count: columns),
                                                   allRows: allRows, cells: allCells, sticky: stickyMarker != nil, stickyMarker: stickyMarker))
            }
        }

        /// HTML spans keep colour and font choices in the Markdown source across restarts/export.
        private func applySavedTextStyles(to storage: NSTextStorage, source: NSString, bodyFont: NSFont) {
            let pattern = #"<span style=\"(color:(?:#[0-9a-fA-F]{6}|inherit)|"#
                + #"font-family:[^\"<>;]+(?:;font-size:[0-9]{1,3}px)?"#
                + #"(?:;font-weight:(?:bold|normal))?(?:;font-style:(?:italic|normal))?|"#
                + #"font-size:[0-9]{1,3}px)\">|</span>"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let full = NSRange(location: 0, length: source.length)
            var stack: [(NSRange, String)] = []
            var spans: [(NSRange, NSRange, String)] = []
            for match in regex.matches(in: source as String, range: full) {
                let style = match.range(at: 1)
                if style.location != NSNotFound {
                    stack.append((match.range, source.substring(with: style)))
                } else if let open = stack.popLast(), match.range.location >= NSMaxRange(open.0) {
                    let content = NSRange(location: NSMaxRange(open.0), length: match.range.location - NSMaxRange(open.0))
                    spans.append((open.0, content, open.1))
                    hideMarker(match.range, in: storage)
                }
            }
            // Outer spans first, so a more specific nested choice wins.
            for (open, content, style) in spans.reversed() {
                guard content.length > 0 else { hideMarker(open, in: storage); continue }
                if style.hasPrefix("color:"), let rgb = UInt32(style.dropFirst(7), radix: 16) {
                    let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                                        blue: CGFloat(rgb & 255) / 255, alpha: 1)
                    storage.enumerateAttribute(.foregroundColor, in: content) { value, range, _ in
                        guard let previous = value as? NSColor, previous.alphaComponent > 0.01 else { return }
                        storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(previous.alphaComponent), range: range)
                    }
                } else if style == "color:inherit" {
                    storage.enumerateAttribute(.foregroundColor, in: content) { value, range, _ in
                        guard let previous = value as? NSColor, previous.alphaComponent > 0.01 else { return }
                        storage.addAttribute(.foregroundColor, value: NSColor(self.parent.textColor).withAlphaComponent(previous.alphaComponent), range: range)
                    }
                } else if style.hasPrefix("font-family:") {
                    let parts = style.split(separator: ";").map(String.init)
                    let family = String(parts[0].dropFirst("font-family:".count))
                    let size = parts.first(where: { $0.hasPrefix("font-size:") }).flatMap { Double($0.dropFirst("font-size:".count).dropLast(2)) }
                    let weight = parts.first(where: { $0.hasPrefix("font-weight:") })
                    let italic = parts.first(where: { $0.hasPrefix("font-style:") })
                    storage.enumerateAttribute(.font, in: content) { value, range, _ in
                        let previous = value as? NSFont ?? bodyFont
                        guard previous.pointSize > 1 else { return }
                        var font = NSFontManager.shared.font(withFamily: family,
                                                            traits: NSFontManager.shared.traits(of: previous),
                                                            weight: 5, size: size ?? previous.pointSize)
                            ?? (family == "system-ui" ? NSFont.systemFont(ofSize: size ?? previous.pointSize) : NSFont(name: family, size: size ?? previous.pointSize)) ?? previous
                        if family == "system-ui" {
                            let traits = NSFontManager.shared.traits(of: previous)
                            if traits.contains(.boldFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                            if traits.contains(.italicFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                        }
                        if let weight {
                            font = weight == "font-weight:bold" ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                                : NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
                        }
                        if let italic {
                            font = italic == "font-style:italic" ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                                : NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
                        }
                        storage.addAttribute(.font, value: font, range: range)
                    }
                } else if style.hasPrefix("font-size:"),
                          let size = Double(style.dropFirst("font-size:".count).dropLast(2)), (8...144).contains(size) {
                    storage.enumerateAttribute(.font, in: content) { value, range, _ in
                        let previous = value as? NSFont ?? bodyFont
                        guard previous.pointSize > 1 else { return }
                        storage.addAttribute(.font, value: NSFontManager.shared.convert(previous, toSize: size), range: range)
                    }
                }
                hideMarker(open, in: storage)
            }
        }

        private func applyInlineStyles(to storage: NSTextStorage, source: NSString, range: NSRange, bodyFont: NSFont) {
            var codeRanges: [NSRange] = []
            for (regex, format) in Self.inlinePatterns {
                for match in regex.matches(in: source as String, range: range) {
                    let content = match.range(at: 1)
                    guard content.location != NSNotFound, content.length > 0 else { continue }
                    if format != .code && codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
                    if format == .code { codeRanges.append(match.range) }
                    let oldFont = storage.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont ?? bodyFont
                    switch format {
                    case .bold:
                        storage.addAttribute(.font, value: NSFontManager.shared.convert(oldFont, toHaveTrait: .boldFontMask), range: content)
                    case .italic:
                        storage.addAttribute(.font, value: NSFontManager.shared.convert(oldFont, toHaveTrait: .italicFontMask), range: content)
                    case .boldItalic:
                        let bold = NSFontManager.shared.convert(oldFont, toHaveTrait: .boldFontMask)
                        storage.addAttribute(.font, value: NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask), range: content)
                    case .strikethrough:
                        storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                    case .code:
                        storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: oldFont.pointSize, weight: .regular),
                                               .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12)], range: content)
                    }
                    hideMarker(NSRange(location: match.range.location, length: content.location - match.range.location), in: storage)
                    hideMarker(NSRange(location: NSMaxRange(content), length: NSMaxRange(match.range) - NSMaxRange(content)), in: storage)
                }
            }
            if let regex = Self.linkPattern {
                for match in regex.matches(in: source as String, range: range) {
                    let label = match.range(at: 1), destination = match.range(at: 2)
                    guard label.location != NSNotFound, destination.location != NSNotFound,
                          let url = URL(string: source.substring(with: destination)) else { continue }
                    storage.addAttributes([.link: url, .foregroundColor: NSColor.linkColor,
                                           .underlineStyle: NSUnderlineStyle.single.rawValue], range: label)
                    hideMarker(NSRange(location: match.range.location, length: label.location - match.range.location), in: storage)
                    hideMarker(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)), in: storage)
                }
            }
        }
    }
}

private final class MarkdownEditorScrollView: NSScrollView {
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    private var reportedHeight: CGFloat = 0
    private var lastTableWidth: CGFloat = 0

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if let editor = documentView as? MarkdownEditingTextView, editor.tableVisuals.contains(where: \.sticky) {
            editor.needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        if let view = documentView as? NSTextView, contentSize.width > 0,
           abs(view.frame.width - contentSize.width) > 0.5 {
            view.setFrameSize(NSSize(width: contentSize.width, height: view.frame.height))
        }
        (documentView as? MarkdownEditingTextView)?.updateImageWidths(contentSize.width - 16)
        if let view = documentView as? MarkdownEditingTextView, contentSize.width > 0,
           abs(contentSize.width - lastTableWidth) > 1 {
            lastTableWidth = contentSize.width
            if view.string.contains("|") {
                DispatchQueue.main.async { [weak view] in
                    guard let view, !view.hasMarkedText() else { return }
                    view.refreshTaskStyle?()
                }
            }
        }
        reportContentHeight()
    }

    func reportContentHeight() {
        guard let view = documentView as? NSTextView, let layout = view.layoutManager,
              let container = view.textContainer, contentSize.width > 0 else { return }
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).maxY
        if view.string.isEmpty || view.string.hasSuffix("\n") {
            height = max(height, layout.extraLineFragmentRect.maxY)
        }
        height = ceil(max(height, NSFont.preferredFont(forTextStyle: .body).pointSize) + view.textContainerInset.height * 2)
        guard abs(height - reportedHeight) > 0.5 else { return }
        reportedHeight = height
        DispatchQueue.main.async { [weak self] in self?.onContentHeightChange(height) }
    }
}

/// Clicking the brackets of an inline Markdown task toggles it without leaving edit mode.
private final class InlineNoteAttachment: NSTextAttachment {
    let markdown: String

    init(markdown: String, image: NSImage, availableWidth: CGFloat) {
        self.markdown = markdown
        super.init(data: nil, ofType: nil)
        self.image = image
        resize(to: availableWidth)
    }

    func resize(to availableWidth: CGFloat) {
        guard let image else { return }
        let size = image.size
        if size.width > 0 && size.height > 0 {
            let factor = min(1, min(max(100, availableWidth) / size.width, 240 / size.height))
            bounds = NSRect(x: 0, y: 0, width: size.width * factor, height: size.height * factor)
        }
    }

    required init?(coder: NSCoder) { nil }
}

final class MarkdownEditingTextView: NSTextView {
    static let taskLineRegex = try! NSRegularExpression(pattern: #"^([ \t]*)[-*+] \[([ xX])\](?:[ \t]+|$)"#)
    static let listLineRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-+*]|[0-9]{1,9}[.)])(?:[ \t]+|$)"#)
    var structuralRangeSource: String?
    // A collapsed or closed note destroys its editor. Keep its undo stack with that editor,
    // rather than leaving text-system actions on a longer-lived window undo manager.
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
    var separateCompletedTasks = false
    var hideCompletedTasks = false
    var trackAnimatedContentHeight = false
    var hiddenTaskRanges: [NSRange] = []
    var editingTaskStructure = false
    var separatorRanges: [NSRange] = []
    var codeFenceRanges: [NSRange] = []
    fileprivate var tableVisuals: [MarkdownTableVisual] = []
    fileprivate var tableVisualSource: String?
    var quoteRanges: [NSRange] = []
    var activeCodeFenceRange: NSRange?
    var taskMarkers: [(range: NSRange, checked: Bool)] = []
    var bulletMarkers: [NSRange] = []
    fileprivate var orderedMarkers: [OrderedListMarker] = []
    var reminderRanges: [NSRange] = []
    var taskColor = NSColor.labelColor
    var tablePaperColor = NSColor.textBackgroundColor
    private var tableTrackingArea: NSTrackingArea?
    private var tableInsertionHandle: MarkdownTableInsertionHandle?
    var refreshTaskStyle: (() -> Void)?
    private var recentlyCompleted: Set<Int> = []
    private struct CompletionLine {
        let range: NSRange
        let started: TimeInterval
        let lineHeight: CGFloat
        let paragraph: NSParagraphStyle
        let colors: [(NSRange, NSColor)]
    }
    private var completionStarts: [Int: TimeInterval] = [:]
    private var completionLines: [CompletionLine] = []
    private var completionSource: String?
    private var completionTimer: Timer?
    private var completionOpacities: [Int: CGFloat] = [:]
    private(set) var isTogglingCompletion = false
    private(set) var isApplyingCompletionFrame = false
    private struct StylePanelSelection {
        let original: String
        var expected: String
        var range: NSRange
    }
    private var colorPanelSelection: StylePanelSelection?
    private var fontPanelSelection: StylePanelSelection?
    func isTaskAwaitingHide(at location: Int) -> Bool { recentlyCompleted.contains(location) }
    private var pendingTaskPointer: (range: NSRange, start: NSPoint, current: NSPoint, moved: Bool)?
    private var reminderClickInProgress = false

    /// Selection changes can arrive after TextKit edits but before textDidChange restyles.
    /// Never use old offsets to redirect a caret or protect hidden task lines.
    func synchronizeTaskRangesIfNeeded() {
        let current = string
        guard structuralRangeSource != current else { return }
        let source = current as NSString
        var markers: [(range: NSRange, checked: Bool)] = []
        var hidden: [NSRange] = []
        var fence = MarkdownFenceScanner()
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            if fence.consume(line) { return }
            guard !fence.isInside, let match = Self.taskLineRegex.firstMatch(in: line,
                range: NSRange(location: 0, length: (line as NSString).length)) else { return }
            let indent = match.range(at: 1).length
            let checked = (line as NSString).substring(with: match.range(at: 2)) != " "
            markers.append((NSRange(location: range.location + indent, length: match.range.length - indent), checked))
            if checked && self.hideCompletedTasks && !self.isTaskAwaitingHide(at: range.location) {
                hidden.append(source.lineRange(for: range))
            }
        }
        taskMarkers = markers
        hiddenTaskRanges = hidden
        structuralRangeSource = current
    }

    /// A visual selection can span completed tasks that are currently hidden. Delete only the
    /// selected visible text, retaining the hidden task lines and their attributed attachments.
    private func deleteVisibleSelectionPreservingHiddenTasks() -> Bool {
        let selection = selectedRange()
        guard !hasMarkedText(), selection.location != NSNotFound, selection.length > 0,
              let kept = hiddenFragments(in: selection) else { return false }
        replaceAcrossHiddenTasks(in: selection, with: kept,
                                 selectionAfter: NSRange(location: selection.location, length: 0))
        return true
    }

    private func hiddenFragments(in selection: NSRange) -> NSMutableAttributedString? {
        guard let storage = textStorage, NSMaxRange(selection) <= storage.length else { return nil }
        let hidden = hiddenTaskRanges.map { NSIntersectionRange($0, selection) }
            .filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard !hidden.isEmpty else { return nil }

        let source = storage.string as NSString
        let kept = NSMutableAttributedString(string: "")
        var lastEnd = selection.location
        for range in hidden {
            var start = range.location
            // Preserve the line break before a hidden task so it cannot become ordinary text
            // appended to the line before the selection.
            if start > lastEnd, source.substring(with: NSRange(location: start - 1, length: 1)) == "\n" {
                start -= 1
            }
            let fragment = NSRange(location: start, length: NSMaxRange(range) - start)
            kept.append(storage.attributedSubstring(from: fragment))
            lastEnd = NSMaxRange(range)
        }
        return kept
    }

    override func deleteBackward(_ sender: Any?) {
        let hasSelection = selectedRange().length > 0
        if hasSelection { breakUndoCoalescing() }
        defer { if hasSelection { breakUndoCoalescing() } }
        if deleteVisibleSelectionPreservingHiddenTasks() { return }
        if deleteAcrossHiddenTasks(backward: true) { return }
        if selectedRange().length == 0, let range = reminderRanges.first(where: { NSMaxRange($0) == selectedRange().location }) {
            insertText("", replacementRange: range)
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let hasSelection = selectedRange().length > 0
        if hasSelection { breakUndoCoalescing() }
        defer { if hasSelection { breakUndoCoalescing() } }
        if deleteVisibleSelectionPreservingHiddenTasks() { return }
        if deleteAcrossHiddenTasks(backward: false) { return }
        if selectedRange().length == 0, let range = reminderRanges.first(where: { $0.location == selectedRange().location }) {
            insertText("", replacementRange: range)
            return
        }
        super.deleteForward(sender)
    }

    /// Removing a visible line break must not remove the completed task lines between the two
    /// visible paragraphs. Move the following visible paragraph before the hidden block instead.
    private func deleteAcrossHiddenTasks(backward: Bool) -> Bool {
        let selection = selectedRange()
        guard !hasMarkedText(), selection.length == 0, selection.location != NSNotFound,
              let storage = textStorage, !hiddenTaskRanges.isEmpty else { return false }
        let source = storage.string as NSString
        guard selection.location <= source.length else { return false }
        var blocks: [NSRange] = []
        for range in hiddenTaskRanges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = blocks.last, NSMaxRange(last) == range.location {
                blocks[blocks.count - 1].length += range.length
            } else { blocks.append(range) }
        }
        for block in blocks {
            guard NSMaxRange(block) <= source.length else { continue }
            if block.location == 0, backward, selection.location == NSMaxRange(block),
               NSMaxRange(block) < source.length {
                let following = source.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
                let visible = source.substring(with: following).trimmingCharacters(in: .newlines)
                if visible.isEmpty && following.length > 0 {
                    insertText("", replacementRange: following)
                    return true
                }
            }
            guard block.location > 0,
                  source.character(at: block.location - 1) == 10 else { continue }
            let separatorStart = block.location >= 2 && source.character(at: block.location - 2) == 13
                ? block.location - 2 : block.location - 1
            let end = NSMaxRange(block)
            guard backward ? selection.location == end : selection.location == separatorStart else { continue }

            if end < source.length {
                let following = source.lineRange(for: NSRange(location: end, length: 0))
                var bodyLength = following.length
                if bodyLength > 0 && source.character(at: NSMaxRange(following) - 1) == 10 {
                    bodyLength -= 1
                    if bodyLength > 0 && source.character(at: following.location + bodyLength - 1) == 13 { bodyLength -= 1 }
                }
                // An empty visible line can be removed without touching the hidden block.
                if bodyLength == 0 && following.length > 0 {
                    insertText("", replacementRange: following)
                    setSelectedRange(NSRange(location: backward ? end : separatorStart, length: 0))
                    return true
                }
                let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(
                    from: NSRange(location: following.location, length: bodyLength)))
                let hidden = NSMutableAttributedString(attributedString: storage.attributedSubstring(
                    from: NSRange(location: separatorStart, length: end - separatorStart)))
                // When the following paragraph was the last line, keep the last hidden task at EOF.
                if following.location + following.length == source.length && following.length == bodyLength,
                   hidden.length > 0, (hidden.string as NSString).character(at: hidden.length - 1) == 10 {
                    var newlineLength = 1
                    if hidden.length > 1 && (hidden.string as NSString).character(at: hidden.length - 2) == 13 { newlineLength = 2 }
                    hidden.deleteCharacters(in: NSRange(location: hidden.length - newlineLength, length: newlineLength))
                }
                replacement.append(hidden)
                let affected = NSRange(location: separatorStart, length: NSMaxRange(following) - separatorStart)
                replaceAcrossHiddenTasks(in: affected, with: replacement,
                                         selectionAfter: NSRange(location: separatorStart, length: 0))
                return true
            }

            if block.length > 0 && source.character(at: end - 1) == 10 {
                let length = block.length > 1 && source.character(at: end - 2) == 13 ? 2 : 1
                replaceAcrossHiddenTasks(in: NSRange(location: end - length, length: length),
                                         with: NSAttributedString(string: ""),
                                         selectionAfter: NSRange(location: separatorStart, length: 0))
                return true
            }
            if backward {
                setSelectedRange(NSRange(location: separatorStart, length: 0))
                super.deleteBackward(nil)
            }
            return true
        }
        return false
    }

    /// Undo and redo must also be allowed to restore the protected hidden lines.
    private func replaceAcrossHiddenTasks(in range: NSRange, with replacement: NSAttributedString,
                                          selectionAfter: NSRange) {
        guard let storage = textStorage, range.location != NSNotFound, NSMaxRange(range) <= storage.length else { return }
        let original = storage.attributedSubstring(from: range)
        let oldSelection = selectedRange()
        let manager = undoManager
        manager?.registerUndo(withTarget: self) { target in
            target.replaceAcrossHiddenTasks(in: NSRange(location: range.location, length: replacement.length),
                                            with: original, selectionAfter: oldSelection)
        }
        manager?.disableUndoRegistration()
        editingTaskStructure = true
        insertText(replacement, replacementRange: range)
        editingTaskStructure = false
        manager?.enableUndoRegistration()
        let location = min(selectionAfter.location, storage.length)
        setSelectedRange(NSRange(location: location, length: min(selectionAfter.length, storage.length - location)))
    }

    /// The leading indentation and marker are one non-editable visual gutter.
    func taskMarkerCoveringCaret(_ location: Int) -> NSRange? {
        let source = string as NSString
        for marker in taskMarkers {
            let range = marker.range
            guard range.location < source.length, NSMaxRange(range) <= source.length else { continue }
            let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
            guard location >= lineStart && location < NSMaxRange(range) else { continue }
            let raw = source.substring(with: range)
            guard raw.range(of: #"^[-*+] \[[ xX]\](?:[ \t]+|$)"#, options: .regularExpression) != nil else { continue }
            return range
        }
        return nil
    }

    func insertMarkdownTask() {
        guard !hasMarkedText() else { return }
        let selection = selectedRange()
        let source = string as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return }
        let line = source.lineRange(for: selection)
        let before = source.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let prefix = before.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
        window?.makeFirstResponder(self)
        insertText(prefix + "- [ ] ", replacementRange: selection)
    }
    var activeSeparatorRange: NSRange?
    var separatorColor = NSColor.separatorColor

    func isEditingSeparator(_ range: NSRange) -> Bool {
        let selection = selectedRange()
        if selection.length == 0 {
            return selection.location >= range.location && selection.location <= NSMaxRange(range)
        }
        return NSIntersectionRange(selection, range).length > 0
    }

    /// Input-method composition changes text positions before `textDidChange` can restyle it.
    /// Recompute marker locations for painting so a moved checkbox is never drawn over typing.
    private func markersForDrawing() -> [(range: NSRange, checked: Bool)] {
        guard hasMarkedText() else { return taskMarkers }
        let source = string as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)[-*+] \[([ xX])\](?:[ \t]+|$)"#) else { return [] }
        var result: [(range: NSRange, checked: Bool)] = []
        var fence = MarkdownFenceScanner()
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            if fence.consume(line) { return }
            guard !fence.isInside,
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return }
            let indent = match.range(at: 1).length
            result.append((NSRange(location: range.location + indent, length: match.range.length - indent),
                           (line as NSString).substring(with: match.range(at: 2)) != " "))
        }
        return result
    }

    private func bulletsForDrawing() -> [NSRange] {
        guard hasMarkedText() else { return bulletMarkers }
        let source = string as NSString
        var result: [NSRange] = []
        var fence = MarkdownFenceScanner()
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            if fence.consume(line) { return }
            let lineRange = NSRange(location: 0, length: (line as NSString).length)
            guard !fence.isInside, Self.taskLineRegex.firstMatch(in: line, range: lineRange) == nil,
                  let match = Self.listLineRegex.firstMatch(in: line, range: lineRange),
                  ["-", "+", "*"].contains((line as NSString).substring(with: match.range(at: 2))) else { return }
            let indent = match.range(at: 1).length
            result.append(NSRange(location: range.location + indent, length: match.range.length - indent))
        }
        return result
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    /// Recompute the ranges while drawing so IME composition never leaves a stale background.
    private func codeBlocksForDrawing() -> [NSRange] {
        let source = string as NSString
        guard source.length > 0 else { return [] }
        var scanner = MarkdownFenceScanner()
        var start: Int?
        var blocks: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            guard let line, scanner.consume(line) else { return }
            if scanner.isInside {
                start = range.location
            } else if let blockStart = start {
                blocks.append(NSRange(location: blockStart, length: NSMaxRange(range) - blockStart))
                start = nil
            }
        }
        if let start { blocks.append(NSRange(location: start, length: source.length - start)) }
        return blocks
    }

    private func tableGeometry(_ table: MarkdownTableVisual) -> (rect: NSRect, rows: [NSRect])? {
        guard tableVisualSource == string, let layoutManager, let textContainer else { return nil }
        var rows: [NSRect] = []
        for range in table.rows {
            guard range.length > 0, NSMaxRange(range) <= (textStorage?.length ?? 0) else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            rows.append(layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        let x = textContainerOrigin.x + textContainer.lineFragmentPadding
        let width = table.columnWidths.reduce(0, +)
        return (NSRect(x: x, y: first.minY, width: width, height: last.maxY - first.minY), rows)
    }

    private func stickyHeaderRect(_ table: MarkdownTableVisual) -> NSRect? {
        guard table.sticky, let geometry = tableGeometry(table), let header = geometry.rows.first else { return nil }
        let top = visibleRect.minY
        guard top > header.minY + 1, top < geometry.rect.maxY - header.height else { return nil }
        return NSRect(x: geometry.rect.minX, y: top, width: geometry.rect.width, height: header.height)
    }

    private func insertionHandle(at point: NSPoint) -> MarkdownTableInsertionHandle? {
        guard !hasMarkedText(), tableVisualSource == string else { return nil }
        for table in tableVisuals {
            guard let geometry = tableGeometry(table), geometry.rect.insetBy(dx: -5, dy: -5).contains(point),
                  stickyHeaderRect(table)?.contains(point) != true else { continue }
            var candidates: [(CGFloat, MarkdownTableInsertionHandle)] = []
            for index in 1...geometry.rows.count {
                let y = index == geometry.rows.count ? geometry.rect.maxY :
                    (geometry.rows[index - 1].maxY + geometry.rows[index].minY) / 2
                let distance = abs(point.y - y)
                guard distance <= 5, index - 1 < table.rows.count else { continue }
                let row = table.rows[index - 1]
                let center = NSPoint(x: min(geometry.rect.maxX - 10, max(geometry.rect.minX + 10, point.x)), y: y)
                candidates.append((distance, MarkdownTableInsertionHandle(anchor: row.location, action: "rowBelow", center: center,
                    lineStart: NSPoint(x: geometry.rect.minX, y: y), lineEnd: NSPoint(x: geometry.rect.maxX, y: y))))
            }
            var x = geometry.rect.minX
            for (index, width) in table.columnWidths.enumerated() {
                x += width
                let distance = abs(point.x - x)
                guard distance <= 5, let header = table.cells.first, index < header.count else { continue }
                let center = NSPoint(x: x, y: min(geometry.rect.maxY - 10, max(geometry.rect.minY + 10, point.y)))
                candidates.append((distance, MarkdownTableInsertionHandle(anchor: header[index].location, action: "columnRight", center: center,
                    lineStart: NSPoint(x: x, y: geometry.rect.minY), lineEnd: NSPoint(x: x, y: geometry.rect.maxY))))
            }
            if let best = candidates.min(by: { $0.0 < $1.0 }) { return best.1 }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tableTrackingArea { removeTrackingArea(tableTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        tableTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let next = insertionHandle(at: convert(event.locationInWindow, from: nil))
        if tableInsertionHandle != next {
            tableInsertionHandle = next
            needsDisplay = true
        }
        if next != nil { NSCursor.pointingHand.set() }
        else { super.mouseMoved(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if tableInsertionHandle != nil { tableInsertionHandle = nil; needsDisplay = true }
        super.mouseExited(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        for table in tableVisuals {
            guard let geometry = tableGeometry(table), geometry.rect.intersects(dirtyRect) else { continue }
            taskColor.withAlphaComponent(0.035).setFill()
            NSBezierPath(roundedRect: geometry.rect, xRadius: 5, yRadius: 5).fill()
            if let header = geometry.rows.first {
                taskColor.withAlphaComponent(0.075).setFill()
                NSRect(x: geometry.rect.minX, y: header.minY, width: geometry.rect.width, height: header.height).fill()
            }
        }
        if let layoutManager, let textContainer {
            for range in codeBlocksForDrawing() where range.length > 0 && NSMaxRange(range) <= (textStorage?.length ?? 0) {
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                // Paragraph spacing belongs outside the code card, not in its background.
                let first = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let last = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
                let x = textContainerOrigin.x + textContainer.lineFragmentPadding
                let right = bounds.width - textContainerInset.width - textContainer.lineFragmentPadding
                let rect = NSRect(x: x, y: first.minY + textContainerOrigin.y - 3,
                                  width: max(0, right - x), height: last.maxY - first.minY + 6)
                guard rect.width > 0, rect.intersects(dirtyRect) else { continue }
                taskColor.withAlphaComponent(0.075).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            }
        }
        for range in reminderRanges where !hiddenTaskRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
            for rect in reminderRects(range) where rect.intersects(dirtyRect) {
                let line = (string as NSString).lineRange(for: NSRange(location: range.location, length: 0)).location
                taskColor.withAlphaComponent(0.12 * (completionOpacities[line] ?? 1)).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -1), xRadius: 5, yRadius: 5).fill()
            }
        }
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        let displayedOrderedMarkers = hasMarkedText() ? orderedListMarkers(in: string as NSString) : orderedMarkers
        let listFont = NSFont.preferredFont(forTextStyle: .body)
        for marker in displayedOrderedMarkers {
            guard marker.marker.length > 0, NSMaxRange(marker.marker) <= (textStorage?.length ?? 0) else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: marker.marker, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let label = marker.label as NSString
            let size = label.size(withAttributes: [.font: listFont])
            let rect = NSRect(x: box.minX, y: line.midY - size.height / 2, width: size.width + 2, height: size.height + 2)
            guard rect.intersects(dirtyRect) else { continue }
            label.draw(in: rect, withAttributes: [.font: listFont, .foregroundColor: taskColor])
        }
        if structuralRangeSource == string {
            for range in quoteRanges where range.length > 0 && NSMaxRange(range) <= (textStorage?.length ?? 0) {
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                let first = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let last = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
                let x = textContainerOrigin.x + textContainer.lineFragmentPadding + 1
                let rect = NSRect(x: x, y: first.minY + textContainerOrigin.y + 1, width: 2,
                                  height: max(0, last.maxY - first.minY - 2))
                guard rect.intersects(dirtyRect) else { continue }
                taskColor.withAlphaComponent(0.38).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
        }
        for table in tableVisuals {
            guard let geometry = tableGeometry(table), geometry.rect.intersects(dirtyRect) else { continue }
            taskColor.withAlphaComponent(0.23).setStroke()
            let grid = NSBezierPath(roundedRect: geometry.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            grid.lineWidth = 1
            grid.stroke()
            let lines = NSBezierPath()
            lines.lineWidth = 1
            var x = geometry.rect.minX
            for width in table.columnWidths.dropLast() {
                x += width
                lines.move(to: NSPoint(x: x, y: geometry.rect.minY))
                lines.line(to: NSPoint(x: x, y: geometry.rect.maxY))
            }
            for index in 1..<geometry.rows.count {
                let y = (geometry.rows[index - 1].maxY + geometry.rows[index].minY) / 2
                lines.move(to: NSPoint(x: geometry.rect.minX, y: y))
                lines.line(to: NSPoint(x: geometry.rect.maxX, y: y))
            }
            lines.stroke()
        }
        if let handle = tableInsertionHandle, tableVisualSource == string {
            let accent = NSColor.controlAccentColor
            accent.withAlphaComponent(0.65).setStroke()
            let guide = NSBezierPath()
            guide.lineWidth = 1.5
            guide.move(to: handle.lineStart)
            guide.line(to: handle.lineEnd)
            guide.stroke()
            let circle = NSRect(x: handle.center.x - 7, y: handle.center.y - 7, width: 14, height: 14)
            accent.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke()
            let plus = NSBezierPath()
            plus.lineWidth = 1.5
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: handle.center.x - 3, y: handle.center.y))
            plus.line(to: NSPoint(x: handle.center.x + 3, y: handle.center.y))
            plus.move(to: NSPoint(x: handle.center.x, y: handle.center.y - 3))
            plus.line(to: NSPoint(x: handle.center.x, y: handle.center.y + 3))
            plus.stroke()
        }
        for range in bulletsForDrawing() {
            guard let rect = taskMarkerRect(range), rect.intersects(dirtyRect) else { continue }
            let side: CGFloat = 4
            taskColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)).fill()
        }
        separatorColor.setStroke()
        for range in separatorRanges where range.length > 0 && !isEditingSeparator(range) {
            guard NSMaxRange(range) <= (textStorage?.length ?? 0) else { continue }
            let glyph = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyph.length > 0 else { continue }
            let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph.location, effectiveRange: nil)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let y = rect.midY
            let start = textContainerOrigin.x + textContainer.lineFragmentPadding
            let end = bounds.width - textContainerInset.width - textContainer.lineFragmentPadding
            guard end > start, NSRect(x: start, y: y - 1, width: end - start, height: 2).intersects(dirtyRect) else { continue }
            let line = NSBezierPath()
            line.lineWidth = 1
            line.move(to: NSPoint(x: start, y: y))
            line.line(to: NSPoint(x: end, y: y))
            line.stroke()
        }
        for marker in markersForDrawing() where !(hideCompletedTasks && marker.checked && !isTaskAwaitingHide(
            at: (string as NSString).lineRange(for: NSRange(location: marker.range.location, length: 0)).location
        )) {
            guard let rect = taskMarkerRect(marker.range), rect.intersects(dirtyRect) else { continue }
            let circle = NSBezierPath(ovalIn: rect)
            circle.lineWidth = 1.3
            let lineStart = (string as NSString).lineRange(for: NSRange(location: marker.range.location, length: 0)).location
            let opacity = completionOpacities[lineStart] ?? 1
            taskColor.withAlphaComponent((marker.checked ? 0.65 : 0.8) * opacity).setStroke()
            if marker.checked {
                taskColor.withAlphaComponent(0.65 * opacity).setFill()
                circle.fill()
            } else { circle.stroke() }
            if marker.checked {
                NSColor.white.withAlphaComponent(opacity).setStroke()
                let tick = NSBezierPath()
                tick.lineWidth = 1.4
                tick.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
                tick.line(to: NSPoint(x: rect.minX + 5.5, y: rect.maxY - 3.5))
                tick.line(to: NSPoint(x: rect.maxX - 2.5, y: rect.minY + 3))
                tick.stroke()
            }
        }
        if let pending = pendingTaskPointer, pending.moved,
           let source = textStorage?.string as NSString?, pending.range.location < source.length {
            let line = source.lineRange(for: NSRange(location: pending.range.location, length: 0))
            let raw = source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = raw.replacingOccurrences(of: #"^[-*+] \[[ xX]\]\s*"#, with: "", options: .regularExpression)
            let point = convert(pending.current, from: nil)
            let width = min(max(120, bounds.width - 20), 230)
            let rect = NSRect(x: max(0, min(bounds.width - width, point.x - 12)),
                              y: max(0, min(bounds.height - 25, point.y - 12)), width: width, height: 25)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            shape.fill()
            taskColor.withAlphaComponent(0.3).setStroke()
            shape.stroke()
            let textRect = rect.insetBy(dx: 9, dy: 4)
            (label as NSString).draw(in: textRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: taskColor
            ])
        }
        for table in tableVisuals {
            guard let rect = stickyHeaderRect(table), rect.intersects(dirtyRect), let cells = table.cells.first else { continue }
            (tablePaperColor.blended(withFraction: 0.08, of: taskColor) ?? tablePaperColor).setFill()
            NSBezierPath(rect: rect).fill()
            taskColor.withAlphaComponent(0.25).setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            var x = rect.minX
            let font = NSFontManager.shared.convert(NSFont.preferredFont(forTextStyle: .body), toHaveTrait: .boldFontMask)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            for (index, width) in table.columnWidths.enumerated() {
                if index > 0 {
                    taskColor.withAlphaComponent(0.25).setStroke()
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: x, y: rect.minY))
                    line.line(to: NSPoint(x: x, y: rect.maxY))
                    line.stroke()
                }
                if index < cells.count, NSMaxRange(cells[index]) <= (string as NSString).length {
                    let value = (string as NSString).substring(with: cells[index]).trimmingCharacters(in: .whitespaces)
                    let h = (value as NSString).size(withAttributes: [.font: font]).height
                    (value as NSString).draw(in: NSRect(x: x + 8, y: rect.midY - h / 2, width: max(0, width - 16), height: h + 2),
                                             withAttributes: [.font: font, .foregroundColor: taskColor, .paragraphStyle: paragraph])
                }
                x += width
            }
        }
    }

    private func taskMarkerRect(_ range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer, range.length > 0,
              NSMaxRange(range) <= (textStorage?.length ?? 0) else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let side = min(13, max(10, line.height - 4))
        return NSRect(x: box.minX + 1, y: line.midY - side / 2, width: side, height: side)
    }

    private func reminderRects(_ range: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer, range.length > 0,
              NSMaxRange(range) <= (textStorage?.length ?? 0) else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return [] }
        var rectangles: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            guard part.length > 0 else { return }
            let rect = layoutManager.boundingRect(forGlyphRange: part, in: textContainer)
                .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            rectangles.append(rect)
        }
        return rectangles
    }
    var knownImageIDs: Set<String> = []
    var onPasteImage: ((Data, @escaping (String, Data) -> Void) -> Void)?
    private var lastImageWidth: CGFloat = 0

    func updateImageWidths(_ width: CGFloat) {
        guard width > 0, abs(width - lastImageWidth) > 0.5, let storage = textStorage else { return }
        lastImageWidth = width
        var images: [(NSRange, InlineNoteAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let image = value as? InlineNoteAttachment { images.append((range, image)) }
        }
        guard !images.isEmpty else { return }
        storage.beginEditing()
        for (range, image) in images {
            image.resize(to: width)
            storage.addAttribute(.attachment, value: image, range: range)
        }
        storage.endEditing()
    }

    func markdownSource() -> String {
        guard let storage = textStorage else { return string }
        let source = storage.string as NSString
        var result = ""
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let image = value as? InlineNoteAttachment { result += image.markdown }
            else { result += source.substring(with: range) }
        }
        return result
    }

    func setMarkdownSource(_ markdown: String, images: [String: Data]) {
        knownImageIDs = Set(images.keys)
        lastImageWidth = 0
        let source = markdown as NSString
        let result = NSMutableAttributedString(string: "")
        let expression = try? NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(tic-image://([0-9A-Fa-f-]+)\)"#)
        var location = 0
        for match in expression?.matches(in: markdown, range: NSRange(location: 0, length: source.length)) ?? [] {
            let id = source.substring(with: match.range(at: 1))
            guard let data = images[id], let image = NSImage(data: data) else { continue }
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: location, length: match.range.location - location))))
            let marker = source.substring(with: match.range)
            let attachment = InlineNoteAttachment(markdown: marker, image: image,
                                                  availableWidth: max(100, bounds.width - 16))
            result.append(NSAttributedString(attachment: attachment))
            location = NSMaxRange(match.range)
        }
        result.append(NSAttributedString(string: source.substring(from: location)))
        textStorage?.setAttributedString(result)
    }

    private func sourceOffset(forDisplayOffset offset: Int) -> Int {
        guard let storage = textStorage else { return offset }
        let limit = min(max(offset, 0), storage.length)
        var result = 0
        if limit > 0 {
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: limit)) { value, range, _ in
                result += (value as? InlineNoteAttachment).map { ($0.markdown as NSString).length } ?? range.length
            }
        }
        return result
    }

    private func displayOffset(forSourceOffset offset: Int) -> Int {
        guard let storage = textStorage else { return offset }
        var sourcePosition = 0
        var displayPosition = 0
        var found = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            let length = (value as? InlineNoteAttachment).map { ($0.markdown as NSString).length } ?? range.length
            if offset <= sourcePosition + length {
                let delta = max(0, offset - sourcePosition)
                displayPosition = range.location + ((value is InlineNoteAttachment) ? min(delta, range.length) : delta)
                found = true
                stop.pointee = true
            } else { sourcePosition += length; displayPosition = NSMaxRange(range) }
        }
        return found ? displayPosition : storage.length
    }

    func sourceSelection() -> NSRange {
        let selection = selectedRange()
        let start = sourceOffset(forDisplayOffset: selection.location)
        let end = sourceOffset(forDisplayOffset: NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }

    func setSourceSelection(_ selection: NSRange) {
        let start = displayOffset(forSourceOffset: selection.location)
        let end = displayOffset(forSourceOffset: NSMaxRange(selection))
        setSelectedRange(NSRange(location: start, length: max(0, end - start)))
    }

    static func adjustSelection(_ selection: NSRange, from old: String, to new: String) -> NSRange {
        let before = old as NSString, after = new as NSString
        var prefix = 0
        while prefix < min(before.length, after.length), before.character(at: prefix) == after.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(before.length - prefix, after.length - prefix),
              before.character(at: before.length - suffix - 1) == after.character(at: after.length - suffix - 1) { suffix += 1 }
        func mapped(_ position: Int) -> Int {
            if position <= prefix { return position }
            if position >= before.length - suffix { return max(prefix, position + after.length - before.length) }
            return after.length - suffix
        }
        let start = mapped(selection.location), end = mapped(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }

    static func mergeExternalChange(base: String, target: String, local: String) -> String {
        guard base != target else { return local }
        let before = base as NSString, after = target as NSString
        var prefix = 0
        while prefix < min(before.length, after.length), before.character(at: prefix) == after.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(before.length - prefix, after.length - prefix),
              before.character(at: before.length - suffix - 1) == after.character(at: after.length - suffix - 1) { suffix += 1 }
        let changed = NSRange(location: prefix, length: before.length - prefix - suffix)
        let replacement = after.substring(with: NSRange(location: prefix, length: after.length - prefix - suffix))
        let mapped = adjustSelection(changed, from: base, to: local)
        let localSource = local as NSString
        guard NSMaxRange(mapped) <= localSource.length else { return local }
        return localSource.replacingCharacters(in: mapped, with: replacement)
    }
    private var pendingFocus = false
    private var focusHandled: (() -> Void)?
    var onAddTask: (() -> Void)?

    override func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.pastableImageData(), let onPasteImage {
            onPasteImage(data) { [weak self] marker, thumbnail in
                guard let self, let image = NSImage(data: thumbnail), !self.hasMarkedText() else { return }
                let range = self.selectedRange()
                guard self.shouldChangeText(in: range, replacementString: "\u{FFFC}") else { return }
                let attachment = InlineNoteAttachment(markdown: marker, image: image, availableWidth: self.bounds.width - 16)
                self.textStorage?.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
                self.didChangeText()
                self.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            }
        } else if let text = NSPasteboard.general.string(forType: .string), pasteMultilineIntoTask(text) {
            return
        } else {
            pasteAsPlainText(sender)
        }
    }

    /// Treat each pasted line like Return in the current task, preserving its nesting level.
    private func pasteMultilineIntoTask(_ raw: String) -> Bool {
        guard !hasMarkedText(), let storage = textStorage else { return false }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard normalized.contains("\n") else { return false }
        let selection = selectedRange(), source = storage.string as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length,
              let marker = taskMarkers.first(where: { item in
                  guard item.range.location < source.length else { return false }
                  let line = source.lineRange(for: NSRange(location: item.range.location, length: 0))
                  let lastLineEnd = NSMaxRange(line) == source.length && source.length > 0
                      && source.character(at: source.length - 1) != 10
                  return selection.location >= NSMaxRange(item.range)
                      && (selection.location < NSMaxRange(line) || (lastLineEnd && selection.location == source.length))
                      && !hiddenTaskRanges.contains(where: { NSIntersectionRange($0, item.range).length > 0 })
              }) else { return false }
        let line = source.lineRange(for: NSRange(location: marker.range.location, length: 0))
        let indent = source.substring(with: NSRange(location: line.location, length: marker.range.location - line.location))
        let markerText = source.substring(with: marker.range)
        let bullet = markerText.first.map(String.init) ?? "-"
        let existingTask = try? NSRegularExpression(pattern: #"^[ \t]*[-*+] \[[ xX]\](?:[ \t]+|$)"#)
        let lines = normalized.components(separatedBy: "\n")
        var replacement = lines[0]
        if selection.location == NSMaxRange(marker.range),
           let match = existingTask?.firstMatch(in: replacement, range: NSRange(location: 0, length: (replacement as NSString).length)) {
            replacement = (replacement as NSString).substring(from: NSMaxRange(match.range))
        }
        for part in lines.dropFirst() {
            let alreadyTask = existingTask?.firstMatch(in: part, range: NSRange(location: 0, length: (part as NSString).length)) != nil
            replacement += "\n" + indent + (alreadyTask ? "" : "\(bullet) [ ] ") + part
        }
        breakUndoCoalescing()
        if let hidden = hiddenFragments(in: selection) {
            let kept = NSMutableAttributedString(string: replacement)
            if hidden.length > 0 && !hidden.string.hasPrefix("\n") && !replacement.hasSuffix("\n") {
                kept.append(NSAttributedString(string: "\n"))
            }
            kept.append(hidden)
            replaceAcrossHiddenTasks(in: selection, with: kept,
                                     selectionAfter: NSRange(location: selection.location + (replacement as NSString).length, length: 0))
        } else {
            insertText(replacement, replacementRange: selection)
        }
        breakUndoCoalescing()
        return true
    }

    /// Copy what is visible: omit hidden completed lines and the task-circle source markers.
    private func copyVisibleTaskSelection() -> Bool {
        guard !hasMarkedText(), let storage = textStorage else { return false }
        synchronizeTaskRangesIfNeeded()
        let selection = selectedRange()
        guard selection.location != NSNotFound, selection.length > 0, NSMaxRange(selection) <= storage.length else { return false }
        let source = storage.string as NSString
        let firstLine = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let firstTask = taskMarkers.first { marker in
            marker.range.location >= firstLine.location && marker.range.location < NSMaxRange(firstLine)
        }
        let baseIndent = firstTask.map { $0.range.location - firstLine.location } ?? 0
        let sharedIndent = taskMarkers.compactMap { marker -> NSRange? in
            guard baseIndent > 0, marker.range.location < source.length,
                  NSIntersectionRange(marker.range, selection).length > 0 else { return nil }
            let line = source.lineRange(for: NSRange(location: marker.range.location, length: 0))
            let length = min(baseIndent, marker.range.location - line.location)
            return length > 0 ? NSRange(location: line.location, length: length) : nil
        }
        let exclusions = (hiddenTaskRanges + taskMarkers.map(\.range) + sharedIndent)
            .map { NSIntersectionRange($0, selection) }.filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        guard !exclusions.isEmpty else { return false }
        var merged: [NSRange] = []
        for range in exclusions {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
            } else { merged.append(range) }
        }
        let copied = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selection))
        for range in merged.reversed() {
            copied.deleteCharacters(in: NSRange(location: range.location - selection.location, length: range.length))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copied.string, forType: .string)
        let full = NSRange(location: 0, length: copied.length)
        if let data = try? copied.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            pasteboard.setData(data, forType: .rtfd)
        } else if let data = try? copied.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(data, forType: .rtf)
        }
        return true
    }

    override func copy(_ sender: Any?) {
        let before = NSPasteboard.general.changeCount
        if !copyVisibleTaskSelection() { super.copy(sender) }
        AppModel.shared.ignoreClipboardCopy(from: window, previousChangeCount: before)
    }

    override func cut(_ sender: Any?) {
        let before = NSPasteboard.general.changeCount
        if isEditable && copyVisibleTaskSelection() { deleteBackward(sender) }
        else { super.cut(sender) }
        AppModel.shared.ignoreClipboardCopy(from: window, previousChangeCount: before)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), NSPasteboard.general.hasPastableImage { return true }
        if item.action == #selector(undoFromMenu(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redoFromMenu(_:)) { return undoManager?.canRedo == true }
        if item.action == #selector(tableActionFromMenu(_:)), let menuItem = item as? NSMenuItem,
           let action = menuItem.representedObject as? String {
            guard !hasMarkedText(), let location = tableMenuLocation, let table = tableAt(location: location) else { return false }
            if action == "deleteColumn" { return table.columnWidths.count > 1 }
            if action == "deleteRow" {
                let source = string as NSString
                let start = source.lineRange(for: NSRange(location: min(location, source.length), length: 0)).location
                guard let row = table.allRows.firstIndex(where: { $0.location == start }) else { return false }
                return row > 1 || table.allRows.count > 2
            }
            return true
        }
        if item.action == #selector(applyHeadingFromMenu(_:)) || item.action == #selector(convertListFromMenu(_:)) ||
            item.action == #selector(quoteFromMenu(_:)) || item.action == #selector(codeBlockFromMenu(_:)) ||
            item.action == #selector(insertMarkdownBlockFromMenu(_:)) || item.action == #selector(tableActionFromMenu(_:)) { return !hasMarkedText() }
        let selectionActions: [Selector] = [#selector(boldFromMenu(_:)), #selector(italicFromMenu(_:)),
            #selector(strikeFromMenu(_:)), #selector(codeFromMenu(_:)), #selector(colorFromMenu(_:)),
            #selector(chooseTextColor(_:)), #selector(fontFromMenu(_:)), #selector(chooseTextFont(_:)),
            #selector(fontSizeFromMenu(_:)), #selector(addReminderForSelection(_:)), #selector(addLinkForSelection(_:))]
        if let action = item.action, selectionActions.contains(action) { return selectedRange().length > 0 }
        return super.validateUserInterfaceItem(item)
    }
    private let slashPopover = NSPopover()
    private var slashRange: NSRange?
    private var slashCommands: [SlashCommand] = []
    private var selectedSlashCommand = 0
    private var slashUpdateScheduled = false
    private var tableMenuLocation: Int?

    func scheduleSlashMenuUpdate() {
        guard !slashUpdateScheduled else { return }
        slashUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.slashUpdateScheduled = false
            self.updateSlashMenu()
        }
    }

    private func updateSlashMenu() {
        guard !hasMarkedText(), window?.firstResponder === self,
              selectedRange().length == 0, selectedRange().location != NSNotFound else {
            slashPopover.close()
            return
        }
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        let lineStart = source.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = source.substring(with: NSRange(location: lineStart, length: caret - lineStart)) as NSString
        guard let regex = try? NSRegularExpression(pattern: #"(/([a-zA-Z]*))$"#),
              let match = regex.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length)) else {
            slashPopover.close()
            return
        }
        let slashLocation = match.range(at: 1).location
        if slashLocation > 0 {
            let previous = before.substring(with: NSRange(location: slashLocation - 1, length: 1))
            if previous == ":" || previous == "/" { slashPopover.close(); return }
        }
        let query = before.substring(with: match.range(at: 2)).lowercased()
        let commands = SlashCommand.allCases.filter {
            query.isEmpty || $0.rawValue.hasPrefix(query) || $0.title.lowercased().contains(query)
        }
        guard !commands.isEmpty else { slashPopover.close(); return }
        let oldRange = slashRange
        let nextRange = NSRange(location: lineStart + match.range(at: 1).location, length: match.range(at: 1).length)
        if oldRange != nextRange || commands != slashCommands { selectedSlashCommand = 0 }
        slashRange = nextRange
        slashCommands = commands
        presentSlashMenu()
    }

    private func presentSlashMenu() {
        guard let slashRange else { return }
        let menu = SlashCommandMenu(commands: slashCommands, selected: selectedSlashCommand) { [weak self] command in
            self?.performSlashCommand(command)
        }
        let host = NSHostingView(rootView: LocalizedRoot { menu })
        let controller = NSViewController()
        controller.view = host
        slashPopover.contentViewController = controller
        slashPopover.contentSize = NSSize(width: 260, height: CGFloat(30 + slashCommands.count * 31))
        slashPopover.behavior = .transient
        if !slashPopover.isShown {
            guard let layoutManager, let textContainer else { return }
            let characterIndex = NSMaxRange(slashRange) - 1
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: characterIndex, length: 1), actualCharacterRange: nil)
            var caret = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            caret.origin.x += textContainerOrigin.x
            caret.origin.y += textContainerOrigin.y
            caret.origin.x = caret.maxX
            caret.size.width = 1
            slashPopover.show(relativeTo: caret, of: self, preferredEdge: .maxY)
        }
    }

    private func performSlashCommand(_ command: SlashCommand) {
        guard let range = slashRange, NSMaxRange(range) <= (string as NSString).length else {
            slashPopover.close(); return
        }
        if command == .time {
            slashPopover.close()
            slashRange = nil
            showReminderPicker(replacing: range)
            return
        }
        let source = string as NSString
        let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
        let before = source.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        let prefix = before.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
        let insertion = prefix + command.replacement
        slashPopover.close()
        slashRange = nil
        guard shouldChangeText(in: range, replacementString: insertion) else { return }
        textStorage?.replaceCharacters(in: range, with: insertion)
        didChangeText()
        let cursorOffset = command == .code ? (prefix as NSString).length + 4 : (insertion as NSString).length
        setSelectedRange(NSRange(location: range.location + cursorOffset, length: 0))
        window?.makeFirstResponder(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", to destination: NSMenu? = nil, object: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.representedObject = object
            (destination ?? menu).addItem(item)
        }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = characterIndexForInsertion(at: point)
        tableMenuLocation = clicked
        if let table = tableAt(location: clicked) {
            // Keep table actions in the main menu: nested menus can be squeezed at screen edges.
            add(AppLanguage.text("在上方插入行", "Insert Row Above"), #selector(tableActionFromMenu(_:)), object: "rowAbove")
            add(AppLanguage.text("在下方插入行", "Insert Row Below"), #selector(tableActionFromMenu(_:)), object: "rowBelow")
            add(AppLanguage.text("在左侧插入列", "Insert Column Left"), #selector(tableActionFromMenu(_:)), object: "columnLeft")
            add(AppLanguage.text("在右侧插入列", "Insert Column Right"), #selector(tableActionFromMenu(_:)), object: "columnRight")
            add(AppLanguage.text("删除当前行", "Delete Row"), #selector(tableActionFromMenu(_:)), object: "deleteRow")
            add(AppLanguage.text("删除当前列", "Delete Column"), #selector(tableActionFromMenu(_:)), object: "deleteColumn")
            add(table.sticky ? AppLanguage.text("取消固定表头", "Unfreeze Header") : AppLanguage.text("固定表头", "Freeze Header"),
                #selector(tableActionFromMenu(_:)), object: "sticky")
            menu.addItem(.separator())
        }
        add(AppLanguage.text("撤销", "Undo"), #selector(undoFromMenu(_:)), key: "z")
        add(AppLanguage.text("重做", "Redo"), #selector(redoFromMenu(_:)))
        menu.addItem(.separator())
        add(AppLanguage.text("剪切", "Cut"), #selector(cut(_:)), key: "x")
        add(AppLanguage.text("复制", "Copy"), #selector(copy(_:)), key: "c")
        add(AppLanguage.text("粘贴", "Paste"), #selector(paste(_:)), key: "v")
        add(AppLanguage.text("全选", "Select All"), #selector(selectAll(_:)), key: "a")
        menu.addItem(.separator())
        let heading = NSMenu(title: AppLanguage.text("段落样式", "Paragraph Style"))
        for (label, level) in [(AppLanguage.text("正文", "Body"), 0), (AppLanguage.text("一级标题", "Heading 1"), 1),
                               (AppLanguage.text("二级标题", "Heading 2"), 2), (AppLanguage.text("三级标题", "Heading 3"), 3),
                               (AppLanguage.text("四级标题", "Heading 4"), 4), (AppLanguage.text("五级标题", "Heading 5"), 5),
                               (AppLanguage.text("六级标题", "Heading 6"), 6)] {
            add(label, #selector(applyHeadingFromMenu(_:)), to: heading, object: level)
        }
        let headingItem = NSMenuItem(title: heading.title, action: nil, keyEquivalent: "")
        headingItem.submenu = heading
        menu.addItem(headingItem)
        let lists = NSMenu(title: AppLanguage.text("转换为列表", "Convert to List"))
        for (label, style) in [(AppLanguage.text("任务", "Task"), "task"),
                               (AppLanguage.text("无序列表", "Bulleted List"), "bullet"),
                               (AppLanguage.text("有序列表", "Numbered List"), "numbered")] {
            add(label, #selector(convertListFromMenu(_:)), to: lists, object: style)
        }
        let listsItem = NSMenuItem(title: lists.title, action: nil, keyEquivalent: "")
        listsItem.submenu = lists
        menu.addItem(listsItem)
        add(AppLanguage.text("引用", "Quote"), #selector(quoteFromMenu(_:)))
        add(AppLanguage.text("代码块", "Code Block"), #selector(codeBlockFromMenu(_:)))
        let insert = NSMenu(title: AppLanguage.text("插入", "Insert"))
        add(AppLanguage.text("分割线", "Divider"), #selector(insertMarkdownBlockFromMenu(_:)), to: insert, object: "divider")
        add(AppLanguage.text("表格", "Table"), #selector(insertMarkdownBlockFromMenu(_:)), to: insert, object: "table")
        let insertItem = NSMenuItem(title: insert.title, action: nil, keyEquivalent: "")
        insertItem.submenu = insert
        menu.addItem(insertItem)
        add(AppLanguage.text("粗体", "Bold"), #selector(boldFromMenu(_:)), key: "b")
        add(AppLanguage.text("斜体", "Italic"), #selector(italicFromMenu(_:)), key: "i")
        add(AppLanguage.text("删除线", "Strikethrough"), #selector(strikeFromMenu(_:)))
        add(AppLanguage.text("行内代码", "Inline Code"), #selector(codeFromMenu(_:)))
        let colors = NSMenu(title: AppLanguage.text("文字颜色", "Text Color"))
        add(AppLanguage.text("默认颜色", "Default Color"), #selector(colorFromMenu(_:)), to: colors, object: "inherit")
        colors.addItem(.separator())
        for (label, hex) in [("黑色", "252525"), ("灰色", "707780"), ("红色", "D63838"), ("橙色", "C46A14"),
                             ("绿色", "28834C"), ("蓝色", "1769C2"), ("紫色", "884BB0")] {
            add(AppLanguage.isChinese ? label : ["黑色":"Black", "灰色":"Gray", "红色":"Red", "橙色":"Orange", "绿色":"Green", "蓝色":"Blue", "紫色":"Purple"][label] ?? label,
                #selector(colorFromMenu(_:)), to: colors, object: hex)
        }
        colors.addItem(.separator())
        add(AppLanguage.text("自选颜色…", "Choose Color…"), #selector(chooseTextColor(_:)), to: colors)
        let colorItem = NSMenuItem(title: colors.title, action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        let fontMenu = NSMenu(title: AppLanguage.text("字体", "Font"))
        for (label, family) in [(AppLanguage.text("系统字体", "System"), "system-ui"), ("苹方", "PingFang SC"),
                                ("黑体", "Heiti SC"), ("宋体", "Songti SC"), ("Helvetica", "Helvetica"),
                                ("Georgia", "Georgia"), (AppLanguage.text("等宽", "Monospace"), "Menlo")] {
            if NSFontManager.shared.availableFontFamilies.contains(family) || family == "system-ui" {
                add(label, #selector(fontFromMenu(_:)), to: fontMenu, object: family)
            }
        }
        fontMenu.addItem(.separator())
        add(AppLanguage.text("更多字体…", "Show Fonts…"), #selector(chooseTextFont(_:)), to: fontMenu)
        let fontItem = NSMenuItem(title: fontMenu.title, action: nil, keyEquivalent: "")
        fontItem.submenu = fontMenu
        menu.addItem(fontItem)
        let sizes = NSMenu(title: AppLanguage.text("字号", "Font Size"))
        for size in [10, 12, 14, 16, 18, 20, 24, 28, 36] {
            add("\(size)", #selector(fontSizeFromMenu(_:)), to: sizes, object: size)
        }
        let sizeItem = NSMenuItem(title: sizes.title, action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)
        if selectedRange().length > 0 {
            menu.addItem(.separator())
            add(AppLanguage.text("添加链接…", "Add Link…"), #selector(addLinkForSelection(_:)))
            add(AppLanguage.text("添加提醒…", "Add Reminder…"), #selector(addReminderForSelection(_:)))
        }
        return menu
    }

    @objc private func undoFromMenu(_ sender: Any?) { undoManager?.undo() }
    @objc private func redoFromMenu(_ sender: Any?) { undoManager?.redo() }
    @objc private func boldFromMenu(_ sender: Any?) { applyInlineFormat(.bold) }
    @objc private func italicFromMenu(_ sender: Any?) { applyInlineFormat(.italic) }
    @objc private func strikeFromMenu(_ sender: Any?) { applyInlineFormat(.strikethrough) }
    @objc private func codeFromMenu(_ sender: Any?) { applyInlineFormat(.code) }

    private func tableAt(location: Int) -> MarkdownTableVisual? {
        guard tableVisualSource == string else { return nil }
        let source = string as NSString
        guard location >= 0, location <= source.length else { return nil }
        let start = source.lineRange(for: NSRange(location: location, length: 0)).location
        return tableVisuals.first { $0.allRows.contains(where: { $0.location == start }) }
    }

    @objc private func tableActionFromMenu(_ sender: NSMenuItem) {
        guard !hasMarkedText(), let action = sender.representedObject as? String,
              let location = tableMenuLocation, let table = tableAt(location: location),
              let first = table.allRows.first, let last = table.allRows.last,
              let storage = textStorage else { return }
        let source = string as NSString
        let currentLine = source.lineRange(for: NSRange(location: min(location, source.length), length: 0)).location
        guard let row = table.allRows.firstIndex(where: { $0.location == currentLine }), table.allRows.count >= 2 else { return }
        let affected = NSRange(location: first.location, length: NSMaxRange(source.lineRange(for: last)) - first.location)
        guard !hiddenTaskRanges.contains(where: { NSIntersectionRange($0, affected).length > 0 }) else { NSSound.beep(); return }
        var hasAttachment = false
        storage.enumerateAttribute(.attachment, in: affected) { value, _, stop in
            if value != nil { hasAttachment = true; stop.pointee = true }
        }
        guard !hasAttachment else { NSSound.beep(); return }
        breakUndoCoalescing()
        if action == "sticky" {
            if let marker = table.stickyMarker {
                insertText("", replacementRange: marker)
                setSelectedRange(NSRange(location: max(0, location - marker.length), length: 0))
            } else {
                let marker = stickyTableMarker + "\n\n"
                insertText(marker, replacementRange: NSRange(location: first.location, length: 0))
                setSelectedRange(NSRange(location: location + (marker as NSString).length, length: 0))
            }
            breakUndoCoalescing()
            return
        }
        let count = table.columnWidths.count
        guard count > 0, table.cells.count == table.allRows.count else { return }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: affected))
        var caret = location
        if action == "rowAbove" || action == "rowBelow" {
            let target = row <= 1 ? 1 : (action == "rowAbove" ? row - 1 : row)
            let selected = table.allRows[target]
            let insertion = NSMaxRange(source.lineRange(for: selected))
            let suffix = insertion == source.length && (insertion == 0 || source.character(at: insertion - 1) != 10) ? "\n" : ""
            let newRow = suffix + "|" + String(repeating: "  |", count: count) + "\n"
            replacement.mutableString.insert(newRow, at: insertion - affected.location)
            caret = insertion + (suffix as NSString).length + 2
        } else if action == "deleteRow" {
            if row <= 1 {
                // Markdown tables require a header. Promote the first body row when deleting it.
                guard table.allRows.count > 2 else { return }
                let promoted = table.allRows[2]
                let body = storage.attributedSubstring(from: promoted)
                let bodyEnd = min(NSMaxRange(affected), NSMaxRange(source.lineRange(for: promoted)))
                replacement.deleteCharacters(in: NSRange(location: promoted.location - affected.location, length: bodyEnd - promoted.location))
                replacement.replaceCharacters(in: NSRange(location: first.location - affected.location, length: first.length), with: body)
                caret = first.location
            } else {
                let selected = table.allRows[row]
                let end = min(NSMaxRange(affected), NSMaxRange(source.lineRange(for: selected)))
                replacement.deleteCharacters(in: NSRange(location: selected.location - affected.location, length: end - selected.location))
                caret = min(selected.location, affected.location + replacement.length)
            }
        } else if action == "deleteColumn" {
            guard count > 1 else { return }
            let cells = table.cells[min(row, table.cells.count - 1)]
            let column = max(0, min(count - 1, cells.lastIndex(where: { location >= $0.location }) ?? 0))
            for index in table.allRows.indices.reversed() {
                let rowCells = table.cells[index]
                guard column < rowCells.count, rowCells.count > 1 else { continue }
                let cell = rowCells[column]
                let deletion: NSRange
                if column + 1 < rowCells.count {
                    deletion = NSRange(location: cell.location, length: rowCells[column + 1].location - cell.location)
                } else {
                    guard cell.location > table.allRows[index].location, source.character(at: cell.location - 1) == 124 else { return }
                    deletion = NSRange(location: cell.location - 1, length: NSMaxRange(cell) - cell.location + 1)
                }
                guard deletion.location >= affected.location, NSMaxRange(deletion) <= NSMaxRange(affected) else { return }
                replacement.deleteCharacters(in: NSRange(location: deletion.location - affected.location, length: deletion.length))
                if deletion.location < caret { caret -= min(deletion.length, caret - deletion.location) }
            }
        } else if action == "columnLeft" || action == "columnRight" {
            let cells = table.cells[min(row, table.cells.count - 1)]
            let currentColumn = max(0, min(count - 1, cells.lastIndex(where: { location >= $0.location }) ?? 0))
            let targetColumn = action == "columnLeft" ? currentColumn : currentColumn + 1
            for index in table.allRows.indices.reversed() {
                let rowRange = table.allRows[index], rowCells = table.cells[index]
                guard !rowCells.isEmpty else { continue }
                let fragment = index == 1 ? " --- " : "  "
                let insertion: Int
                let newText: String
                if targetColumn < rowCells.count {
                    insertion = rowCells[targetColumn].location
                    newText = fragment + "|"
                } else {
                    insertion = NSMaxRange(rowCells.last!)
                    newText = "|" + fragment
                }
                guard insertion >= rowRange.location, insertion <= NSMaxRange(rowRange) else { return }
                replacement.mutableString.insert(newText, at: insertion - affected.location)
                if insertion <= caret { caret += (newText as NSString).length }
            }
        } else { return }
        insertText(replacement, replacementRange: affected)
        setSelectedRange(NSRange(location: min(caret, affected.location + replacement.length), length: 0))
        breakUndoCoalescing()
    }

    /// Apply block formatting to complete lines, preserving other notes and hidden tasks.
    private func markdownBlockSelection() -> NSRange? {
        guard !hasMarkedText(), let storage = textStorage else { return nil }
        synchronizeTaskRangesIfNeeded()
        let source = string as NSString, selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return nil }
        let start = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let endLocation = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let end = NSMaxRange(source.lineRange(for: NSRange(location: endLocation, length: 0)))
        let range = NSRange(location: start, length: end - start)
        guard !hiddenTaskRanges.contains(where: { NSIntersectionRange(range, $0).length > 0 }) else { NSSound.beep(); return nil }
        var hasAttachment = false
        if range.length > 0 {
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if value != nil { hasAttachment = true; stop.pointee = true }
            }
        }
        guard !hasAttachment else { NSSound.beep(); return nil }
        return range
    }

    @objc private func quoteFromMenu(_ sender: Any?) {
        guard let range = markdownBlockSelection() else { return }
        let source = string as NSString
        let text = source.substring(with: range)
        let lines = text.components(separatedBy: "\n")
        let nonempty = lines.filter { !$0.isEmpty }
        let remove = !nonempty.isEmpty && nonempty.allSatisfy { $0.hasPrefix("> ") }
        let replacement = lines.enumerated().map { index, line -> String in
            if index == lines.count - 1 && line.isEmpty { return line }
            if remove { return line.hasPrefix("> ") ? String(line.dropFirst(2)) : line }
            return "> " + line
        }.joined(separator: "\n")
        breakUndoCoalescing()
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
        breakUndoCoalescing()
    }

    @objc private func codeBlockFromMenu(_ sender: Any?) {
        guard let range = markdownBlockSelection() else { return }
        let text = (string as NSString).substring(with: range)
        let trailingNewline = text.hasSuffix("\n")
        let content = trailingNewline ? String(text.dropLast()) : text
        let runs = content.split(whereSeparator: { $0 != "`" }).map(\.count)
        let fence = String(repeating: "`", count: max(3, (runs.max() ?? 0) + 1))
        let replacement = fence + "\n" + content + "\n" + fence + (trailingNewline ? "\n" : "")
        breakUndoCoalescing()
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + (fence as NSString).length + 1, length: (content as NSString).length))
        breakUndoCoalescing()
    }

    @objc private func insertMarkdownBlockFromMenu(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String, let range = markdownBlockSelection() else { return }
        let source = string as NSString
        let location = NSMaxRange(range)
        let needsNewline = location > 0 && source.character(at: location - 1) != 10
        let prefix = needsNewline ? "\n" : ""
        let body = kind == "table" ? AppLanguage.text("| 列 1 | 列 2 |\n| --- | --- |\n|  |  |\n", "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |\n") : "---\n"
        let insertion = prefix + body
        breakUndoCoalescing()
        insertText(insertion, replacementRange: NSRange(location: location, length: 0))
        let offset = kind == "table" ? (prefix as NSString).length + 2 : (insertion as NSString).length
        setSelectedRange(NSRange(location: location + offset, length: 0))
        breakUndoCoalescing()
    }

    /// Convert complete selected paragraphs, preserving indentation, text attributes and hidden tasks.
    @objc private func convertListFromMenu(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String, !hasMarkedText(), let storage = textStorage else { return }
        synchronizeTaskRangesIfNeeded()
        let source = storage.string as NSString, selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return }
        let start = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let end = NSMaxRange(source.lineRange(for: NSRange(location: last, length: 0)))
        let affected = NSRange(location: start, length: end - start)
        guard affected.length > 0 else { return }
        guard let prefix = try? NSRegularExpression(
            pattern: #"^([ \t]*)(?:(?:[-*+] \[[ xX]\]|[-*+]|[0-9]+[.)]|#{1,6})[ \t]+)?"#
        ) else { return }
        let task = Self.taskLineRegex
        var replacements: [(NSRange, String)] = []
        var ordinal: [Int: Int] = [:]
        var fence = MarkdownFenceScanner()
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, lineRange, _, _ in
            guard let line else { return }
            if fence.consume(line) { return }
            guard !fence.isInside, NSIntersectionRange(lineRange, affected).length > 0,
                  !self.hiddenTaskRanges.contains(where: { NSIntersectionRange($0, lineRange).length > 0 }),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let text = line as NSString, range = NSRange(location: 0, length: text.length)
            guard let match = prefix.firstMatch(in: line, range: range) else { return }
            let indent = text.substring(with: match.range(at: 1))
            let existingTask = task.firstMatch(in: line, range: range)
            let marker: String
            switch style {
            case "task":
                let mark = existingTask.map { text.substring(with: $0.range(at: 2)) } ?? " "
                marker = "- [\(mark)] "
            case "bullet": marker = "- "
            case "numbered":
                let level = indent.count
                ordinal = ordinal.filter { $0.key <= level }
                let number = (ordinal[level] ?? 0) + 1
                ordinal[level] = number
                marker = "\(number). "
            default: return
            }
            replacements.append((NSRange(location: lineRange.location, length: match.range.length), indent + marker))
        }
        guard !replacements.isEmpty else { return }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: affected))
        for (range, value) in replacements.reversed() {
            replacement.replaceCharacters(in: NSRange(location: range.location - start, length: range.length), with: value)
        }
        let selectionAfter: NSRange
        if selection.length == 0 {
            var cursor = selection.location
            for (range, value) in replacements where range.location <= selection.location {
                let newLength = (value as NSString).length
                cursor += selection.location < NSMaxRange(range)
                    ? newLength - (selection.location - range.location) : newLength - range.length
            }
            selectionAfter = NSRange(location: min(start + replacement.length, max(start, cursor)), length: 0)
        } else {
            selectionAfter = NSRange(location: start, length: replacement.length)
        }
        breakUndoCoalescing()
        if hiddenTaskRanges.contains(where: { NSIntersectionRange($0, affected).length > 0 }) {
            replaceAcrossHiddenTasks(in: affected, with: replacement,
                                     selectionAfter: selectionAfter)
        } else {
            insertText(replacement, replacementRange: affected)
            setSelectedRange(selectionAfter)
        }
        breakUndoCoalescing()
    }

    @objc private func applyHeadingFromMenu(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Int, (0...6).contains(level), !hasMarkedText() else { return }
        let source = string as NSString, selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return }
        let paragraphs = source.lineRange(for: selection)
        guard !hiddenTaskRanges.contains(where: { NSIntersectionRange(paragraphs, $0).length > 0 }) else { NSSound.beep(); return }
        let lines = source.substring(with: paragraphs).components(separatedBy: "\n")
        let replacement = lines.map { line -> String in
            guard !line.isEmpty else { return line }
            let body = line.replacingOccurrences(of: #"^#{1,6}[ \t]+"#, with: "", options: .regularExpression)
            return level == 0 ? body : String(repeating: "#", count: level) + " " + body
        }.joined(separator: "\n")
        insertText(replacement, replacementRange: paragraphs)
        setSelectedRange(NSRange(location: paragraphs.location, length: (replacement as NSString).length))
    }

    @objc private func colorFromMenu(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        applyTextStyle(hex == "inherit" ? "color:inherit" : "color:#\(hex)")
    }
    @objc private func fontFromMenu(_ sender: NSMenuItem) {
        guard let family = sender.representedObject as? String else { return }
        applyTextStyle("font-family:\(family)")
    }
    @objc private func fontSizeFromMenu(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Int else { return }
        applyTextStyle("font-size:\(size)px")
    }

    private func captureStyleSelection() -> StylePanelSelection? {
        let selection = selectedRange(), source = string as NSString
        guard !hasMarkedText(), selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= source.length else { return nil }
        guard !hiddenTaskRanges.contains(where: { NSIntersectionRange(selection, $0).length > 0 }) else { NSSound.beep(); return nil }
        var attachment = false
        textStorage?.enumerateAttribute(.attachment, in: selection) { value, _, stop in
            if value != nil { attachment = true; stop.pointee = true }
        }
        guard !attachment else { NSSound.beep(); return nil }
        return StylePanelSelection(original: source.substring(with: selection), expected: string, range: selection)
    }

    private func styledText(_ text: String, style: String) -> String {
        let opening = "<span style=\"\(style)\">", closing = "</span>"
        return text.components(separatedBy: "\n").map { line in
            guard !line.isEmpty else { return line }
            // Leave heading/list syntax at the beginning of each paragraph intact.
            let prefix = line.range(of: #"^[ \t]*(?:#{1,6}[ \t]+|[-*+] \[[ xX]\][ \t]+|[-*+][ \t]+|[0-9]+\.[ \t]+|>[ \t]+)"#,
                                    options: .regularExpression)
            if let prefix {
                let head = String(line[prefix]), body = String(line[prefix.upperBound...])
                return body.isEmpty ? head : head + opening + body + closing
            }
            return opening + line + closing
        }.joined(separator: "\n")
    }

    private func applyTextStyle(_ style: String) {
        guard var selection = captureStyleSelection() else { return }
        replaceStyleSelection(&selection, style: style)
    }

    private func replaceStyleSelection(_ selection: inout StylePanelSelection, style: String) {
        guard string == selection.expected, NSMaxRange(selection.range) <= (string as NSString).length else { return }
        let replacement = styledText(selection.original, style: style)
        let start = selection.range.location
        let before = string
        let opening = ("<span style=\"\(style)\">" as NSString).length
        let nextSelection = !selection.original.contains("\n") && replacement.hasPrefix("<span ")
            ? NSRange(location: start + opening, length: (selection.original as NSString).length)
            : NSRange(location: start, length: (replacement as NSString).length)
        insertText(replacement, replacementRange: selection.range)
        guard string != before else { return }
        setSelectedRange(nextSelection)
        selection.range = NSRange(location: start, length: (replacement as NSString).length)
        selection.expected = string
    }

    @objc private func chooseTextColor(_ sender: Any?) {
        guard let selection = captureStyleSelection() else { return }
        colorPanelSelection = selection
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(textColorDidChange(_:)))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func textColorDidChange(_ sender: NSColorPanel) {
        guard var selection = colorPanelSelection, let color = sender.color.usingColorSpace(.sRGB) else { return }
        func component(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        let hex = String(format: "%02X%02X%02X", component(color.redComponent),
                         component(color.greenComponent), component(color.blueComponent))
        replaceStyleSelection(&selection, style: "color:#\(hex)")
        colorPanelSelection = selection
    }

    @objc private func chooseTextFont(_ sender: Any?) {
        guard let selection = captureStyleSelection() else { return }
        fontPanelSelection = selection
        let manager = NSFontManager.shared
        manager.target = self
        let font = (textStorage?.attribute(.font, at: selection.range.location, effectiveRange: nil) as? NSFont)
            ?? NSFont.preferredFont(forTextStyle: .body)
        manager.setSelectedFont(font, isMultiple: false)
        NSApp.activate()
        manager.orderFrontFontPanel(nil)
        manager.fontPanel(true)?.makeKeyAndOrderFront(nil)
    }

    override func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager, var selection = fontPanelSelection else { return }
        let chosen = manager.convert(NSFont.preferredFont(forTextStyle: .body))
        guard let family = chosen.familyName,
              family.rangeOfCharacter(from: CharacterSet(charactersIn: "\"<>;")) == nil else { return }
        let traits = manager.traits(of: chosen)
        let size = min(144, max(8, Int(chosen.pointSize.rounded())))
        let weight = traits.contains(.boldFontMask) ? "bold" : "normal"
        let italic = traits.contains(.italicFontMask) ? "italic" : "normal"
        replaceStyleSelection(&selection, style: "font-family:\(family);font-size:\(size)px;font-weight:\(weight);font-style:\(italic)")
        fontPanelSelection = selection
    }

    @objc private func addLinkForSelection(_ sender: Any?) {
        guard let selected = captureStyleSelection(), let layoutManager, let textContainer else { return }
        guard !selected.original.contains("\n"), !selected.original.contains("\r"),
              !selected.original.contains("]") else {
            let alert = NSAlert()
            alert.messageText = AppLanguage.text("请选择单行文字", "Select text on one line")
            alert.informativeText = AppLanguage.text("链接文字不能跨行或包含右方括号。", "Link text cannot contain a line break or a closing bracket.")
            alert.runModal()
            return
        }
        let source = selected.expected as NSString
        let line = source.lineRange(for: selected.range)
        let expression = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^\s)]+|mailto:[^\s)]+)\)"#)
        let existing = expression?.matches(in: selected.expected, range: line).first { $0.range(at: 1) == selected.range }
        let replaceRange = existing?.range ?? selected.range
        let initialURL = existing.map { source.substring(with: $0.range(at: 2)) } ?? ""
        let popover = NSPopover()
        let picker = LinkEditor(initialURL: initialURL, editing: existing != nil, save: { [weak self, weak popover] url in
            guard let self, self.string == selected.expected,
                  NSMaxRange(replaceRange) <= (self.string as NSString).length else { return }
            let replacement = "[\(selected.original)](\(url))"
            self.breakUndoCoalescing()
            self.insertText(replacement, replacementRange: replaceRange)
            self.breakUndoCoalescing()
            self.setSelectedRange(NSRange(location: replaceRange.location + 1, length: (selected.original as NSString).length))
            popover?.close()
            self.window?.makeFirstResponder(self)
        }, cancel: { [weak popover] in popover?.close() })
        let controller = NSViewController()
        controller.view = NSHostingView(rootView: LocalizedRoot { picker })
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 320, height: 146)
        popover.behavior = .transient
        linkPopover = popover
        let glyph = layoutManager.glyphIndexForCharacter(at: selected.range.location)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    private var linkPopover: NSPopover?

    @objc private func addReminderForSelection(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else { return }
        showReminderPicker(replacing: NSRange(location: NSMaxRange(selection), length: 0))
    }

    private func showReminderPicker(replacing range: NSRange, editing: Bool = false) {
        guard let layoutManager, let textContainer, NSMaxRange(range) <= (string as NSString).length else { return }
        let snapshot = string
        let popover = NSPopover()
        let original = (snapshot as NSString).substring(with: range)
        let savedDate = editing ? ReminderScheduler.formatter().date(from: original.replacingOccurrences(of: "⏰", with: "").trimmingCharacters(in: .whitespaces)) : nil
        let remove: (() -> Void)? = editing ? { [weak self, weak popover] in
            guard let self, self.string == snapshot else { return }
            self.insertText("", replacementRange: range)
            popover?.close()
            self.window?.makeFirstResponder(self)
        } : nil
        let view = ReminderPicker(date: savedDate ?? Date().addingTimeInterval(3600), save: { [weak self, weak popover] date in
            guard let self else { return }
            Task { @MainActor in
                do {
                    guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                        let alert = NSAlert()
                        alert.messageText = AppLanguage.text("请在系统设置中允许 Tico 通知", "Allow Tico notifications in System Settings")
                        alert.runModal()
                        return
                    }
                    let formatter = ReminderScheduler.formatter()
                    let formatted = formatter.string(from: date)
                    guard self.string == snapshot, let rounded = formatter.date(from: formatted), rounded > Date() else { return }
                    let marker = (editing ? "⏰ " : " ⏰ ") + formatted
                    self.insertText(marker, replacementRange: range)
                    popover?.close()
                    self.window?.makeFirstResponder(self)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }, remove: remove)
        let controller = NSViewController()
        controller.view = NSHostingView(rootView: LocalizedRoot { view })
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 280, height: 130)
        popover.behavior = .transient
        reminderPopover = popover
        let glyph = layoutManager.glyphIndexForCharacter(at: max(0, min(range.location, max(0, (string as NSString).length - 1))))
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    private var reminderPopover: NSPopover?

    override func keyDown(with event: NSEvent) {
        if slashPopover.isShown && !hasMarkedText() {
            switch event.keyCode {
            case 125, 126: // Down / Up
                let delta = event.keyCode == 125 ? 1 : -1
                selectedSlashCommand = (selectedSlashCommand + delta + slashCommands.count) % slashCommands.count
                presentSlashMenu()
                return
            case 36, 76, 48: // Return / keypad Enter / Tab
                if !slashCommands.isEmpty { performSlashCommand(slashCommands[selectedSlashCommand]); return }
            case 53: // Escape
                slashPopover.close()
                slashRange = nil
                return
            default: break
            }
        }
        if !hasMarkedText(), handleLinkArrow(event) { return }
        if !hasMarkedText(), handleTaskKey(event) { return }
        if !hasMarkedText(), handleListKey(event) { return }
        super.keyDown(with: event)
    }

    private func handleListKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let selection = selectedRange(), source = string as NSString
        guard selection.length == 0, selection.location != NSNotFound, selection.location <= source.length else { return false }
        let lineRange = source.lineRange(for: selection)
        var fence = MarkdownFenceScanner()
        for line in source.substring(to: lineRange.location).components(separatedBy: .newlines) { _ = fence.consume(line) }
        guard !fence.isInside else { return false }
        let line = source.substring(with: lineRange) as NSString
        let search = NSRange(location: 0, length: line.length)
        guard Self.taskLineRegex.firstMatch(in: line as String, range: search) == nil,
              let match = Self.listLineRegex.firstMatch(in: line as String, range: search),
              selection.location >= lineRange.location + NSMaxRange(match.range) else { return false }
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            breakUndoCoalescing()
            undoManager?.beginUndoGrouping()
            defer { undoManager?.endUndoGrouping(); breakUndoCoalescing() }
            let text = line.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range.length))
            } else {
                let indent = line.substring(with: match.range(at: 1))
                let marker = line.substring(with: match.range(at: 2))
                let next: String
                if let last = marker.last, let number = Int(marker.dropLast()), number < 999_999_999 {
                    next = "\(number + 1)\(last)"
                } else { next = marker }
                insertText("\n" + indent + next + " ", replacementRange: selection)
            }
            normalizeOrderedGroup(near: selectedRange().location)
            return true
        }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            breakUndoCoalescing()
            undoManager?.beginUndoGrouping()
            defer { undoManager?.endUndoGrouping(); breakUndoCoalescing() }
            let indentation = line.substring(with: match.range(at: 1))
            if modifiers == .shift {
                let removed = indentation.hasPrefix("\t") ? 1 : min(2, indentation.prefix(while: { $0 == " " }).count)
                if removed > 0 {
                    insertText("", replacementRange: NSRange(location: lineRange.location, length: removed))
                    setSelectedRange(NSRange(location: selection.location - removed, length: 0))
                }
            } else {
                insertText("  ", replacementRange: NSRange(location: lineRange.location, length: 0))
                setSelectedRange(NSRange(location: selection.location + 2, length: 0))
            }
            normalizeOrderedGroup(near: selectedRange().location)
            return true
        }
        return false
    }

    /// Persist corrected numbers as one undoable edit with the initiating Return/Tab.
    private func normalizeOrderedGroup(near location: Int) {
        guard let storage = textStorage else { return }
        synchronizeTaskRangesIfNeeded()
        let source = string as NSString
        let markers = orderedListMarkers(in: source)
        let position = max(0, min(location, source.length))
        let lineStart = source.lineRange(for: NSRange(location: position, length: 0)).location
        let current = markers.first(where: { source.lineRange(for: $0.marker).location == lineStart })
            ?? markers.last(where: { NSMaxRange(source.lineRange(for: $0.marker)) == lineStart })
        guard let current else { return }
        let group = markers.filter { $0.group == current.group }
        guard let first = group.first, let last = group.last else { return }
        let start = source.lineRange(for: first.marker).location
        let end = NSMaxRange(source.lineRange(for: last.marker))
        let range = NSRange(location: start, length: end - start)
        guard !hiddenTaskRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
        let changed = group.filter { source.substring(with: $0.digits) != String($0.number) }
        guard !changed.isEmpty else { return }
        let oldSelection = selectedRange()
        var newLocation = oldSelection.location
        for item in changed where item.digits.location < oldSelection.location {
            newLocation += (String(item.number) as NSString).length - item.digits.length
        }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        for item in changed.reversed() {
            replacement.mutableString.replaceCharacters(in: NSRange(location: item.digits.location - start, length: item.digits.length),
                                                        with: String(item.number))
        }
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: max(start, min(start + replacement.length, newLocation)), length: oldSelection.length))
    }

    /// Skip hidden Markdown link delimiters so arrow keys move by visible characters.
    private func handleLinkArrow(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let selection = selectedRange(), source = string as NSString
        guard flags.isEmpty, (event.keyCode == 123 || event.keyCode == 124),
              selection.length == 0, selection.location != NSNotFound, selection.location <= source.length else { return false }
        let line = source.lineRange(for: selection)
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^\s)]+|mailto:[^\s)]+)\)"#) else { return false }
        for match in regex.matches(in: string, range: line) {
            let label = match.range(at: 1), whole = match.range
            if event.keyCode == 123, selection.location > NSMaxRange(label), selection.location <= NSMaxRange(whole) {
                let character = source.rangeOfComposedCharacterSequence(at: NSMaxRange(label) - 1)
                setSelectedRange(NSRange(location: character.location, length: 0))
                return true
            }
            if event.keyCode == 123, selection.location > whole.location, selection.location <= label.location {
                let afterTaskMarker = taskMarkers.contains { NSMaxRange($0.range) == whole.location }
                let previous = whole.location > 0 && !afterTaskMarker && source.character(at: whole.location - 1) != 10
                    ? source.rangeOfComposedCharacterSequence(at: whole.location - 1).location : whole.location
                setSelectedRange(NSRange(location: previous, length: 0))
                return true
            }
            if event.keyCode == 124, selection.location >= whole.location, selection.location < label.location {
                let character = source.rangeOfComposedCharacterSequence(at: label.location)
                setSelectedRange(NSRange(location: NSMaxRange(character), length: 0))
                return true
            }
            if event.keyCode == 124, selection.location >= NSMaxRange(label), selection.location < NSMaxRange(whole) {
                let end = NSMaxRange(whole)
                let next = end < source.length && source.character(at: end) != 10
                    ? NSMaxRange(source.rangeOfComposedCharacterSequence(at: end)) : end
                setSelectedRange(NSRange(location: next, length: 0))
                return true
            }
        }
        return false
    }

    /// Markdown tasks remain ordinary editable text; Return and Tab only extend their syntax.
    private func handleTaskKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let selection = selectedRange()
        let source = string as NSString
        guard selection.length == 0, selection.location <= source.length else { return false }
        let lineRange = source.lineRange(for: selection)
        let previousLines = source.substring(to: lineRange.location).components(separatedBy: .newlines)
        var fence = MarkdownFenceScanner()
        for line in previousLines { _ = fence.consume(line) }
        guard !fence.isInside else { return false }
        let line = source.substring(with: lineRange)
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+]) \[([ xX])\](?:[ \t]+|$)"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return false }
        let value = line as NSString
        let indent = value.substring(with: match.range(at: 1))
        let safeCursor = max(selection.location, lineRange.location + NSMaxRange(match.range))
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            let remainder = value.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty {
                let prefix = NSRange(location: lineRange.location, length: match.range.length)
                guard shouldChangeText(in: prefix, replacementString: "") else { return true }
                textStorage?.replaceCharacters(in: prefix, with: "")
                didChangeText()
                setSelectedRange(NSRange(location: prefix.location, length: 0))
            } else {
                insertText("\n" + indent + value.substring(with: match.range(at: 2)) + " [ ] ", replacementRange: selection)
            }
            return true
        }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            changeTaskIndent(at: lineRange.location + match.range.location + match.range(at: 1).length,
                             outdent: modifiers == .shift, caret: safeCursor)
            return true
        }
        return false
    }

    func requestFocusWhenReady(_ handled: @escaping () -> Void) {
        pendingFocus = true
        focusHandled = handled
        focusWhenAttached()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        focusWhenAttached()
    }

    private func focusWhenAttached() {
        guard pendingFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFocus, let window = self.window else { return }
            if window.makeFirstResponder(self) {
                self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
                self.pendingFocus = false
                self.focusHandled?()
                self.focusHandled = nil
            }
        }
    }

    func applyInlineFormat(_ format: MarkdownInlineFormat) {
        guard !hasMarkedText() else { return }
        let source = string as NSString
        let selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return }
        guard !hiddenTaskRanges.contains(where: { NSIntersectionRange(selection, $0).length > 0 }) else { NSSound.beep(); return }
        var containsAttachment = false
        if selection.length > 0 {
            textStorage?.enumerateAttribute(.attachment, in: selection) { value, _, stop in
                if value is InlineNoteAttachment { containsAttachment = true; stop.pointee = true }
            }
        }
        guard !containsAttachment else { NSSound.beep(); return }
        let marker = format.marker
        let markerLength = (marker as NSString).length
        let selectedText = source.substring(with: selection)
        let replacement: String
        let newSelection: NSRange
        if selection.length >= markerLength * 2 && selectedText.hasPrefix(marker) && selectedText.hasSuffix(marker) {
            let selected = selectedText as NSString
            replacement = selected.substring(with: NSRange(location: markerLength, length: selected.length - markerLength * 2))
            newSelection = NSRange(location: selection.location, length: (replacement as NSString).length)
        } else if selection.location >= markerLength && NSMaxRange(selection) + markerLength <= source.length,
                  source.substring(with: NSRange(location: selection.location - markerLength, length: markerLength)) == marker,
                  source.substring(with: NSRange(location: NSMaxRange(selection), length: markerLength)) == marker {
            let enclosing = NSRange(location: selection.location - markerLength, length: selection.length + markerLength * 2)
            insertText(selectedText, replacementRange: enclosing)
            setSelectedRange(NSRange(location: enclosing.location, length: selection.length))
            window?.makeFirstResponder(self)
            return
        } else {
            replacement = marker + selectedText + marker
            newSelection = NSRange(location: selection.location + markerLength, length: selection.length)
        }
        insertText(replacement, replacementRange: selection)
        setSelectedRange(newSelection)
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command, !hasMarkedText() {
            if event.keyCode == 11 { applyInlineFormat(.bold); return true }
            if event.keyCode == 34 { applyInlineFormat(.italic); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard !string.isEmpty else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = insertionHandle(at: point) {
            tableInsertionHandle = nil
            tableMenuLocation = handle.anchor
            let item = NSMenuItem()
            item.representedObject = handle.action
            tableActionFromMenu(item)
            needsDisplay = true
            return
        }
        if let table = tableVisuals.first(where: { stickyHeaderRect($0)?.contains(point) == true }),
           let rect = stickyHeaderRect(table), let cells = table.cells.first, !cells.isEmpty {
            var edge = rect.minX
            var column = 0
            for (index, width) in table.columnWidths.enumerated() {
                edge += width
                column = min(index, cells.count - 1)
                if point.x < edge { break }
            }
            let cell = cells[column]
            window?.makeFirstResponder(self)
            scrollRangeToVisible(cell)
            setSelectedRange(NSRange(location: min(NSMaxRange(cell), cell.location + 1), length: 0))
            return
        }
        if let reminder = reminderRanges.first(where: { reminderRects($0).contains { $0.insetBy(dx: -3, dy: -2).contains(point) } }) {
            reminderClickInProgress = true
            showReminderPicker(replacing: reminder, editing: true)
            return
        }
        if let marker = taskMarkers.first(where: { marker in
            !(hideCompletedTasks && marker.checked && !isTaskAwaitingHide(
                at: (string as NSString).lineRange(for: NSRange(location: marker.range.location, length: 0)).location
            )) && taskMarkerRect(marker.range)?.insetBy(dx: -4, dy: -4).contains(point) == true
        }) {
            window?.makeFirstResponder(self)
            pendingTaskPointer = (marker.range, event.locationInWindow, event.locationInWindow, false)
            return
        }
        // The indentation before a task is a gutter, not editable whitespace. Ignore clicks
        // there rather than briefly placing the caret and correcting it after a selection change.
        if taskMarkers.contains(where: { marker in
            guard !(hideCompletedTasks && marker.checked && !isTaskAwaitingHide(
                at: (string as NSString).lineRange(for: NSRange(location: marker.range.location, length: 0)).location
            )) else { return false }
            guard let rect = taskMarkerRect(marker.range) else { return false }
            return point.x < rect.minX - 4 && point.y >= rect.minY - 4 && point.y <= rect.maxY + 4
        }) { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if reminderClickInProgress { return }
        guard var pending = pendingTaskPointer else { return super.mouseDragged(with: event) }
        pending.current = event.locationInWindow
        if hypot(event.locationInWindow.x - pending.start.x, event.locationInWindow.y - pending.start.y) >= 5 {
            pending.moved = true
            NSCursor.closedHand.set()
        }
        pendingTaskPointer = pending
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if reminderClickInProgress { reminderClickInProgress = false; return }
        guard let pending = pendingTaskPointer else { return super.mouseUp(with: event) }
        pendingTaskPointer = nil
        needsDisplay = true
        if pending.moved {
            if !separateCompletedTasks {
                moveMarkdownTask(marker: pending.range, to: convert(event.locationInWindow, from: nil))
            }
            NSCursor.arrow.set()
        } else {
            toggleMarkdownTask(pending.range)
        }
    }

    private struct TaskLine {
        let line: NSRange
        let indent: NSRange
        let mark: NSRange
        let level: Int
        let checked: Bool
    }

    /// Adjacent Markdown task lines form an outline; prose separates independent outlines.
    private func taskRun(containing marker: NSRange) -> (lines: [TaskLine], index: Int)? {
        let source = string as NSString
        var groups: [[TaskLine]] = []
        for item in taskMarkers {
            guard item.range.location < source.length, NSMaxRange(item.range) <= source.length else { continue }
            let line = source.lineRange(for: NSRange(location: item.range.location, length: 0))
            let markerText = source.substring(with: item.range) as NSString
            let bracket = markerText.range(of: "[")
            guard bracket.location != NSNotFound, bracket.location + 1 < markerText.length else { continue }
            let leading = source.substring(with: NSRange(location: line.location, length: item.range.location - line.location))
            let columns = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let entry = TaskLine(line: line,
                                 indent: NSRange(location: line.location, length: item.range.location - line.location),
                                 mark: NSRange(location: item.range.location + bracket.location + 1, length: 1),
                                 level: min(TaskItem.maxIndentLevel, columns / 2), checked: item.checked)
            if let last = groups.last?.last, NSMaxRange(last.line) == line.location {
                groups[groups.count - 1].append(entry)
            } else { groups.append([entry]) }
        }
        for lines in groups {
            if let index = lines.firstIndex(where: { NSLocationInRange(marker.location, $0.line) }) {
                return (lines, index)
            }
        }
        return nil
    }

    private func changeTaskIndent(at markerLocation: Int, outdent: Bool, caret: Int) {
        guard let storage = textStorage,
              let run = taskRun(containing: NSRange(location: markerLocation, length: 0)) else { return }
        let noteID = UUID()
        let tasks = run.lines.enumerated().map { index, line in
            TaskItem(noteId: noteID, isDone: line.checked, sortIndex: index, indentLevel: line.level)
        }
        let updated = outdent ? TaskOutline.outdenting(tasks, id: tasks[run.index].id)
                              : TaskOutline.indenting(tasks, id: tasks[run.index].id)
        let changes = zip(run.lines, updated).filter { $0.0.level != $0.1.indentLevel }
        guard let first = changes.first, let last = changes.last else { return }
        let affected = NSRange(location: first.0.line.location,
                               length: NSMaxRange(last.0.line) - first.0.line.location)
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: affected))
        for (line, task) in changes.reversed() {
            replacement.mutableString.replaceCharacters(
                in: NSRange(location: line.indent.location - affected.location, length: line.indent.length),
                with: String(repeating: "  ", count: task.indentLevel))
        }
        guard shouldChangeText(in: affected, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: affected, with: replacement)
        didChangeText()
        let delta = updated[run.index].indentLevel * 2 - run.lines[run.index].indent.length
        setSelectedRange(NSRange(location: max(0, min(storage.length, caret + delta)), length: 0))
    }

    private func toggleMarkdownTask(_ marker: NSRange) {
        guard let storage = textStorage, let run = taskRun(containing: marker) else { return }
        let noteID = UUID()
        let tasks = run.lines.enumerated().map { index, line in
            TaskItem(noteId: noteID, isDone: line.checked, sortIndex: index, indentLevel: line.level)
        }
        let updated = TaskOutline.applyingToggle(tasks, toggling: tasks[run.index].id, now: Date())
        if separateCompletedTasks && !hideCompletedTasks {
            replaceTaskRun(run.lines, original: tasks, updated: updated)
            return
        }
        let changes = zip(run.lines, updated).filter { $0.0.checked != $0.1.isDone }
        guard let first = changes.first, let last = changes.last else { return }
        let affected = NSRange(location: first.0.mark.location, length: NSMaxRange(last.0.mark) - first.0.mark.location)
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: affected))
        for (line, task) in changes.reversed() {
            replacement.mutableString.replaceCharacters(in: NSRange(location: line.mark.location - affected.location, length: 1),
                                                         with: task.isDone ? "x" : " ")
        }
        guard shouldChangeText(in: affected, replacementString: replacement.string) else { return }
        let newlyCompleted = hideCompletedTasks ? changes.filter { $0.1.isDone }.map { $0.0.line.location } : []
        if hideCompletedTasks {
            let now = ProcessInfo.processInfo.systemUptime
            for (line, task) in changes {
                if task.isDone { completionStarts[line.line.location] = now }
                else { completionStarts.removeValue(forKey: line.line.location) }
            }
            recentlyCompleted = Set(completionStarts.keys)
        }
        isTogglingCompletion = true
        storage.replaceCharacters(in: affected, with: replacement)
        didChangeText()
        isTogglingCompletion = false
        // Start the visible hold after layout has caught up, even in a long note.
        let ready = ProcessInfo.processInfo.systemUptime
        for location in newlyCompleted { completionStarts[location] = ready }
        if completionStarts.isEmpty {
            stopCompletionAnimation()
            if separateCompletedTasks { separateAllTaskGroups() }
        } else {
            captureCompletionLines()
            startCompletionAnimation()
        }
    }

    /// A text edit can change line offsets. Finish the visual transition before applying it;
    /// the underlying task state was saved as soon as the checkbox was clicked.
    @discardableResult
    func cancelCompletionAnimationForEdit() -> Bool {
        guard !completionStarts.isEmpty else { return false }
        stopCompletionAnimation()
        return true
    }

    private func stopCompletionAnimation() {
        completionTimer?.invalidate()
        completionTimer = nil
        completionStarts.removeAll()
        completionLines.removeAll()
        completionOpacities.removeAll()
        recentlyCompleted.removeAll()
        completionSource = nil
    }

    private func captureCompletionLines() {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        let source = storage.string as NSString
        layout.ensureLayout(for: container)
        completionLines = completionStarts.compactMap { location, started in
            guard location < source.length else { return nil }
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
            let paragraph = (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
                ?? NSParagraphStyle.default
            let glyph = layout.glyphIndexForCharacter(at: location)
            let height = max(paragraph.minimumLineHeight, layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height)
            var colors: [(NSRange, NSColor)] = []
            storage.enumerateAttribute(.foregroundColor, in: range) { value, part, _ in
                if let color = value as? NSColor { colors.append((part, color)) }
            }
            return CompletionLine(range: range, started: started, lineHeight: max(1, height), paragraph: paragraph, colors: colors)
        }
        completionSource = storage.string
    }

    private func startCompletionAnimation() {
        guard completionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                self?.advanceCompletionAnimation()
            }
        }
        completionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceCompletionAnimation() {
        guard let storage = textStorage, storage.string == completionSource, !hasMarkedText(), hideCompletedTasks else {
            stopCompletionAnimation()
            refreshTaskStyle?()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var finished = true
        isApplyingCompletionFrame = true
        storage.beginEditing()
        for line in completionLines {
            guard NSMaxRange(line.range) <= storage.length else { continue }
            // Leave the check visible briefly, then fade and close its space together.
            let progress = min(1, max(0, (now - line.started - 0.16) / 0.30))
            if progress < 1 { finished = false }
            let eased = CGFloat(progress * progress * (3 - 2 * progress))
            let opacity = 1 - eased
            completionOpacities[line.range.location] = opacity
            for (range, color) in line.colors where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * opacity), range: range)
            }
            guard let paragraph = line.paragraph.mutableCopy() as? NSMutableParagraphStyle else { continue }
            let height = max(0.1, line.lineHeight * opacity)
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            paragraph.lineSpacing *= opacity
            paragraph.paragraphSpacing *= opacity
            paragraph.paragraphSpacingBefore *= opacity
            storage.addAttribute(.paragraphStyle, value: paragraph, range: line.range)
        }
        storage.endEditing()
        isApplyingCompletionFrame = false
        needsDisplay = true
        if trackAnimatedContentHeight { (enclosingScrollView as? MarkdownEditorScrollView)?.reportContentHeight() }
        if finished {
            stopCompletionAnimation()
            if separateCompletedTasks { separateAllTaskGroups() }
            refreshTaskStyle?()
        }
    }

    /// Partition sibling subtrees within each contiguous Markdown task group. Headings and prose
    /// remain in place, and a parent always travels with its descendants.
    func separateAllTaskGroups() {
        guard separateCompletedTasks, !hasMarkedText() else { return }
        let markers = taskMarkers.map(\.range)
        var visited = Set<Int>()
        var runs: [[TaskLine]] = []
        for marker in markers {
            guard let run = taskRun(containing: marker), let first = run.lines.first,
                  visited.insert(first.line.location).inserted else { continue }
            runs.append(run.lines)
        }
        for lines in runs.reversed() {
            let noteID = UUID()
            let tasks = lines.enumerated().map { index, line in
                TaskItem(noteId: noteID, isDone: line.checked, sortIndex: index, indentLevel: line.level)
            }
            replaceTaskRun(lines, original: tasks, updated: tasks)
        }
    }

    private func replaceTaskRun(_ lines: [TaskLine], original: [TaskItem], updated: [TaskItem]) {
        guard let storage = textStorage, let first = lines.first, let last = lines.last,
              lines.count == original.count, original.count == updated.count else { return }
        let sorted = TaskOutline.sortedCompletedToBottom(updated)
        let indices = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($0.element.id, $0.offset) })
        let source = storage.string as NSString
        let range = NSRange(location: first.line.location, length: NSMaxRange(last.line) - first.line.location)
        guard NSMaxRange(range) <= storage.length else { return }
        let endsInNewline = range.length > 0 && source.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n"
        let result = NSMutableAttributedString(string: "")
        for (position, task) in sorted.enumerated() {
            guard let index = indices[task.id] else { return }
            let line = lines[index]
            let hasNewline = line.line.length > 0 && source.substring(with: NSRange(location: NSMaxRange(line.line) - 1, length: 1)) == "\n"
            let length = line.line.length - (hasNewline ? 1 : 0)
            let fragment = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: NSRange(location: line.line.location, length: length)))
            fragment.mutableString.replaceCharacters(in: NSRange(location: line.mark.location - line.line.location, length: 1),
                                                     with: task.isDone ? "x" : " ")
            result.append(fragment)
            if position < sorted.count - 1 || endsInNewline { result.append(NSAttributedString(string: "\n")) }
        }
        guard result.string != source.substring(with: range) else { return }
        editingTaskStructure = true
        defer { editingTaskStructure = false }
        guard shouldChangeText(in: range, replacementString: result.string) else { return }
        storage.replaceCharacters(in: range, with: result)
        didChangeText()
    }

    private func moveMarkdownTask(marker: NSRange, to point: NSPoint) {
        guard let layoutManager, let textContainer, let storage = textStorage else { return }
        let source = storage.string as NSString
        guard marker.location < source.length else { return }
        var block = source.lineRange(for: NSRange(location: marker.location, length: 0))
        let initialLine = source.substring(with: block) as NSString
        let indent = initialLine.range(of: #"^[ \t]*"#, options: .regularExpression).length
        // Include consecutive nested task lines, without taking surrounding prose along.
        while NSMaxRange(block) < source.length {
            let next = source.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            let text = source.substring(with: next)
            guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)[-*+] \[[ xX]\]"#),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
                  match.range(at: 1).length > indent else { break }
            block.length = NSMaxRange(next) - block.location
        }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = min(layoutManager.characterIndex(for: local, in: textContainer,
                                                    fractionOfDistanceBetweenInsertionPoints: nil), source.length)
        let target = source.lineRange(for: NSRange(location: index, length: 0))
        let run = taskRun(containing: marker)
        let originalLevel = run.map { $0.lines[$0.index].level } ?? min(TaskItem.maxIndentLevel, indent / 2)
        let markerX = taskMarkerRect(marker)?.midX ?? point.x
        let horizontalSteps = Int(((point.x - markerX) / NoteLayout.indentStep).rounded())
        if target.location >= block.location && target.location < NSMaxRange(block) {
            if horizontalSteps != 0 {
                changeTaskIndent(at: marker.location, outdent: horizontalSteps < 0, caret: NSMaxRange(marker))
            }
            return
        }
        let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: min(target.location, max(0, source.length - 1)), length: 1), actualCharacterRange: nil)
        let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph.location, effectiveRange: nil)
        let after = local.y > rect.midY
        // The first line is the note title; moving a task never places it before that title.
        let destination = target.location == 0 && source.substring(with: target)
            .range(of: #"^[ \t]*[-*+] \[[ xX]\]"#, options: .regularExpression) == nil
            ? NSMaxRange(target) : (after ? NSMaxRange(target) : target.location)
        let result = NSMutableAttributedString(attributedString: storage)
        let fragment = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: block))
        result.deleteCharacters(in: block)
        let position = destination > block.location ? destination - block.length : destination
        guard position >= 0, position <= result.length else { return }
        if let run {
            let descendants = run.lines.dropFirst(run.index).prefix { $0.line.location < NSMaxRange(block) }
            let depth = max(0, (descendants.map(\.level).max() ?? originalLevel) - originalLevel)
            var allowed = 0
            if position > 0 {
                let remaining = result.string as NSString
                let preceding = remaining.lineRange(for: NSRange(location: position - 1, length: 0))
                let text = remaining.substring(with: preceding)
                if let regex = try? NSRegularExpression(pattern: #"^([ \t]*)[-*+] \[[ xX]\]"#),
                   let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    let whitespace = (text as NSString).substring(with: match.range(at: 1))
                    let columns = whitespace.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
                    allowed = min(TaskItem.maxIndentLevel, columns / 2 + 1)
                }
            }
            let newLevel = max(0, min(originalLevel + horizontalSteps, allowed, TaskItem.maxIndentLevel - depth))
            let shift = newLevel - originalLevel
            if shift != 0 {
                for line in descendants.reversed() {
                    fragment.mutableString.replaceCharacters(
                        in: NSRange(location: line.indent.location - block.location, length: line.indent.length),
                        with: String(repeating: "  ", count: max(0, line.level + shift)))
                }
            }
        }
        if position > 0, (result.string as NSString).substring(with: NSRange(location: position - 1, length: 1)) != "\n" {
            fragment.insert(NSAttributedString(string: "\n"), at: 0)
        }
        if position < result.length, !fragment.string.hasSuffix("\n") {
            fragment.append(NSAttributedString(string: "\n"))
        }
        result.insert(fragment, at: position)
        let all = NSRange(location: 0, length: storage.length)
        guard shouldChangeText(in: all, replacementString: result.string) else { return }
        storage.setAttributedString(result)
        didChangeText()
        setSelectedRange(NSRange(location: min(position, storage.length), length: 0))
    }
}

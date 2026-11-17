import Foundation

/// A bounded editable window into a clipboard note. Offsets are UTF-16, matching TextKit.
/// The full source stays in the note; pages never become separate persisted records.
enum ClipboardMarkdownPages {
    static let pageSize = 12_000
    /// Look only this far around a page boundary; avoid scanning an entire large note on each edit.
    static let maximumProtectedImageReferenceLength = pageSize * 2

    static func first(in text: String) -> NSRange? {
        let length = (text as NSString).length
        guard length > pageSize else { return nil }
        return next(in: text, from: 0)
    }

    static func next(in text: String, from start: Int) -> NSRange {
        let source = text as NSString
        let start = min(max(0, start), source.length)
        let remaining = source.length - start
        guard remaining > pageSize else { return NSRange(location: start, length: remaining) }
        let candidate = NSRange(location: start, length: pageSize)
        let newline = source.rangeOfCharacter(from: .newlines, options: .backwards, range: candidate)
        let end: Int
        if newline.location != NSNotFound && newline.location >= start + pageSize / 2 {
            end = NSMaxRange(newline)
        } else {
            // Never split a surrogate pair or an extended grapheme cluster.
            end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: start + pageSize - 1))
        }
        let safeEnd = imageSafeBoundary(in: source, at: end, pageEdge: start, forward: true)
        return NSRange(location: start, length: safeEnd - start)
    }

    static func previous(in text: String, before end: Int) -> NSRange {
        let source = text as NSString
        let end = min(max(0, end), source.length)
        guard end > pageSize else { return NSRange(location: 0, length: end) }
        let tentative = end - pageSize
        let search = NSRange(location: tentative, length: min(pageSize / 2, end - tentative))
        let newline = source.rangeOfCharacter(from: .newlines, options: [], range: search)
        let start: Int
        if newline.location != NSNotFound {
            start = NSMaxRange(newline)
        } else {
            start = source.rangeOfComposedCharacterSequence(at: tentative).location
        }
        let safeStart = imageSafeBoundary(in: source, at: start, pageEdge: end, forward: false)
        return NSRange(location: safeStart, length: end - safeStart)
    }

    /// Keep ordinary `tic-image` references together. Work is bounded even for malformed or
    /// extraordinarily long markup; such markup remains intact in the stored document.
    private static func imageSafeBoundary(in source: NSString, at boundary: Int, pageEdge: Int, forward: Bool) -> Int {
        let low = max(0, boundary - maximumProtectedImageReferenceLength)
        let high = min(source.length, boundary + maximumProtectedImageReferenceLength)
        let opening = source.range(of: "![", options: .backwards,
                                   range: NSRange(location: low, length: boundary - low))
        guard opening.location != NSNotFound else { return boundary }
        let altStart = NSMaxRange(opening)
        let altRange = NSRange(location: altStart, length: high - altStart)
        let bracket = source.rangeOfCharacter(from: CharacterSet(charactersIn: "]\n\r"), options: [], range: altRange)
        guard bracket.location != NSNotFound, source.character(at: bracket.location) == 93 else { return boundary }
        let prefix = "](tic-image://" as NSString
        guard bracket.location + prefix.length <= high,
              source.substring(with: NSRange(location: bracket.location, length: prefix.length)) == prefix as String else { return boundary }
        let idStart = bracket.location + prefix.length
        let closing = source.range(of: ")", options: [], range: NSRange(location: idStart, length: high - idStart))
        guard closing.location != NSNotFound else { return boundary }
        let end = NSMaxRange(closing)
        guard opening.location < boundary, boundary < end,
              end - opening.location <= maximumProtectedImageReferenceLength else { return boundary }
        let identifier = source.substring(with: NSRange(location: idStart, length: closing.location - idStart))
        guard !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) }) else {
            return boundary
        }
        if forward { return opening.location > pageEdge ? opening.location : end }
        return end < pageEdge ? end : opening.location
    }

    static func replacing(_ range: NSRange, in text: String, with page: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: page)
    }

    /// Choose a bounded page that contains the caret after an unusually large edit.
    static func pageContainingCaret(in text: String, caret: Int) -> NSRange {
        let source = text as NSString
        let caret = min(max(0, caret), source.length)
        guard caret > 0 else { return next(in: text, from: 0) }
        let end = imageSafeBoundary(in: source, at: caret, pageEdge: caret, forward: true)
        return previous(in: text, before: end)
    }

    /// While the input method is composing, keep the whole old segment plus inserted text so the
    /// editor sees a single insertion instead of an insertion and a simultaneous truncation.
    static func afterExternalChange(_ range: NSRange, old: String, new: String, composing: Bool) -> NSRange? {
        if range.location == 0 && !composing { return first(in: new) }
        let mapped = MarkdownEditingTextView.adjustSelection(range, from: old, to: new)
        let length = (new as NSString).length
        return NSMaxRange(mapped) <= length && mapped.length > 0 ? mapped : first(in: new)
    }
}

import Foundation

/// A bounded editable window into a clipboard note. Offsets are UTF-16, matching TextKit.
/// The full source stays in the note; pages never become separate persisted records.
enum ClipboardMarkdownPages {
    static let pageSize = 12_000

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
        return NSRange(location: start, length: end - start)
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
        return NSRange(location: start, length: end - start)
    }

    static func replacing(_ range: NSRange, in text: String, with page: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: page)
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

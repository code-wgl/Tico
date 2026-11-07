import Foundation

/// Text formats keep note text editable; JSON remains the lossless Tic backup format.
enum NotePortableFormat {
    static func data(for archive: NoteArchive, format: NoteExportFormat) throws -> Data {
        if format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(archive)
        }
        var markdown = archive.note.markdown
        for image in archive.inlineImages {
            let replacement = format == .markdown ? try imageURL(image.data) : "tic-omitted-image"
            markdown = markdown.replacingOccurrences(of: "tic-image://\(image.id)", with: replacement)
        }
        let taskImages = Dictionary(uniqueKeysWithValues: archive.taskImages.map { ($0.taskId, $0.data) })
        if !archive.tasks.isEmpty {
            var lines: [String] = []
            for task in archive.tasks {
                let level = max(0, task.indentLevel)
                let parts = task.text.components(separatedBy: "\n")
                var line = String(repeating: "  ", count: level) + (task.isDone ? "- [x] " : "- [ ] ") + (parts.first ?? "")
                if let image = taskImages[task.id] {
                    line += format == .markdown ? " ![image](\(try imageURL(image)))" : " [图片]"
                }
                for continuation in parts.dropFirst() {
                    line += "\n" + String(repeating: "  ", count: level + 2) + continuation
                }
                lines.append(line)
            }
            if !markdown.isEmpty && !markdown.hasSuffix("\n") { markdown += "\n" }
            if !markdown.isEmpty { markdown += "\n" }
            markdown += lines.joined(separator: "\n")
        }
        if format == .markdown && archive.note.hideCompleted {
            markdown = markingHiddenTasks(in: markdown)
        }
        if format == .text {
            markdown = markdown.replacingOccurrences(of: #"!\[[^\]\n]*\]\(tic-omitted-image\)"#, with: "[图片]", options: .regularExpression)
            // Text exports keep the words without exposing the editor's HTML style markup.
            if let spans = try? NSRegularExpression(pattern: #"<span style=\"(?:color:(?:#[0-9a-fA-F]{6}|inherit)|font-family:[^\"<>;]+(?:;font-size:[0-9]{1,3}px)?(?:;font-weight:(?:bold|normal))?(?:;font-style:(?:italic|normal))?|font-size:[0-9]{1,3}px)\">(.*?)</span>"#, options: [.dotMatchesLineSeparators]) {
                while true {
                    let result = spans.stringByReplacingMatches(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length), withTemplate: "$1")
                    if result == markdown { break }
                    markdown = result
                }
            }
        }
        return Data(markdown.utf8)
    }

    /// Hidden tasks are still exported. Mark their text as completed without editing the note.
    private static func markingHiddenTasks(in markdown: String) -> String {
        guard let task = try? NSRegularExpression(pattern: #"^([ \t]*[-*+] \[[xX]\][ \t]+)(.*?)([ \t]*\r?)$"#) else { return markdown }
        var fence: String?
        return markdown.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let delimiter = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            if let delimiter {
                if fence == nil { fence = delimiter }
                else if fence == delimiter { fence = nil }
                return line
            }
            guard fence == nil else { return line }
            let source = line as NSString
            guard let match = task.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return line }
            let text = source.substring(with: match.range(at: 2))
            guard !text.isEmpty, !(text.hasPrefix("~~") && text.hasSuffix("~~")) else { return line }
            return source.substring(with: match.range(at: 1)) + "~~" + text + "~~" + source.substring(with: match.range(at: 3))
        }.joined(separator: "\n")
    }

    /// Convert self-contained data-URL images to Tic's stored image references before import.
    static func archive(markdown: String, fallbackTitle: String) throws -> NoteArchive {
        let source = markdown as NSString
        let regex = try NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(data:image/(?:png|jpeg|gif|tiff|webp);base64,([A-Za-z0-9+/=]+)\)"#, options: .caseInsensitive)
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: source.length))
        let converted = NSMutableString(string: markdown)
        var images: [NoteArchive.InlineImage] = []
        for match in matches.reversed() {
            guard let data = Data(base64Encoded: source.substring(with: match.range(at: 2))), !data.isEmpty,
                  data.count <= 100 * 1024 * 1024, let thumbnail = TaskImage.thumbnail(data).flatMap(TaskImage.pngData) else { throw NoteArchiveError.invalid }
            let id = UUID().uuidString
            images.append(.init(id: id, data: data, thumbnail: thumbnail))
            let alt = source.substring(with: match.range(at: 1))
            converted.replaceCharacters(in: match.range, with: "![\(alt)](tic-image://\(id))")
        }
        let text = converted as String
        let first = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = first.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        return NoteArchive(note: Note(title: title.isEmpty ? fallbackTitle : String(title.prefix(120)), markdown: text), tasks: [], inlineImages: images, taskImages: [])
    }

    private static func imageURL(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(12))
        let type: String
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) { type = "png" }
        else if bytes.starts(with: [0xff, 0xd8, 0xff]) { type = "jpeg" }
        else if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { type = "gif" }
        else if bytes.starts(with: [0x49, 0x49, 0x2a, 0x00]) || bytes.starts(with: [0x4d, 0x4d, 0x00, 0x2a]) { type = "tiff" }
        else if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), bytes.count >= 12, Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { type = "webp" }
        else {
            guard let image = TaskImage.fullImage(data), let png = TaskImage.pngData(image) else { throw NoteArchiveError.missingImage }
            return "data:image/png;base64,\(png.base64EncodedString())"
        }
        return "data:image/\(type);base64,\(data.base64EncodedString())"
    }
}

import Foundation

/// Edits scalar frontmatter properties without rewriting unrelated YAML or body.
enum LiteraturePageEditor {
    struct Property: Equatable, Sendable { var key: String; var value: String; var raw: String; var editable: Bool }
    private static let begin = "<!-- lumen-reading-notes:begin -->"
    private static let end = "<!-- lumen-reading-notes:end -->"
    static func properties(_ text: String) throws -> [Property] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" || lines.first == "---\r" else { return [] }
        guard let finish = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "---\r" }) else { throw LiteratureNoteError.malformed }
        var result: [Property] = []; var i = 1
        while i < finish {
            let line = lines[i]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = String(line[..<colon]); let start = i
            i += 1
            while i < finish {
                if lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") { i += 1; continue }
                if lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var next = i + 1
                    while next < finish && lines[next].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next += 1 }
                    if next < finish && (lines[next].hasPrefix(" ") || lines[next].hasPrefix("\t")) { i = next; continue }
                }
                break
            }
            guard !result.contains(where: { $0.key == key }) else { throw LiteratureNoteError.malformed }
            let raw = lines[start..<i].joined(separator: "\n")
            let token = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = token; var editable = key != "itemLink"
            if token.hasPrefix("\"") {
                if let data = token.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) { value = decoded }
                else { editable = false }
            } else if token.hasPrefix("'") && token.hasSuffix("'") {
                value = String(token.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else if token == "|" || token == "|-" || token == ">" || token == ">-" {
                value = lines[(start + 1)..<i].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: token.hasPrefix(">") ? " " : "\n")
            } else if token.hasPrefix("[") || token.hasPrefix("{") || i > start + 1 || token.contains(" #") || token.hasPrefix("&") || token.hasPrefix("*") || token.hasPrefix("!") { editable = false }
            result.append(Property(key: key, value: value, raw: raw, editable: editable))
        }
        return result
    }
    static func set(_ text: String, key: String, value: String?, expected: Property?) throws -> String {
        guard key != "itemLink", key.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} _-]*$"#, options: .regularExpression) != nil else { throw LiteratureNoteError.invalidText }
        let existing = try properties(text).first { $0.key == key }
        guard existing == expected, existing?.editable != false else { throw LiteratureFileError.noteChanged }
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let replacement = try value.map { key + ": " + String(decoding: try encoder.encode($0), as: UTF8.self) }
        var output = text
        if let existing {
            guard let range = output.range(of: "\n" + existing.raw + "\n") else { throw LiteratureNoteError.malformed }
            output.replaceSubrange(range, with: replacement.map { "\n" + $0 + "\n" } ?? "\n")
        } else if let replacement {
            if output.hasPrefix("---\n") || output.hasPrefix("---\r\n") {
                output.insert(contentsOf: replacement + "\n", at: output.index(output.startIndex, offsetBy: (output.hasPrefix("---\r\n") ? "---\r\n" : "---\n").count))
            }
            else { output = "---\n" + replacement + "\n---\n\n" + output }
        }
        return output
    }
    private static func compactNotes(_ text: String) -> String {
        text.replacingOccurrences(of: begin, with: LiteratureNoteCodec.compactMarker(begin))
            .replacingOccurrences(of: end, with: LiteratureNoteCodec.compactMarker(end))
    }
    private static func legacyNotes(_ text: String) -> String {
        text.replacingOccurrences(of: LiteratureNoteCodec.compactMarker(begin), with: begin)
            .replacingOccurrences(of: LiteratureNoteCodec.compactMarker(end), with: end)
    }
    /// Attach only the verified identity; metadata ownership is handled separately.
    static func attachZotero(_ text: String, identity: LiteratureZoteroIdentity) throws -> String {
        var output = text
        let existingLink = try properties(output).first { $0.key == "itemLink" }
        if existingLink != nil {
            guard LiteratureNoteIndex.itemLink(in: output) == identity.itemLink else { throw LiteratureFileError.duplicatePages }
        } else {
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            let value = String(decoding: try encoder.encode(identity.itemLink), as: UTF8.self)
            if output.hasPrefix("---\n") || output.hasPrefix("---\r\n") {
                let newline = output.hasPrefix("---\r\n") ? "\r\n" : "\n"
                output.insert(contentsOf: "itemLink: " + value + newline, at: output.index(output.startIndex, offsetBy: ("---" + newline).count))
            } else { output = "---\nitemLink: " + value + "\n---\n\n" + output }
        }
        return output
    }

    /// Fill known fields immediately. Refresh values we previously supplied,
    /// preserving user edits, custom properties, ratings and reading notes.
    static func refreshMetadata(_ text: String, identity: LiteratureZoteroIdentity,
                                previous: LiteratureZoteroIdentity?, addMissing: Bool = true) throws -> String {
        var output = text
        let fields = [("标题", identity.title, previous?.title), ("作者", identity.authors, previous?.authors),
                      ("日期", identity.year, previous?.year), ("期刊", identity.journal ?? "", previous?.journal)]
        for (key, value, old) in fields where !value.isEmpty {
            let property = try properties(output).first { $0.key == key }
            if (property == nil && previous == nil && addMissing) || (property?.editable == true && (property?.value.isEmpty == true || property?.value == old)) {
                output = try set(output, key: key, value: value, expected: property)
            }
        }
        return output
    }

    static func readingNotes(_ text: String) throws -> String? {
        let text = legacyNotes(text)
        let starts = text.components(separatedBy: begin).count - 1
        let ends = text.components(separatedBy: end).count - 1
        guard starts == ends, starts <= 1 else { throw LiteratureNoteError.malformed }
        guard starts == 1 else { return nil }
        guard let a = text.range(of: begin + "\n"), let b = text.range(of: "\n" + end, range: a.upperBound..<text.endIndex) else { throw LiteratureNoteError.malformed }
        return String(text[a.upperBound..<b.lowerBound])
    }
    static func setReadingNotes(_ text: String, value: String, expected: String?) throws -> String {
        let text = legacyNotes(text)
        guard !value.contains("<!-- lumen-"), !value.contains("%% lumen-") else { throw LiteratureNoteError.invalidText }
        guard try readingNotes(text) == expected else { throw LiteratureFileError.noteChanged }
        if let a = text.range(of: begin + "\n"), let b = text.range(of: "\n" + end, range: a.upperBound..<text.endIndex) {
            var output = text; output.replaceSubrange(a.upperBound..<b.lowerBound, with: value); return compactNotes(output)
        }
        return compactNotes(placingReadingNotes(in: text, value: value))
    }

    /// Move only our delimited reading notes. Personal prose and annotation
    /// blocks remain byte-for-byte intact; remove obsolete headings only.
    static func arrangePage(_ text: String) throws -> String {
        let text = legacyNotes(text)
        let notes = try readingNotes(text) ?? ""
        var output = text
        if let a = output.range(of: begin + "\n"),
           let b = output.range(of: "\n" + end, range: a.upperBound..<output.endIndex) {
            var start = a.lowerBound
            let prefix = output[..<start]
            for heading in ["## 阅读笔记\n\n", "## 阅读笔记\n"] where prefix.hasSuffix(heading) {
                start = output.index(start, offsetBy: -heading.count)
                break
            }
            output.removeSubrange(start..<b.upperBound)
        }
        var insideManagedBlock = false
        output = output.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("<!-- lumen-"), line.hasSuffix(":begin -->") { insideManagedBlock = true }
            defer {
                if line.hasPrefix("<!-- lumen-"), line.hasSuffix(":end -->") { insideManagedBlock = false }
            }
            return insideManagedBlock || !["## 我的整理", "## 文献信息"].contains(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }.joined(separator: "\n")
        // Trim only whitespace adjacent to our removed/generated boundaries.
        output = output.replacingOccurrences(of: #"\n{3,}(?=(?:<!--|%%) lumen-attachment:)"#, with: "\n\n", options: .regularExpression)
        return compactNotes(placingReadingNotes(in: output.trimmingCharacters(in: .newlines) + "\n", value: notes))
    }

    private static func placingReadingNotes(in text: String, value: String) -> String {
        let section = "## 阅读笔记\n\n" + begin + "\n" + value + "\n" + end + "\n\n"
        // Match attachment starts only, not text containing a Lumen URL.
        if let first = text.range(of: #"(?m)^(?:<!-- lumen-attachment:[A-Za-z0-9_-]+:begin -->|%% lumen-attachment:[A-Za-z0-9_-]+:begin %%)"#, options: .regularExpression) {
            var output = text
            output.insert(contentsOf: section, at: first.lowerBound)
            return output
        }
        return text + (text.hasSuffix("\n\n") ? "" : "\n\n") + section
    }
}

enum LiteratureRating {
    static func value(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        if let value = Int(trimmed), (0...5).contains(value) { return value }
        if trimmed.count <= 5, trimmed.allSatisfy({ $0 == "★" || $0 == "☆" }) {
            return trimmed.filter { $0 == "★" }.count
        }
        return nil
    }
    static func text(_ value: Int) -> String {
        let rating = min(5, max(0, value))
        return String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating)
    }
    static func value(at x: Double, width: Double) -> Int {
        guard width > 0 else { return 0 }
        return min(5, max(0, Int(ceil(x / (width / 5)))))
    }
}

extension LiteratureNoteFiles {
    func editPage(url: URL, transform: @Sendable (String) throws -> String) throws {
        let before = try Data(contentsOf: url)
        guard let text = String(data: before, encoding: .utf8) else { throw LiteratureFileError.invalidUTF8 }
        let after = Data(try transform(text).utf8)
        let coordinator = NSFileCoordinator(); var coordinationError: NSError?; var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { path in
            result = Result {
                guard try Data(contentsOf: path) == before else { throw LiteratureFileError.noteChanged }
                if after != before {
                    guard FileManager.default.isWritableFile(atPath: path.path) else { throw CocoaError(.fileWriteNoPermission) }
                    try after.write(to: path, options: .atomic)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LiteratureFileError.noteChanged }
        try result.get()
    }
}

import Foundation
import LumenKit

struct LiteratureZoteroIdentity: Codable, Equatable, Sendable {
    /// `library` or `groups/<group ID>`; this is not a filename or title.
    var library: String
    var itemKey: String
    var attachmentKey: String
    var title: String
    var authors: String
    var year: String
    var journal: String? = nil

    var itemLink: String { "zotero://select/\(library)/items/\(itemKey)" }
}

enum LiteratureFileError: Error, LocalizedError, Equatable {
    case duplicatePages
    case invalidFolder
    case noteChanged
    case noteMissing
    case invalidUTF8
    case backupFailed
    case stateFailed

    var errorDescription: String? {
        switch self {
        case .duplicatePages: return "多个文献页包含同一文献标识，请先处理重复页面。"
        case .invalidFolder: return "文献笔记目录不可用。"
        case .noteChanged: return "文献页在同步期间被修改，已保留原文件并等待重试。"
        case .noteMissing: return "关联的文献页不在原位置，请重新关联。"
        case .invalidUTF8: return "文献页不是有效的 UTF-8 文件。"
        case .backupFailed: return "无法备份已有文献页，未开始接管。"
        case .stateFailed: return "无法保存同步记录，已暂停。"
        }
    }
}

/// Only an explicit frontmatter itemLink is accepted; links in a note's body
/// can point to cited works and must never select the destination page.
enum LiteratureNoteIndex {
    static func itemLink(in text: String) -> String? {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard let finish = lines.dropFirst().firstIndex(of: "---") else { return nil }
        let regex = try? NSRegularExpression(pattern: #"^itemLink:\s*(?:\[\s*)?[\"']?(zotero://select/(?:library|groups/[0-9]+)/items/[A-Z0-9]+)[\"']?(?:\s*\])?\s*$"#)
        let properties = lines[1..<finish].filter { $0.hasPrefix("itemLink:") }
        guard properties.count == 1, let property = properties.first else { return nil }
        // JSON-encoded YAML may escape slashes; this is the same Zotero URL.
        let line = property.replacingOccurrences(of: "\\/", with: "/")
        guard let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    static func matchingPage(in folder: URL, itemLink: String) throws -> URL? {
        try matchingPage(in: folder) { Self.itemLink(in: $0) == itemLink }
    }

    static func matchingPage(in folder: URL, documentID: String) throws -> URL? {
        let marker = LiteratureNoteCodec.attachmentMarker(for: documentID)
        return try matchingPage(in: folder) { $0.components(separatedBy: .newlines).contains(where: { $0 == marker || $0 == LiteratureNoteCodec.compactMarker(marker) }) }
    }

    private static func matchingPage(in folder: URL, matchesIdentity: (String) -> Bool) throws -> URL? {
        let manager = FileManager.default
        guard let files = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw LiteratureFileError.invalidFolder
        }
        var matches: [URL] = []
        for case let url as URL in files where url.pathExtension.lowercased() == "md" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8), matchesIdentity(text) else { continue }
            matches.append(url)
        }
        guard matches.count < 2 else { throw LiteratureFileError.duplicatePages }
        return matches.first
    }

    static func newPage(for identity: LiteratureZoteroIdentity) -> String {
        func quoted(_ string: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            guard let data = try? encoder.encode(string), let value = String(data: data, encoding: .utf8) else { return "\"\"" }
            return value
        }
        let cleanTitle = identity.title.replacingOccurrences(of: "\n", with: " ")
        return "---\n标题: \(quoted(cleanTitle))\n作者: \(quoted(identity.authors))\n日期: \(quoted(identity.year))\nitemLink: \(quoted(identity.itemLink))\n---\n\n# \(cleanTitle)\n"
    }

    static func newPageURL(in folder: URL, identity: LiteratureZoteroIdentity, filename: String? = nil) -> URL {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = (filename ?? identity.title).components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var title = String((cleaned.isEmpty ? "未命名文献" : cleaned).prefix(120))
        // macOS limits UTF-16 units, not Swift grapheme clusters. Leave room for
        // the collision suffix even when a valid source filename contains emoji.
        while title.utf16.count > 200 { title.removeLast() }
        if title.isEmpty { title = "未命名文献" }
        let plain = folder.appendingPathComponent("\(title).md")
        if filename != nil && !FileManager.default.fileExists(atPath: plain.path) { return plain }
        return folder.appendingPathComponent("\(title) \(identity.itemKey).md")
    }
}

/// Serializes the note and state writes in this process. File coordination and
/// a byte-for-byte recheck protect changes from other cooperating writers.
actor LiteratureNoteFiles {
    struct Prepared: Sendable {
        var url: URL
        var before: Data?
        var merge: LiteratureNoteCodec.Merge
        var metadataRendered: String?
    }

    private let backupDirectory: URL
    init(backupDirectory: URL) { self.backupDirectory = backupDirectory }

    func prepare(url: URL, initial: String, snapshot: LiteratureAttachmentSnapshot,
                 baseline: LiteratureNoteBaseline?, metadata: LiteratureZoteroIdentity? = nil,
                 metadataBaseline: String? = nil, initializeProperties: Bool = false, filename: String? = nil,
                 migratePageStyle: Bool = false, previousMetadata: LiteratureZoteroIdentity? = nil, attachIdentity: Bool = false) throws -> Prepared {
        let before: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            before = try Data(contentsOf: url)
        } else {
            guard baseline == nil else { throw LiteratureFileError.noteMissing }
            before = nil
        }
        guard var text = before.map({ String(data: $0, encoding: .utf8) }) ?? (before == nil ? initial : nil) else {
            throw LiteratureFileError.invalidUTF8
        }
        if initializeProperties {
            let values = ["作者": metadata?.authors ?? "", "日期": metadata?.year ?? "", "期刊": metadata?.journal ?? "", "评价": LiteratureRating.text(0), "总结": ""]
            for (key, value) in values where try !LiteraturePageEditor.properties(text).contains(where: { $0.key == key }) {
                text = try LiteraturePageEditor.set(text, key: key, value: value, expected: nil)
            }
        }
        if migratePageStyle || initializeProperties {
            let title = try LiteraturePageEditor.properties(text).first { $0.key == "标题" }
            // Repair the previous filename-as-title migration, preserving a
            // title explicitly edited by the user.
            if title == nil || title?.value == filename {
                // A local file without bibliographic metadata has no known
                // literature title. Leave the field empty for the user to fill.
                text = try LiteraturePageEditor.set(text, key: "标题", value: metadata?.title ?? "", expected: title)
            }
            if let rating = try LiteraturePageEditor.properties(text).first(where: { $0.key == "评价" }),
               rating.editable, rating.value.isEmpty {
                text = try LiteraturePageEditor.set(text, key: "评价", value: LiteratureRating.text(0), expected: rating)
            }
        }
        if let metadata {
            text = try LiteraturePageEditor.refreshMetadata(text, identity: metadata, previous: previousMetadata, addMissing: initializeProperties)
        }
        if attachIdentity, let metadata { text = try LiteraturePageEditor.attachZotero(text, identity: metadata) }
        let metadataResult = try metadata.map { try LiteratureMetadataCodec.merge(document: text, identity: $0, baseline: metadataBaseline) }
        var merge = try LiteratureNoteCodec.export(document: metadataResult?.document ?? text, snapshot: snapshot, baseline: baseline)
        if migratePageStyle { merge.document = try LiteraturePageEditor.arrangePage(merge.document) }
        return Prepared(url: url, before: before,
                        merge: merge,
                        metadataRendered: metadataResult?.rendered)
    }

    /// Returns the backup location on first takeover. No changes are made on a mismatch.
    func commit(_ prepared: Prepared, firstTakeover: Bool) throws -> URL? {
        let newData = Data(prepared.merge.document.utf8)
        if let before = prepared.before, before != newData,
           !FileManager.default.isWritableFile(atPath: prepared.url.path) { throw CocoaError(.fileWriteNoPermission) }
        var backup: URL?
        if firstTakeover || prepared.merge.replacedLocalExport, let original = prepared.before, original != newData {
            do {
                try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let destination = backupDirectory.appendingPathComponent(UUID().uuidString + ".md")
                try original.write(to: destination, options: .withoutOverwriting)
                guard try Data(contentsOf: destination) == original else { throw LiteratureFileError.backupFailed }
                backup = destination
            } catch { throw LiteratureFileError.backupFailed }
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: prepared.url, options: .forReplacing, error: &coordinationError) { url in
            result = Result {
                let exists = FileManager.default.fileExists(atPath: url.path)
                let current = exists ? try Data(contentsOf: url) : nil
                guard current == prepared.before else { throw LiteratureFileError.noteChanged }
                if current == newData { return }
                if current != nil, !FileManager.default.isWritableFile(atPath: url.path) { throw CocoaError(.fileWriteNoPermission) }
                if current == nil {
                    // Write a hidden sibling completely, then create the visible
                    // name exclusively. Another app can neither see a partial
                    // note nor have its newly created file replaced.
                    let temporary = url.deletingLastPathComponent().appendingPathComponent(".lumen-\(UUID().uuidString).tmp")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try newData.write(to: temporary, options: .withoutOverwriting)
                    try FileManager.default.linkItem(at: temporary, to: url)
                } else {
                    try newData.write(to: url, options: .atomic)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LiteratureFileError.noteChanged }
        try result.get()
        return backup
    }
}

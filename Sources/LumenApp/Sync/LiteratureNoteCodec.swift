import Foundation
import LumenKit

/// A plain value snapshot. PDFKit objects never cross into the note writer.
struct LiteratureAnnotation: Codable, Equatable, Sendable {
    var id: String
    var locator: String
    var quote: String
    var note: String
    var color: String?
    var hasHighlight: Bool

    init(_ item: AnnotationItem) {
        id = item.id
        locator = item.locator.storageKey
        quote = item.quote
        note = item.note
        color = item.highlightHex
        hasHighlight = item.hasHighlight
    }
}

struct LiteratureAttachmentSnapshot: Codable, Equatable, Sendable {
    var documentID: String
    var title: String
    var annotations: [LiteratureAnnotation]
}

struct LiteratureNoteBaseline: Codable, Equatable, Sendable {
    var snapshot: LiteratureAttachmentSnapshot
    /// The previous generated section is used to detect changes outside comment bodies.
    var rendered: String
}

enum LiteratureNoteError: Error, LocalizedError, Equatable {
    case malformed
    case duplicateAnnotation(String)
    case invalidText
    case changedStructure
    case untrackedSection

    var errorDescription: String? {
        switch self {
        case .malformed: return "文献页的 Lumen 标记不完整，已暂停同步。"
        case .duplicateAnnotation: return "文献页中存在重复的批注标识，已暂停同步。"
        case .invalidText: return "批注正文包含同步保留标记，不能安全同步。"
        case .changedStructure: return "批注区域的摘录或标记被修改，已暂停同步。"
        case .untrackedSection: return "文献页已有未登记的 Lumen 区域，已暂停同步。"
        }
    }
}

/// Each attachment owns one delimited section. Nothing outside it is rewritten.
enum LiteratureNoteCodec {
    private static let reserved = "<!-- lumen-"
    struct Merge: Sendable {
        var document: String
        var baseline: LiteratureNoteBaseline
        var replacedLocalExport = false
    }

    private static func token(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func start(_ id: String) -> String { "<!-- lumen-attachment:\(token(id)):begin -->" }
    private static func end(_ id: String) -> String { "<!-- lumen-attachment:\(token(id)):end -->" }

    static func attachmentMarker(for documentID: String) -> String { start(documentID) }
    static func compactMarker(_ marker: String) -> String {
        marker.replacingOccurrences(of: "<!-- ", with: "%% ").replacingOccurrences(of: " -->", with: " %%")
    }

    /// Production export: original annotations belong to Lumen. Only this
    /// bounded section is refreshed; properties and reading notes stay outside.
    static func export(document: String, snapshot: LiteratureAttachmentSnapshot,
                       baseline: LiteratureNoteBaseline?) throws -> Merge {
        guard Set(snapshot.annotations.map(\.id)).count == snapshot.annotations.count else { throw LiteratureNoteError.duplicateAnnotation("") }
        let legacyBegin = start(snapshot.documentID), legacyFinish = end(snapshot.documentID)
        let begin = compactMarker(legacyBegin), finish = compactMarker(legacyFinish)
        var rows = [begin, "## 批注", ""]
        for item in snapshot.annotations {
            guard !item.note.contains(reserved), !item.quote.contains(reserved), !item.note.contains("%% lumen-"), !item.quote.contains("%% lumen-") else { throw LiteratureNoteError.invalidText }
            var url = URLComponents()
            url.scheme = "lumen"; url.host = "open"
            url.queryItems = [URLQueryItem(name: "document", value: snapshot.documentID),
                              URLQueryItem(name: "annotation", value: item.id),
                              URLQueryItem(name: "locator", value: item.locator)]
            let label = DocumentLocator.parse(storageKey: item.locator)?.displayLabel() ?? "原文位置"
            var dot = ""
            if let color = item.color, color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil {
                dot = "<span style=\"color: \(color)\">●</span> "
            }
            rows.append("> [!quote] \(dot)[\(label)](\(url.url?.absoluteString ?? ""))")
            if !item.quote.isEmpty { rows += item.quote.components(separatedBy: "\n").map { "> " + $0 } }
            if !item.note.isEmpty {
                if !item.quote.isEmpty { rows.append(">") }
                rows += item.note.components(separatedBy: "\n").map { "> " + $0 }
            }
            rows.append("")
        }
        rows.append(finish)
        let rendered = rows.joined(separator: "\n")
        var output = document.replacingOccurrences(of: legacyBegin, with: begin).replacingOccurrences(of: legacyFinish, with: finish)
        let starts = output.components(separatedBy: begin).count - 1
        let ends = output.components(separatedBy: finish).count - 1
        guard starts == ends, starts <= 1 else { throw LiteratureNoteError.malformed }
        var replacedLocalExport = false
        if let a = output.range(of: begin), let b = output.range(of: finish, range: a.upperBound..<output.endIndex) {
            let existing = String(output[a.lowerBound..<b.upperBound])
            if let baseline {
                let expected = baseline.rendered.replacingOccurrences(of: legacyBegin, with: begin).replacingOccurrences(of: legacyFinish, with: finish)
                replacedLocalExport = existing != expected
            }
            output.replaceSubrange(a.lowerBound..<b.upperBound, with: rendered)
        } else {
            replacedLocalExport = baseline != nil
            // A whole deleted export is recreated; no original annotation is deleted.
            output += (output.hasSuffix("\n\n") ? "" : "\n\n") + rendered + "\n"
        }
        return Merge(document: output, baseline: .init(snapshot: snapshot, rendered: rendered), replacedLocalExport: replacedLocalExport)
    }

}

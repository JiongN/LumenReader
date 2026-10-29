import Foundation

/// Separate metadata ownership keeps existing YAML and personal text intact.
enum LiteratureMetadataCodec {
    struct Result {
        var document: String
        var rendered: String
    }

    static func key(_ identity: LiteratureZoteroIdentity) -> String {
        identity.library + ":" + identity.itemKey
    }

    static func render(_ identity: LiteratureZoteroIdentity) -> String {
        let token = Data(key(identity).utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        // Bibliographic fields already live in frontmatter; retain only the
        // ownership boundary so old generated blocks can be safely migrated.
        return ["<!-- lumen-zotero:\(token):begin -->", "<!-- lumen-zotero:\(token):end -->"].joined(separator: "\n")
    }

    static func merge(document: String, identity: LiteratureZoteroIdentity, baseline: String?) throws -> Result {
        let rendered = render(identity)
        let firstLine = rendered.components(separatedBy: "\n")[0]
        let lastLine = rendered.components(separatedBy: "\n").last!
        let starts = document.components(separatedBy: firstLine).count - 1
        let ends = document.components(separatedBy: lastLine).count - 1
        guard starts == ends, starts <= 1 else { throw LiteratureNoteError.malformed }
        guard starts == 1 else { return Result(document: document, rendered: "") }
        guard let baseline else { throw LiteratureNoteError.untrackedSection }
        guard let first = document.range(of: firstLine),
              let last = document.range(of: lastLine, range: first.upperBound..<document.endIndex) else {
            throw LiteratureNoteError.malformed
        }
        let range = first.lowerBound..<last.upperBound
        guard document[range] == baseline else { throw LiteratureNoteError.changedStructure }
        var output = document
        output.replaceSubrange(range, with: "")
        return Result(document: output, rendered: "")
    }
}

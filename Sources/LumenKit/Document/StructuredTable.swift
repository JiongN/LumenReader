import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct DocumentTableCell: Codable, Sendable, Equatable {
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public var header: Bool
    public var text: String
}

public enum StructuredTable {
    public static func cells(html: String) -> [DocumentTableCell]? {
        guard html.utf8.count <= 512_000, !html.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !html.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let delegate = TableDelegate()
        let parser = XMLParser(data: Data(html.utf8))
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.cells.isEmpty else { return nil }
        return delegate.cells
    }
}

private final class TableDelegate: NSObject, XMLParserDelegate {
    var cells: [DocumentTableCell] = []
    private var row = -1, column = 0
    private var current: DocumentTableCell?
    private var occupied: [Int: Int] = [:]
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch element.lowercased() {
        case "tr": row += 1; column = 0
        case "td", "th":
            while occupied[column, default: -1] >= row { column += 1 }
            let rowSpan = min(1000, max(1, Int(attributes["rowspan"] ?? "1") ?? 1))
            let colSpan = min(1000, max(1, Int(attributes["colspan"] ?? "1") ?? 1))
            current = .init(row: max(0, row), column: column, rowSpan: rowSpan, columnSpan: colSpan, header: element.lowercased() == "th", text: "")
            for col in column..<(column + colSpan) { occupied[col] = row + rowSpan - 1 }
        case "br": current?.text += "\n"
        default: break
        }
        if cells.count > 20_000 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { current?.text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if ["td", "th"].contains(element.lowercased()), var cell = current {
            cell.text = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            cells.append(cell); column += cell.columnSpan; current = nil
        }
    }
}

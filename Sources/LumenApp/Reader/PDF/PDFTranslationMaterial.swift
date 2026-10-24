import Foundation
import PDFKit
import LumenKit

/// Translation and chat share durable enhanced pages; the live reader never
/// owns the parser document or waits for page images on the main thread.
actor PDFTranslationMaterial {
    static let shared = PDFTranslationMaterial()
    private let service: EnhancedDocumentService
    init(service: EnhancedDocumentService = .shared) { self.service = service }

    struct Result: Sendable {
        var paragraphs: [PDFParagraph]
        var note: String?
    }

    func prepare(_ snapshot: PDFContextSnapshot, options: DocumentAIOptions,
                 pageRange: ClosedRange<Int>?) async throws -> Result {
        let native = Result(paragraphs: snapshot.paragraphs, note: snapshot.context.extractionNote)
        guard options.parsingEnabled else { return native }
        let pages = Set((0..<snapshot.context.unitCount).filter { pageRange?.contains($0) != false })
        // Partial replacement must never drop the neighbouring page of a joined paragraph.
        let boundaryPages = Set(snapshot.paragraphs.filter(\.spansPages).flatMap(\.pageIndices))
        let complex = Self.complexPages(snapshot.paragraphs).subtracting(boundaryPages)
        let enriched = try await service.enrich(snapshot.context, options: options, allowedPages: pages.subtracting(boundaryPages),
            layoutPages: complex, progress: { _ in })
        let enhanced = enriched.blocks.filter { $0.parser == options.parsingModel && pages.contains($0.pageIndex) }
        guard !enhanced.isEmpty else { return .init(paragraphs: native.paragraphs, note: enriched.extractionNote) }
        try Task.checkCancellation()
        guard let pdf = CGPDFDocument(URL(fileURLWithPath: snapshot.context.path) as CFURL) else { throw AIError.invalidResponse }
        var replacements: [Int: [PDFParagraph]] = [:]
        var rejected: [Int] = []
        for (index, blocks) in Dictionary(grouping: enhanced, by: \.pageIndex) {
            guard !boundaryPages.contains(index), let page = pdf.page(at: index + 1) else { continue }
            let box = page.getBoxRect(.cropBox)
            let rotated = abs(page.rotationAngle) % 180 == 90
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
            let mapped = Self.paragraphs(blocks: blocks, displaySize: size, inverseTransform: transform.inverted())
            let source = snapshot.paragraphs.filter { $0.pageIndex == index }
            if !mapped.isEmpty, Self.preservesBody(source, replacement: mapped) { replacements[index] = mapped }
            else { rejected.append(index + 1) }
        }
        let allPages = Set(snapshot.paragraphs.map(\.pageIndex)).union(replacements.keys).sorted()
        let original = Dictionary(grouping: snapshot.paragraphs, by: \.pageIndex)
        var note = enriched.extractionNote
        if !rejected.isEmpty {
            note = (note.map { $0 + " · " } ?? "") + "增强结果缺少完整文字或定位，保留本机排版：" + rejected.sorted().map(String.init).joined(separator: ",")
        }
        return .init(paragraphs: allPages.flatMap { replacements[$0] ?? original[$0] ?? [] }, note: note)
    }

    nonisolated static func complexPages(_ paragraphs: [PDFParagraph]) -> Set<Int> {
        Set(Dictionary(grouping: paragraphs, by: \.pageIndex).compactMap { page, blocks in
            if blocks.contains(where: { $0.kind == .table && $0.text.count > 80 }) { return page }
            // Readable symmetric columns remain native. A substantial narrow
            // sidebar beside prose is the risky mixed-layout case.
            for sidebar in blocks where sidebar.lineCount >= 3 && sidebar.bounds.width > 15 {
                if blocks.contains(where: { body in
                    body.lineCount >= 4 && body.bounds.width > sidebar.bounds.width * 2.2
                        && (sidebar.bounds.minX - body.bounds.maxX > 4 || body.bounds.minX - sidebar.bounds.maxX > 4)
                        && min(body.bounds.maxY, sidebar.bounds.maxY) - max(body.bounds.minY, sidebar.bounds.minY) > sidebar.bounds.height * 0.5
                }) { return page }
            }
            return nil
        })
    }

    nonisolated static func preservesBody(_ original: [PDFParagraph], replacement: [PDFParagraph]) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let accepted = words(replacement.map(\.text).joined(separator: " "))
        for paragraph in original where paragraph.text.count >= 160 && !TextLayerTrust.hasInvalidEncoding(paragraph.text) {
            let expected = words(paragraph.text)
            // A readable body must not disappear in a partial or wrong-page response.
            if expected.count >= 20, Double(expected.intersection(accepted).count) / Double(expected.count) < 0.8 { return false }
        }
        return true
    }

    nonisolated static func paragraphs(blocks: [DocumentBlock], displaySize: CGSize,
                                       inverseTransform: CGAffineTransform = .identity) -> [PDFParagraph] {
        let body = blocks.filter { ![.header, .footer, .figure].contains($0.kind) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.order < $1.order }
        // Do not substitute half a page when the provider omitted a text block's box.
        guard !body.isEmpty, body.allSatisfy({ $0.bounds?.isValid == true }) else { return [] }
        let paragraphs = body.compactMap { block -> PDFParagraph? in
            guard let bounds = block.bounds else { return nil }
            let rectangle = CGRect(x: bounds.x * displaySize.width, y: (1 - bounds.y - bounds.height) * displaySize.height,
                width: bounds.width * displaySize.width, height: bounds.height * displaySize.height).applying(inverseTransform)
            let text: String
            if block.kind == .table, let cells = block.tableCells, !cells.isEmpty {
                let columns = min(256, max(1, cells.map { $0.column + $0.columnSpan }.max() ?? 1))
                text = Dictionary(grouping: cells, by: \.row).sorted { $0.key < $1.key }.map { _, row in
                    var values = Array(repeating: "", count: columns)
                    for cell in row where values.indices.contains(cell.column) {
                        values[cell.column] = cell.text.replacingOccurrences(of: "\n", with: " ")
                    }
                    return values.joined(separator: "\t")
                }.joined(separator: "\n")
            } else {
                text = PDFParagraphExtractor.joinLines(block.text.components(separatedBy: .newlines))
            }
            return PDFParagraph(pageIndex: block.pageIndex, text: text, bounds: rectangle,
                lineCount: max(1, block.text.components(separatedBy: .newlines).count), firstLineOrdinal: block.order,
                isShort: text.count < 20, kind: block.kind == .table ? .table : block.kind == .caption ? .caption : nil)
        }
        guard Set(paragraphs.map(\.id)).count == paragraphs.count else { return [] }
        return paragraphs
    }
}

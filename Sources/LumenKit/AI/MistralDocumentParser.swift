import Foundation

/// Retain the full service response alongside normalized blocks. Unknown fields
/// survive locally, rather than being discarded by an evolving provider schema.
public enum DocumentJSON: Codable, Sendable, Equatable {
    case object([String: DocumentJSON]), array([DocumentJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: DocumentJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([DocumentJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> Self { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var array: [Self] { if case .array(let v) = self { return v }; return [] }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
}

public struct MistralDocumentParser: Sendable {
    public struct Page: Codable, Sendable {
        public var pageIndex: Int
        public var blocks: [DocumentBlock]
        public var markdown: String
        public var raw: DocumentJSON
    }
    public var client: DocumentAIClient
    public var model: String
    public init(client: DocumentAIClient, model: String) { self.client = client; self.model = model }

    public func parse(image: AIImage, pageIndex: Int) async throws -> Page {
        struct Body: Encodable, Sendable {
            struct Document: Encodable, Sendable { var type = "image_url"; var image_url: String }
            var model: String
            var document: Document
            var include_blocks = true
            var include_image_base64 = false
            var extract_header = true
            var extract_footer = true
            var table_format = "html"
            var confidence_scores_granularity = "block"
        }
        let body = Body(model: model, document: .init(image_url: "data:\(image.mimeType);base64," + image.data.base64EncodedString()))
        let raw = try await client.post("/ocr", body: body, response: DocumentJSON.self)
        return try Self.normalized(raw, pageIndex: pageIndex, parser: model)
    }

    public static func normalized(_ raw: DocumentJSON, pageIndex: Int, parser: String) throws -> Page {
        let pages = raw["pages"].array
        guard pages.count == 1, pages[0]["index"].number == 0,
              let markdown = pages[0]["markdown"].string else { throw AIError.preparation("解析服务未返回预期单页，未缓存错误页码。") }
        let page = pages[0]
        let width = page["dimensions"]["width"].number ?? 0, height = page["dimensions"]["height"].number ?? 0
        var blocks: [DocumentBlock] = []
        for (index, block) in page["blocks"].array.enumerated() {
            let label = block["type"].string ?? block["label"].string ?? "unknown"
            let aliases: [String: DocumentBlock.Kind] = ["text": .paragraph, "title": .heading, "image": .figure, "list": .paragraph, "code": .paragraph]
            let kind = DocumentBlock.Kind(rawValue: label) ?? aliases[label] ?? .unknown
            let bbox = block["bbox"]
            let values = bbox.array.compactMap(\.number)
            let x = block["top_left_x"].number ?? bbox["x_min"].number ?? bbox["top_left_x"].number ?? values.first
            let y = block["top_left_y"].number ?? bbox["y_min"].number ?? bbox["top_left_y"].number ?? (values.count > 1 ? values[1] : nil)
            let right = block["bottom_right_x"].number ?? bbox["x_max"].number ?? bbox["bottom_right_x"].number ?? (values.count > 2 ? values[2] : nil)
            let bottom = block["bottom_right_y"].number ?? bbox["y_max"].number ?? bbox["bottom_right_y"].number ?? (values.count > 3 ? values[3] : nil)
            var bounds: DocumentBlock.Bounds?
            if let x, let y, let right, let bottom, width > 0, height > 0 {
                bounds = .init(x: x / width, y: y / height, width: (right - x) / width, height: (bottom - y) / height)
            }
            let table = page["tables"].array.first { $0["id"].string == block["table_id"].string && block["table_id"].string != nil }
            let content = table?["content"].string ?? block["content"].string ?? block["text"].string ?? ""
            blocks.append(.init(id: "enhanced-p\(pageIndex)-b\(index)", kind: kind, pageIndex: pageIndex,
                order: index, text: content, bounds: bounds, parser: parser,
                confidence: block["confidence_scores"]["average_content_confidence_score"].number,
                tableCells: kind == .table ? StructuredTable.cells(html: content) : nil))
        }
        // Some deployed OCR versions omit blocks. Preserve text without inventing
        // paragraph boxes or advertising verified chart locations.
        if blocks.isEmpty {
            blocks.append(.init(id: "enhanced-p\(pageIndex)", kind: .unknown, pageIndex: pageIndex,
                order: 0, text: markdown, parser: parser))
        }
        for (index, table) in page["tables"].array.enumerated() {
            if let content = table["content"].string {
                guard !blocks.contains(where: { $0.kind == .table && $0.text == content }) else { continue }
                blocks.append(.init(id: "enhanced-p\(pageIndex)-table\(index)", kind: .table, pageIndex: pageIndex,
                    order: blocks.count, text: content, parser: parser, tableCells: StructuredTable.cells(html: content)))
            }
        }
        for key in ["header", "footer"] {
            if let text = page[key].string, !text.isEmpty {
                blocks.append(.init(id: "enhanced-p\(pageIndex)-\(key)", kind: key == "header" ? .header : .footer,
                    pageIndex: pageIndex, order: blocks.count, text: text, parser: parser))
            }
        }
        return .init(pageIndex: pageIndex, blocks: blocks, markdown: markdown, raw: raw)
    }
}

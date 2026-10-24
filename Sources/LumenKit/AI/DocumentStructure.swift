import Foundation

public struct DocumentBlock: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case paragraph, heading, table, figure, caption, header, footer, equation, unknown }
    public struct Bounds: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.001 && y + height <= 1.001 }
    }
    public var id: String
    public var kind: Kind
    public var pageIndex: Int
    public var printedPage: String?
    public var order: Int
    public var text: String
    public var bounds: Bounds?
    public var cells: [[String]]?
    public var tableCells: [DocumentTableCell]?
    public var relatedIDs: [String]
    public var parser: String
    public var confidence: Double?
    public init(id: String, kind: Kind, pageIndex: Int, order: Int, text: String,
                bounds: Bounds? = nil, cells: [[String]]? = nil, relatedIDs: [String] = [], parser: String,
                confidence: Double? = nil, printedPage: String? = nil, tableCells: [DocumentTableCell]? = nil) {
        self.id = id; self.kind = kind; self.pageIndex = pageIndex; self.order = order; self.text = text
        self.bounds = bounds?.isValid == true ? bounds : nil; self.cells = cells; self.relatedIDs = relatedIDs
        self.parser = parser; self.confidence = confidence; self.printedPage = printedPage
        self.tableCells = tableCells
    }
}

public struct DocumentAIOptions: Codable, Sendable, Equatable {
    public var visionProviderID: UUID?
    public var visionModel = ""
    public var embeddingProviderID: UUID?
    public var embeddingModel = ""
    public var parsingEnabled = false
    public var parsingBaseURL = "https://api.mistral.ai/v1"
    /// Fixed version; never silently follows a changing latest alias.
    public var parsingModel = "mistral-ocr-4-1"
    public var officialTranslationBaseURL = "https://api.cognitive.microsofttranslator.com"
    public var officialTranslationRegion = ""
    public init() {}
}

public extension DocumentAIOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visionProviderID = try c.decodeIfPresent(UUID.self, forKey: .visionProviderID)
        visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel) ?? visionModel
        embeddingProviderID = try c.decodeIfPresent(UUID.self, forKey: .embeddingProviderID)
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel) ?? embeddingModel
        parsingEnabled = try c.decodeIfPresent(Bool.self, forKey: .parsingEnabled) ?? parsingEnabled
        parsingBaseURL = try c.decodeIfPresent(String.self, forKey: .parsingBaseURL) ?? parsingBaseURL
        parsingModel = try c.decodeIfPresent(String.self, forKey: .parsingModel) ?? parsingModel
        if parsingModel == "mistral-ocr-4-0", URL(string: parsingBaseURL)?.host?.lowercased() == "api.mistral.ai" {
            parsingModel = "mistral-ocr-4-1"
        }
        officialTranslationBaseURL = try c.decodeIfPresent(String.self, forKey: .officialTranslationBaseURL) ?? officialTranslationBaseURL
        officialTranslationRegion = try c.decodeIfPresent(String.self, forKey: .officialTranslationRegion) ?? officialTranslationRegion
    }
}

public struct MaterialCoverage: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case original, hierarchical, partial }
    public var mode: Mode
    public var processedUnits: Int
    public var totalUnits: Int
    public var readbackBlocks: Int
    public var label: String {
        let title = mode == .original ? "完整原文" : mode == .hierarchical ? "全书摘要＋相关原文" : "部分材料"
        return "\(title) · \(processedUnits)/\(totalUnits) 页/章 · 补读 \(readbackBlocks) 段"
    }
    public init(mode: Mode, processedUnits: Int, totalUnits: Int, readbackBlocks: Int) {
        self.mode = mode; self.processedUnits = processedUnits; self.totalUnits = totalUnits; self.readbackBlocks = readbackBlocks
    }
}

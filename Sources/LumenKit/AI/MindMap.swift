import Foundation

public struct MindMapNode: Codable, Sendable, Equatable {
    public var label: String
    public var source: String?
    public var children: [MindMapNode]
    public var coveredSections: [String]

    public init(label: String, source: String? = nil, children: [MindMapNode] = [], coveredSections: [String] = []) {
        self.label = label; self.source = source; self.children = children
        self.coveredSections = coveredSections
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decode(String.self, forKey: .label)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        children = try values.decodeIfPresent([MindMapNode].self, forKey: .children) ?? []
        coveredSections = try values.decodeIfPresent([String].self, forKey: .coveredSections) ?? []
    }
}

public struct MindMapResult: Sendable, Equatable {
    public var root: MindMapNode
    public var surroundingText: String

    public static func parse(_ text: String) -> MindMapResult? {
        guard text.utf8.count <= 100_000 else { return nil }
        let payload: Substring
        let replaced: Range<String.Index>
        if let start = text.range(of: "```mindmap", options: .caseInsensitive)
            ?? text.range(of: "```json", options: .caseInsensitive),
           let lineEnd = text[start.upperBound...].firstIndex(of: "\n"),
           let end = text[lineEnd...].range(of: "```") {
            payload = text[lineEnd..<end.lowerBound]
            replaced = start.lowerBound..<end.upperBound
        } else if let range = leadingJSONObject(in: text) {
            payload = text[range]
            replaced = range
        } else { return nil }
        // Bound nesting before recursive Codable decoding (including rejected trees).
        guard safeNesting(payload), let data = String(payload).data(using: .utf8),
              let root = try? JSONDecoder().decode(MindMapNode.self, from: data)
        else { return nil }
        var count = 0
        func valid(_ node: MindMapNode, depth: Int) -> Bool {
            count += 1
            guard depth <= 8, count <= 120, !node.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  node.label.count <= 180, (node.source?.count ?? 0) <= 120,
                  node.coveredSections.count <= 256, node.coveredSections.allSatisfy({ $0.count <= 40 }) else { return false }
            return node.children.allSatisfy { valid($0, depth: depth + 1) }
        }
        guard valid(root, depth: 0) else { return nil }
        let surrounding = String(text[..<replaced.lowerBound]) + String(text[replaced.upperBound...])
        return .init(root: root, surroundingText: surrounding.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func safeNesting(_ text: Substring) -> Bool {
        var nesting = 0, quoted = false, escaped = false
        for character in text {
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" || character == "[" {
                nesting += 1
                if nesting > 20 { return false }
            } else if character == "}" || character == "]" { nesting -= 1 }
        }
        return nesting == 0 && !quoted
    }

    /// Some compatible providers omit fences. Find the object boundary, then
    /// let JSONDecoder validate it; braces inside quoted labels are not delimiters.
    private static func leadingJSONObject(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }), text[start] == "{" else { return nil }
        var depth = 0, quoted = false, escaped = false
        for index in text[start...].indices {
            let character = text[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return start..<text.index(after: index) }
            }
        }
        return nil
    }

    public static let instruction = """
    输出可视化思维导图：使用一个 mindmap 代码块，块内仅有合法 JSON，不输出 Mermaid、ASCII 树或图片链接。
    格式：{"label":"主题","children":[{"label":"分支","source":"第 2 页","children":[{"label":"要点"}]}]}。
    每个节点 label 不超过 28 字，children 可省略；通常 3 层，最多 60 个节点。source 只能使用提供的材料页/章来源，缺乏证据时省略。
    区分作者结论、证据、限定条件与读者推论，关系不明确时不虚构因果。JSON 之外可附一段简短说明。
    """
}

public extension AgentConfig {
    static let mindMapMode = AgentConfig(id: "builtin-mind-map", name: "思维导图",
        persona: "将读者的问题和提供的文献材料组织为思维导图。每次回答都采用以下格式。\n" + MindMapResult.instruction,
        isBuiltIn: true)
}

public struct MindMapLayout: Sendable {
    public struct Item: Sendable, Identifiable {
        public var id: String
        public var node: MindMapNode
        public var center: CGPoint
        public var depth: Int
    }
    public var items: [Item] = []
    public var edges: [(from: CGPoint, to: CGPoint)] = []
    public var size: CGSize = .zero
    public static let nodeSize = CGSize(width: 168, height: 72)

    public init(root: MindMapNode) {
        var leaf = 0, maxDepth = 0
        func place(_ node: MindMapNode, id: String, depth: Int) -> CGPoint {
            maxDepth = max(maxDepth, depth)
            let children = node.children.enumerated().map { place($0.element, id: id + ".\($0.offset)", depth: depth + 1) }
            let y: CGFloat
            if let first = children.first, let last = children.last { y = (first.y + last.y) / 2 }
            else { y = 52 + CGFloat(leaf) * 92; leaf += 1 }
            let center = CGPoint(x: 100 + CGFloat(depth) * 216, y: y)
            items.append(.init(id: id, node: node, center: center, depth: depth))
            for child in children { edges.append((center, child)) }
            return center
        }
        _ = place(root, id: "root", depth: 0)
        size = CGSize(width: 200 + CGFloat(maxDepth) * 216, height: max(104, CGFloat(leaf) * 92 + 12))
    }
}

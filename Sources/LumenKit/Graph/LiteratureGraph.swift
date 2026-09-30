import Foundation

public struct GraphIdentity: Codable, Sendable, Equatable {
    public var title: String
    public var authors: [String]
    public var year: Int?
    public var doi: String?
    public var source: String

    public init(title: String = "", authors: [String] = [], year: Int? = nil, doi: String? = nil, source: String = "本地") {
        self.title = title
        self.authors = authors
        self.year = year
        self.doi = Self.normalizedDOI(doi)
        self.source = source
    }

    public static func normalizedDOI(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "https://doi.org/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "http://dx.doi.org/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "doi:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .;,)]}"))
        return value.lowercased().hasPrefix("10.") && value.contains("/") ? value.lowercased() : nil
    }
}

public struct GraphPaper: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var doi: String?
    public var title: String
    public var authors: [String]
    public var year: Int?
    public var venue: String
    public var abstract: String
    public var openAccessURL: URL?
    public var referencedIDs: [String]
    public var relatedIDs: [String]
    public var citedByCount: Int

    public init(id: String, doi: String?, title: String, authors: [String], year: Int?, venue: String, abstract: String, openAccessURL: URL?, referencedIDs: [String], relatedIDs: [String], citedByCount: Int) {
        self.id = id
        self.doi = GraphIdentity.normalizedDOI(doi)
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.abstract = abstract
        self.openAccessURL = openAccessURL
        self.referencedIDs = referencedIDs
        self.relatedIDs = relatedIDs
        self.citedByCount = citedByCount
    }
}

public enum GraphRelation: String, Codable, Sendable, CaseIterable {
    case reference, citation, related
    public var title: String {
        switch self {
        case .reference: "参考文献"
        case .citation: "被引文献"
        case .related: "相关文献"
        }
    }
}

public struct GraphEdge: Codable, Sendable, Hashable {
    public var source: String
    public var target: String
    public var relation: GraphRelation
    public var provider: String
    public init(source: String, target: String, relation: GraphRelation, provider: String = "OpenAlex") {
        self.source = source; self.target = target; self.relation = relation; self.provider = provider
    }
}

public struct LiteratureGraphSnapshot: Codable, Sendable {
    public var identity = GraphIdentity()
    public var paperID: String?
    public var papers: [GraphPaper] = []
    public var edges: [GraphEdge] = []
    public var positions: [String: GraphPosition] = [:]
    public var pinnedPositionIDs: Set<String> = []
    public var layoutVersion: Int = 0
    public var fetchedAt: Date?
    public var documentSize: Int64 = 0
    public var documentModified: Date?
    public init() {}
}

extension LiteratureGraphSnapshot {
    private enum CodingKeys: String, CodingKey {
        case identity, paperID, papers, edges, positions, pinnedPositionIDs, layoutVersion, fetchedAt, documentSize, documentModified
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decodeIfPresent(GraphIdentity.self, forKey: .identity) ?? GraphIdentity()
        paperID = try values.decodeIfPresent(String.self, forKey: .paperID)
        papers = try values.decodeIfPresent([GraphPaper].self, forKey: .papers) ?? []
        edges = try values.decodeIfPresent([GraphEdge].self, forKey: .edges) ?? []
        positions = try values.decodeIfPresent([String: GraphPosition].self, forKey: .positions) ?? [:]
        pinnedPositionIDs = try values.decodeIfPresent(Set<String>.self, forKey: .pinnedPositionIDs) ?? []
        layoutVersion = try values.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? 0
        fetchedAt = try values.decodeIfPresent(Date.self, forKey: .fetchedAt)
        documentSize = try values.decodeIfPresent(Int64.self, forKey: .documentSize) ?? 0
        documentModified = try values.decodeIfPresent(Date.self, forKey: .documentModified)
    }
}

public struct GraphPosition: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum GraphMerge {
    public static let limit = 150
    /// 用户确认本地引文身份后保留 PDF 原有引用边，并按 DOI / OpenAlex ID 合并。
    public static func resolveLocalReference(_ localID: String, with paper: GraphPaper,
                                             in snapshot: inout LiteratureGraphSnapshot) {
        guard localID.hasPrefix("local:reference:"),
              let localIndex = snapshot.papers.firstIndex(where: { $0.id == localID }) else { return }
        let existing = snapshot.papers.first { $0.id == paper.id || (paper.doi != nil && $0.doi == paper.doi && $0.id != localID) }
        let canonicalID = existing?.id ?? paper.id
        snapshot.papers.remove(at: localIndex)
        if existing == nil { snapshot.papers.append(paper) }
        var seen: Set<GraphEdge> = []
        snapshot.edges = snapshot.edges.map { edge in
            GraphEdge(source: edge.source == localID ? canonicalID : edge.source,
                      target: edge.target == localID ? canonicalID : edge.target,
                      relation: edge.relation, provider: edge.provider)
        }.filter { $0.source != $0.target && seen.insert($0).inserted }
        if let position = snapshot.positions.removeValue(forKey: localID), snapshot.positions[canonicalID] == nil {
            snapshot.positions[canonicalID] = position
        }
        if snapshot.pinnedPositionIDs.remove(localID) != nil {
            snapshot.pinnedPositionIDs.insert(canonicalID)
        }
    }
    public static func add(_ newPapers: [GraphPaper], edges newEdges: [GraphEdge], to snapshot: inout LiteratureGraphSnapshot) {
        var ids = Set(snapshot.papers.map(\.id))
        var doiToID: [String: String] = [:]
        for paper in snapshot.papers { if let doi = paper.doi { doiToID[doi] = paper.id } }
        var aliases: [String: String] = [:]
        for paper in newPapers where snapshot.papers.count < limit {
            if ids.contains(paper.id) { continue }
            if let doi = paper.doi, let canonical = doiToID[doi] {
                // 本地引文尚未核对身份；即使 DOI 相同，也不能让它吞掉已识别的远端题录。
                if !canonical.hasPrefix("local:reference:") || paper.id.hasPrefix("local:") {
                    aliases[paper.id] = canonical
                    continue
                }
            }
            snapshot.papers.append(paper)
            ids.insert(paper.id)
            if let doi = paper.doi { doiToID[doi] = paper.id }
        }
        var existing = Set(snapshot.edges)
        for edge in newEdges {
            let canonical = GraphEdge(source: aliases[edge.source] ?? edge.source, target: aliases[edge.target] ?? edge.target, relation: edge.relation, provider: edge.provider)
            if canonical.source != canonical.target, ids.contains(canonical.source), ids.contains(canonical.target), existing.insert(canonical).inserted {
                snapshot.edges.append(canonical)
            }
        }
        // OpenAlex 的 referenced_works 是明确的引用事实。只在两端已加载时补边，
        // 不把主题相关推荐伪装成引用；同一方向已有边时保留原始来源。
        var linkedPairs = Set(snapshot.edges.filter { $0.relation != .related }
            .map { "\($0.source)→\($0.target)" })
        for paper in snapshot.papers where !paper.id.hasPrefix("local:") {
            for target in paper.referencedIDs where ids.contains(target) && target != paper.id {
                let pair = "\(paper.id)→\(target)"
                if linkedPairs.insert(pair).inserted {
                    snapshot.edges.append(GraphEdge(source: paper.id, target: target,
                        relation: .reference, provider: "OpenAlex referenced_works"))
                }
            }
        }
    }
}

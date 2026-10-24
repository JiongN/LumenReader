import Foundation

extension GraphMerge {
    /// Upgrade only generated, unresolved records. Confirmed database identities stay untouched.
    public static func upgradeLocalReferenceMetadata(in snapshot: inout LiteratureGraphSnapshot) {
        for index in snapshot.papers.indices {
            let paper = snapshot.papers[index]
            guard paper.id.hasPrefix("local:reference:"), paper.sourceCitation == nil else { continue }
            let entry = LocalReferenceParser.details(in: paper.title)
            guard entry.title != entry.citation else { continue }
            snapshot.papers[index] = localPaper(entry, id: paper.id)
        }
    }

    @discardableResult
    public static func refreshLocalReferences(_ entries: [LocalReferenceParser.Entry], rootID: String,
                                              in snapshot: inout LiteratureGraphSnapshot) -> Int {
        guard snapshot.papers.contains(where: { $0.id == rootID }) else { return 0 }
        let previous = Set(snapshot.edges.filter {
            $0.source == rootID && $0.relation == .reference && $0.provider == "PDF 参考文献"
        }.map(\.target))
        let candidates = snapshot.papers.filter { previous.contains($0.id) }.map { paper in
            let parsed = LocalReferenceParser.details(in: paper.sourceCitation ?? paper.title)
            let local = paper.id.hasPrefix("local:reference:")
            let authors = paper.authors.isEmpty && local ? parsed.authors : paper.authors
            return (paper: paper, citation: parsed.citation,
                    title: CNKIRelationBatch.normalizedTitle(local ? parsed.title : paper.title),
                    year: paper.year ?? (local ? parsed.year : nil),
                    authors: Set(authors.map(CNKIRelationBatch.normalizedTitle)))
        }
        var papers: [GraphPaper] = []
        var targets = Set<String>()
        var order: [String] = []
        for entry in entries.prefix(limit - 1) {
            let key = CNKIRelationBatch.normalizedTitle(entry.title)
            let authors = Set(entry.authors.map(CNKIRelationBatch.normalizedTitle))
            let existing = candidates.first { candidate in
                if candidate.citation == entry.citation { return true }
                if let doi = entry.doi, candidate.paper.doi == doi { return true }
                return candidate.title == key
                    && (entry.year == nil || candidate.year == nil || entry.year == candidate.year)
                    && (authors.isEmpty || candidate.authors.isEmpty || !authors.isDisjoint(with: candidate.authors))
            }?.paper
            if let existing, !existing.id.hasPrefix("local:reference:") {
                if targets.insert(existing.id).inserted { order.append(existing.id) }
                continue
            }
            let hash = entry.citation.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
            let paper = localPaper(entry, id: existing?.id ?? "local:reference:\(String(hash, radix: 16))")
            if let index = snapshot.papers.firstIndex(where: { $0.id == paper.id }) { snapshot.papers[index] = paper }
            if targets.insert(paper.id).inserted { papers.append(paper); order.append(paper.id) }
        }
        let obsolete = previous.filter { $0.hasPrefix("local:reference:") && !targets.contains($0) }
        snapshot.edges.removeAll { $0.source == rootID && obsolete.contains($0.target) && $0.provider == "PDF 参考文献" }
        let retained = Set(snapshot.edges.flatMap { [$0.source, $0.target] })
        let removed = obsolete.subtracting(retained)
        snapshot.papers.removeAll { removed.contains($0.id) }
        for id in removed {
            snapshot.positions.removeValue(forKey: id)
            snapshot.pinnedPositionIDs.remove(id)
        }
        add(papers, edges: papers.map {
            GraphEdge(source: rootID, target: $0.id, relation: .reference, provider: "PDF 参考文献")
        }, to: &snapshot)
        let loaded = Dictionary(snapshot.papers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = Dictionary(papers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let linked = Set(snapshot.edges.filter {
            $0.source == rootID && $0.relation == .reference && $0.provider == "PDF 参考文献"
        }.map(\.target))
        var seen = Set<String>()
        let ordered = order.compactMap { id -> GraphPaper? in
            let paper = loaded[id] ?? pending[id]?.doi.flatMap { doi in
                snapshot.papers.last { $0.doi == doi && linked.contains($0.id) }
            }
            guard let paper, seen.insert(paper.id).inserted else { return nil }
            return paper
        }
        // Replace only the reference slots; unrelated nodes retain their order and positions.
        var iterator = ordered.makeIterator()
        snapshot.papers = snapshot.papers.map { seen.contains($0.id) ? (iterator.next() ?? $0) : $0 }
        return ordered.count
    }

    private static func localPaper(_ entry: LocalReferenceParser.Entry, id: String) -> GraphPaper {
        GraphPaper(id: id, doi: entry.doi, title: entry.title, authors: entry.authors, year: entry.year,
                   venue: entry.venue, abstract: "", openAccessURL: nil, referencedIDs: [], relatedIDs: [],
                   citedByCount: 0, sourceCitation: entry.original)
    }
}

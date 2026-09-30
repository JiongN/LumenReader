import Foundation

/// Papers reachable from the current paper through one kind of relationship.
/// Direction matters: references point away from a paper; citations point to it.
public enum GraphRelationView {
    public static func papers(in snapshot: LiteratureGraphSnapshot, relation: GraphRelation,
                              yearStart: Int? = nil) -> [GraphPaper] {
        guard let root = snapshot.paperID,
              snapshot.papers.contains(where: { $0.id == root }) else { return [] }
        var reached: Set<String> = [root]
        var frontier = [root]
        while let current = frontier.popLast() {
            for edge in snapshot.edges where edge.relation == relation {
                let next: String?
                switch relation {
                case .reference, .related: next = edge.source == current ? edge.target : nil
                case .citation: next = edge.target == current ? edge.source : nil
                }
                if let next, reached.insert(next).inserted { frontier.append(next) }
            }
        }
        return snapshot.papers.filter { paper in
            guard reached.contains(paper.id) else { return false }
            if paper.id == root { return true }
            return yearStart.map { (paper.year ?? 0) >= $0 } ?? true
        }
    }
}

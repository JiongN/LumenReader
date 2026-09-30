import Foundation

/// Bounded, deterministic layout; coordinates are independent of window size.
public enum GraphLayout {
    public static func positions(papers: [GraphPaper], edges: [GraphEdge], rootID: String?, iterations: Int = 80) -> [String: GraphPosition] {
        let count = min(papers.count, GraphMerge.limit)
        guard count > 0 else { return [:] }
        let ids = Array(papers.prefix(count).map(\.id))
        var indices: [String: Int] = [:]
        for (index, id) in ids.enumerated() where indices[id] == nil { indices[id] = index }
        var x = [Double](repeating: 0, count: count)
        var y = [Double](repeating: 0, count: count)
        var anchorX = [Double](repeating: 0, count: count)
        var anchorY = [Double](repeating: 0, count: count)
        let rootYear = papers.first(where: { $0.id == rootID })?.year
        var groups: [Int: Int] = [:]
        for index in 0..<count where ids[index] != rootID {
            let id = ids[index]
            let isReference = edges.contains { $0.source == rootID && $0.target == id && $0.relation == .reference }
            let isCitation = edges.contains { $0.target == rootID && $0.source == id && $0.relation == .citation }
            let group: Int
            if isReference { group = 0 }
            else if isCitation { group = 1 }
            else if let year = papers[index].year, let rootYear {
                group = year <= rootYear ? 0 : 1
            } else { group = 2 }
            let ordinal = groups[group, default: 0]
            groups[group] = ordinal + 1
            anchorX[index] = group == 0 ? -175 : (group == 1 ? 175 : 0)
            anchorY[index] = group == 2 ? -170 : 0
            let angle = Double(ordinal) * 2.399963229728653
            let radius = sqrt(Double(ordinal)) * 46
            x[index] = anchorX[index] + cos(angle) * radius
            y[index] = anchorY[index] + sin(angle) * radius
        }
        let links = edges.compactMap { edge -> (Int, Int)? in
            guard let a = indices[edge.source], let b = indices[edge.target], a != b else { return nil }
            return (a, b)
        }
        for step in 0..<max(0, min(iterations, 120)) {
            if Task.isCancelled { break }
            var dx = [Double](repeating: 0, count: count)
            var dy = [Double](repeating: 0, count: count)
            for a in 0..<count {
                for b in (a + 1)..<count {
                    let vx = x[a] - x[b], vy = y[a] - y[b]
                    let distanceSquared = max(64, vx * vx + vy * vy)
                    let force = 2600 / distanceSquared
                    dx[a] += vx * force; dy[a] += vy * force
                    dx[b] -= vx * force; dy[b] -= vy * force
                }
            }
            for (a, b) in links {
                let vx = x[b] - x[a], vy = y[b] - y[a]
                let distance = max(1, hypot(vx, vy))
                let force = min(4, (distance - 105) * 0.018)
                dx[a] += vx / distance * force; dy[a] += vy / distance * force
                dx[b] -= vx / distance * force; dy[b] -= vy / distance * force
            }
            let cooling = 1 - Double(step) / Double(max(1, iterations))
            for index in 0..<count where ids[index] != rootID {
                dx[index] += (anchorX[index] - x[index]) * 0.012
                dy[index] += (anchorY[index] - y[index]) * 0.012
                x[index] += max(-6, min(6, dx[index])) * cooling
                y[index] += max(-6, min(6, dy[index])) * cooling
            }
        }
        var positions: [String: GraphPosition] = [:]
        for (index, id) in ids.enumerated() { positions[id] = GraphPosition(x: x[index], y: y[index]) }
        return positions
    }
}

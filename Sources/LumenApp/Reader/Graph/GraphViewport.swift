import Foundation

enum GraphViewport {
    static func zoom(scale: Double, pan: CGSize, factor: Double, anchor: CGPoint, size: CGSize) -> (scale: Double, pan: CGSize) {
        guard scale > 0, scale.isFinite, factor > 0, factor.isFinite else { return (scale, pan) }
        let next = min(3, max(0.005, scale * factor))
        let ratio = next / scale
        let x = anchor.x - size.width / 2
        let y = anchor.y - size.height / 2
        return (next, CGSize(width: x + (pan.width - x) * ratio,
                             height: y + (pan.height - y) * ratio))
    }
}

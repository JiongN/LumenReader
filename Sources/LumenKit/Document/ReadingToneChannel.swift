import Foundation

/// A color matrix expressed as ordinary blend operations: black -> ink, white -> paper.
public struct ReadingToneChannel: Equatable, Sendable {
    public let inverted: Bool
    public let multiply: Double
    public let screen: Double

    public init(ink: Double, paper: Double) {
        let ink = min(1, max(0, ink.isFinite ? ink : 0))
        let paper = min(1, max(0, paper.isFinite ? paper : 1))
        inverted = ink > paper
        screen = min(ink, paper)
        multiply = screen < 1 ? abs(paper - ink) / (1 - screen) : 0
    }

    public func map(_ input: Double) -> Double {
        let source = inverted ? 1 - input : input
        return 1 - (1 - source * multiply) * (1 - screen)
    }
}

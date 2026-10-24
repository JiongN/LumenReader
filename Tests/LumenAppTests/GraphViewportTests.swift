import Foundation
import Testing
@testable import LumenApp

@Suite("图谱捏合缩放")
struct GraphViewportTests {
    @Test func zoomKeepsPointUnderFingersFixed() {
        let size = CGSize(width: 800, height: 600)
        let anchor = CGPoint(x: 230, y: 210)
        let pan = CGSize(width: 30, height: -20)
        let result = GraphViewport.zoom(scale: 0.8, pan: pan, factor: 1.7, anchor: anchor, size: size)
        let worldX = (anchor.x - size.width / 2 - pan.width) / 0.8
        let worldY = (anchor.y - size.height / 2 - pan.height) / 0.8
        let screenX = worldX * result.scale + result.pan.width + size.width / 2
        let screenY = worldY * result.scale + result.pan.height + size.height / 2
        #expect(abs(screenX - anchor.x) < 0.0001)
        #expect(abs(screenY - anchor.y) < 0.0001)
    }

    @Test func scaleLimitsAndInvalidEventsAreSafe() {
        let size = CGSize(width: 800, height: 600)
        let anchor = CGPoint(x: 400, y: 300)
        #expect(GraphViewport.zoom(scale: 1, pan: .zero, factor: 20, anchor: anchor, size: size).scale == 3)
        #expect(GraphViewport.zoom(scale: 1, pan: .zero, factor: 0.0001, anchor: anchor, size: size).scale == 0.005)
        for factor in [Double.nan, .infinity, -1, 0] {
            let result = GraphViewport.zoom(scale: 1, pan: CGSize(width: 2, height: 3), factor: factor, anchor: anchor, size: size)
            #expect(result.scale == 1)
            #expect(result.pan == CGSize(width: 2, height: 3))
        }
    }
}

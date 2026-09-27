import Testing
@testable import LumenApp

@Suite("双侧面板宽度", .serialized)
@MainActor
struct PanelWidthPolicyTests {
    @Test func preferencesFitInWideWindow() {
        let scale = Double(DS.Size.windowScale(for: 1500))
        let result = PanelWidthPolicy.resolve(containerWidth: 1500, showsRail: true,
            sidebarVisible: true, aiPanelPreferred: 420, sidebarPreferred: 360)
        #expect(abs((result.sidebar ?? 0) - 360 * scale) < 1)
        #expect(abs((result.aiPanel ?? 0) - 420 * scale) < 1)
        #expect(result.reader >= 320)
    }

    @Test func narrowWindowProtectsReaderAndPanelMinimums() {
        let result = PanelWidthPolicy.resolve(containerWidth: 920, showsRail: true,
            sidebarVisible: true, aiPanelPreferred: 640, sidebarPreferred: 420)
        #expect((result.sidebar ?? 0) >= 200)
        #expect((result.aiPanel ?? 0) >= 300)
        #expect(result.reader >= 320)
        let total = (result.sidebar ?? 0) + (result.aiPanel ?? 0) + result.reader
            + Double(LeftRail.width) + 2 * PanelWidthPolicy.handleWidth
        #expect(total <= 920.5)
    }

    @Test func hiddenRightPanelAllowsWiderSidebar() {
        let result = PanelWidthPolicy.resolve(containerWidth: 920, showsRail: true,
            sidebarVisible: true, aiPanelPreferred: nil, sidebarPreferred: 420)
        #expect(abs((result.sidebar ?? 0) - 420) < 1)
        #expect(result.reader >= 320)
    }
}

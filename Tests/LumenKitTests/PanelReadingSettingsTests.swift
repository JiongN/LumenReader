import Foundation
import Testing
@testable import LumenKit

@Suite("面板阅读设置")
struct PanelReadingSettingsTests {
    @Test func legacyAndBadValuesKeepOtherSettings() throws {
        let legacy = try JSONDecoder().decode(UISettings.self, from: Data(#"{"sidebarWidth":700,"animationsEnabled":false}"#.utf8))
        #expect(legacy.sidebarWidth == 700)
        #expect(legacy.aiTextSize == 15)
        #expect(legacy.translationTextSize == 15)
        #expect(!legacy.animationsEnabled)
        let bad = try JSONDecoder().decode(UISettings.self, from: Data(#"{"aiTextSize":"large","translationTextSize":999,"sidebarWidth":-1}"#.utf8))
        #expect(bad.aiTextSize == 15)
        #expect(bad.translationTextSize == 28)
        #expect(bad.sidebarWidth == 200)
    }

    @Test func independentSizesRoundTripAndClamp() throws {
        var ui = UISettings()
        ui.aiTextSize = 24
        ui.translationTextSize = 19
        let restored = try JSONDecoder().decode(UISettings.self, from: JSONEncoder().encode(ui))
        #expect(restored == ui)
        ui.aiTextSize = .nan
        ui.translationTextSize = -.infinity
        #expect(ui.aiTextSize == 15)
        #expect(ui.translationTextSize == 15)
    }
}

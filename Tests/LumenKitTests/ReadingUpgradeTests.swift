import Foundation
import Testing
@testable import LumenKit

@Suite("阅读布局与本地凭据回归")
struct ReadingUpgradeTests {
    @Test func liveCSSVariableNames() {
        let properties = CSSCustomProperties.parse(":root {\n --lm-bg: #252E36;\n --lm-paged: 1;\n --lm-columns: 2;\n}")
        #expect(properties["--lm-bg"] == "#252E36")
        #expect(properties["--lm-paged"] == "1")
        #expect(properties["--lm-columns"] == "2")
        #expect(properties["---lm-bg"] == nil)
    }

    @Test func finalPointerAndBounds() {
        #expect(PanelDragGeometry.width(start: 420, delta: -37, range: 300...600) == 383)
        #expect(PanelDragGeometry.width(start: 420, delta: 300, range: 300...600) == 600)
        #expect(PanelDragGeometry.width(start: 420, delta: -300, range: 300...600) == 300)
        #expect(PanelDragGeometry.width(start: .nan, delta: 20, range: 300...600) == 300)
    }
    @Test func clippedViewportAndOrientation() {
        let page = CGRect(x: 50, y: 100, width: 200, height: 400)
        let visible = CGRect(x: 0, y: 300, width: 200, height: 400)
        #expect(ReadingViewportGeometry.normalized(page: page, visible: visible, flipped: false) == CGRect(x: 0, y: 0, width: 0.75, height: 0.5))
        #expect(ReadingViewportGeometry.normalized(page: page, visible: visible, flipped: true) == CGRect(x: 0, y: 0.5, width: 0.75, height: 0.5))
        #expect(ReadingViewportGeometry.normalized(page: .zero, visible: visible, flipped: false) == nil)
        #expect(ReadingViewportGeometry.normalized(page: page, visible: CGRect(x: 999, y: 999, width: 10, height: 10), flipped: false) == nil)
    }
    @Test func legacyReaderSettings() throws {
        let reader = try JSONDecoder().decode(ReaderSettings.self, from: Data(#"{"themeID":"warm","fontScale":1.2}"#.utf8))
        #expect(reader.themeID == .warm)
        #expect(reader.fontScale == 1.2)
        #expect(!reader.epubDoubleColumn)
        #expect(!reader.pdfOriginalColors)
        var changed = reader
        changed.epubDoubleColumn = true
        changed.pdfOriginalColors = true
        #expect(try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(changed)) == changed)
    }
    @Test func credentialPermissionsAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CredentialFileStore(directory: root)
        #expect(store.save("test-only-value", account: "../account"))
        let fresh = CredentialFileStore(directory: root)
        #expect(fresh.read(account: "../account") == "test-only-value")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(store.save("replacement", account: "../account"))
        #expect(fresh.read(account: "../account") == "replacement")
        #expect(store.save("", account: "../account"))
        #expect(fresh.read(account: "../account") == nil)
        #expect(!store.save("unused", account: ""))
    }
}

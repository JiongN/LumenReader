import Foundation
import Testing
@testable import LumenKit

@Suite("快捷键路由与持久化回归")
struct KeyBindingRegressionTests {
    @Test("默认 ⌘+ 同时接受 ⌘= 和 ⇧⌘=")
    func plusMatchesBothPhysicalKeyboardPaths() {
        let increase = LumenAction.fontIncrease.defaultCombo
        #expect(increase.matches(KeyCombo(key: "=", modifiers: [.command])))
        #expect(increase.matches(KeyCombo(key: "+", modifiers: [.command, .shift])))
        #expect(!increase.matches(KeyCombo(key: "=", modifiers: [.command, .option])))
        #expect(!increase.matches(KeyCombo(key: "+", modifiers: [.command, .option, .shift])))
    }

    @Test("等价按键也不能绕过动作冲突检测")
    @MainActor
    func equivalentPlusBindingConflicts() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-key-conflict-\(UUID().uuidString).json")
        let store = KeyBindingStore(fileURL: file)
        let rejection = store.set(KeyCombo(key: "=", modifiers: [.command]), for: .goToPage)
        guard case .conflict(with: .fontIncrease, _)? = rejection else {
            Issue.record("⌘= 应识别为与默认 ⌘+ 放大冲突，实际为 \(String(describing: rejection))")
            return
        }
    }

    @Test("侧栏翻译页签有独立且唯一的 ⌘6 默认绑定")
    @MainActor
    func translationPaneHasItsOwnCommandSixShortcut() {
        #expect(LumenAction.showTranslation.defaultCombo == KeyCombo(key: "6", modifiers: [.command]))
        let store = KeyBindingStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-key-translation-\(UUID().uuidString).json"))
        let collision = LumenAction.allCases.filter {
            $0 != .showTranslation && store.combo(for: $0) == LumenAction.showTranslation.defaultCombo
        }
        #expect(collision.isEmpty)
    }

    @Test("损坏配置先备份，下一次改键不覆盖唯一原件")
    @MainActor
    func corruptOverridesAreBackedUpBeforeLaterSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-key-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("keybindings.json")
        let original = Data("{ 这不是合法 JSON".utf8)
        try original.write(to: file)

        let store = KeyBindingStore(fileURL: file)
        #expect(store.overrides.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("keybindings.json.corrupt-") }
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup) == original)

        #expect(store.set(KeyCombo(key: "j", modifiers: [.command, .shift]), for: .toggleSidebar) == nil)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try Data(contentsOf: file) != original)
    }
}

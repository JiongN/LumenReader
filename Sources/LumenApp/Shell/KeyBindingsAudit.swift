import Foundation
import LumenKit

/// 快捷键自检：`--keys-report 1`。
///
/// 为什么单独验这一块：快捷键是全项目里「逻辑密度最高、界面表现最弱」的一处——
/// 菜单、命令面板、设置页三处读同一份数据，谁读错了肉眼几乎看不出来；
/// 而「保留键 / 撞车 / 清空」这三条拒绝规则又只在按下键盘那一刻才有反馈。
/// 与其每改一次都去手点菜单试，不如让进程自己在启动时把表打出来、把规则跑一遍。
@MainActor
enum KeyBindingsAudit {

    static func run() {
        guard LaunchOptions.keysReport else { return }
        reportCurrentTable()
        verifyRules()
    }

    // MARK: - 当前生效的表

    private static func reportCurrentTable() {
        let store = KeyBindingStore()
        NSLog("[Lumen][keys] 当前快捷键表，共 \(LumenAction.allCases.count) 项")

        var taken: [KeyCombo: LumenAction] = [:]
        var clashes: [String] = []

        for group in LumenActionGroup.allCases {
            NSLog("[Lumen][keys] ── \(group.title) ──")
            for action in group.actions {
                let combo = store.combo(for: action)
                let tag = store.isCustomized(action) ? "  ← 已自定义" : ""
                NSLog("[Lumen][keys]   \(action.title) → \(combo?.displayOrDash ?? "—")\(tag)")

                guard let combo else { continue }
                if let other = taken[combo] {
                    clashes.append("\(action.title) 与 \(other.title) 都占着 \(combo.display)")
                } else {
                    taken[combo] = action
                }
            }
        }

        NSLog("[Lumen][keys] 撞车检查：\(clashes.isEmpty ? "无" : clashes.joined(separator: "；"))")

        let reserved = LumenAction.allCases.compactMap { action -> String? in
            guard let combo = store.combo(for: action), combo.isReservedBySystem else { return nil }
            return "\(action.title)=\(combo.display)"
        }
        NSLog("[Lumen][keys] 系统保留键占用：\(reserved.isEmpty ? "无" : reserved.joined(separator: "，"))")

        let cleared = LumenAction.allCases.filter { store.isCleared($0) }
        NSLog("[Lumen][keys] 已主动清空：\(cleared.isEmpty ? "无" : cleared.map(\.title).joined(separator: "，"))")
    }

    // MARK: - 规则验证

    /// 拿一个**临时文件**当存储，把 `KeyBindingStore` 的每条规则都实跑一遍。
    ///
    /// 必须用临时文件：这些用例里有 clear / resetAll 这类会清空内容的操作，
    /// 直接拿用户真正的 `keybindings.json` 来验，等于每次自检都把用户的改键清干净。
    private static func verifyRules() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumen-keybindings-audit.json")
        try? FileManager.default.removeItem(at: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        var passed = 0
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failures.append(name) }
        }

        let store = KeyBindingStore(fileURL: temp)
        let subject = LumenAction.toggleSidebar
        let other = LumenAction.toggleAIPanel

        // 1. 没改过时读到默认值
        check("默认值 = defaultCombo", store.combo(for: subject) == subject.defaultCombo)
        check("未改过时 isCustomized 为假", !store.isCustomized(subject))

        // 2. 改绑并被接受
        let custom = KeyCombo(key: "j", modifiers: [.command, .shift])
        check("合法改绑被接受", store.set(custom, for: subject) == nil)
        check("改绑后读到新值", store.combo(for: subject) == custom)
        check("isCustomized 转真", store.isCustomized(subject))

        // 3. 真的落盘了（换一个实例重新读）
        let reloaded = KeyBindingStore(fileURL: temp)
        check("重新加载后仍是新值", reloaded.combo(for: subject) == custom)

        // 4. 撞车被拒
        if case .conflict = store.set(custom, for: other) {
            check("撞车被拒绝", true)
        } else {
            check("撞车被拒绝", false)
        }

        // 5. 裸键被拒
        check("无修饰键被拒绝", store.set(KeyCombo(key: "j", modifiers: []), for: other) == .needsModifier)

        // 6. 系统保留键被拒
        if case .reservedBySystem = store.set(KeyCombo(key: "q", modifiers: [.command]), for: other) {
            check("⌘Q 被拒绝", true)
        } else {
            check("⌘Q 被拒绝", false)
        }

        // 7. 撞车 / 被拒都不能留下副作用
        check("被拒后原值未变", store.combo(for: other) == other.defaultCombo)

        // 8. 清空是「显式状态」，不等于恢复默认
        store.clear(subject)
        check("清空后 combo 为 nil", store.combo(for: subject) == nil)
        check("清空后 isCleared 为真", store.isCleared(subject))
        check("清空不等于重置", store.isCustomized(subject))

        // 9. 单项恢复默认
        store.reset(subject)
        check("恢复默认后回到 defaultCombo", store.combo(for: subject) == subject.defaultCombo)
        check("恢复默认后 isCleared 为假", !store.isCleared(subject))
        check("恢复默认后不再自定义", !store.isCustomized(subject))

        // 10. 全部恢复
        store.set(custom, for: subject)
        check("resetAll 前有自定义", store.hasAnyCustomization)
        store.resetAll()
        check("resetAll 后清空全部自定义", !store.hasAnyCustomization)

        // 11. 容错：文件里塞入已不存在的动作名，应当被过滤而不是整份读失败
        let legacy = #"{"aDeletedAction":{"key":"z","modifiers":["command"]},"toggleSidebar":{"key":"u","modifiers":["command"]}}"#
        try? legacy.data(using: .utf8)?.write(to: temp)
        let tolerant = KeyBindingStore(fileURL: temp)
        check("过滤掉不存在的动作名", tolerant.overrides.keys.contains("aDeletedAction") == false)
        check("同时保留有效项", tolerant.combo(for: subject) == KeyCombo(key: "u", modifiers: [.command]))

        // 12. 坏文件不应崩、也不应把文件删掉
        try? "这不是 JSON".data(using: .utf8)?.write(to: temp)
        let broken = KeyBindingStore(fileURL: temp)
        check("坏文件退回空表而不是崩溃", broken.overrides.isEmpty)
        check("坏文件保持原样（便于用户对照修复）", FileManager.default.fileExists(atPath: temp.path))

        NSLog(
            "[Lumen][keys] 规则验证：通过 \(passed) 项，失败 \(failures.count) 项"
                + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；"))
        )
    }
}

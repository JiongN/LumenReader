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
        NSLog("%@", "[Lumen][keys] 当前快捷键表，共 \(LumenAction.allCases.count) 项")

        var taken: [KeyCombo: LumenAction] = [:]
        var clashes: [String] = []

        for group in LumenActionGroup.allCases {
            NSLog("%@", "[Lumen][keys] ── \(group.title) ──")
            for action in group.actions {
                let combo = store.combo(for: action)
                let tag = store.isCustomized(action) ? "  ← 已自定义" : ""
                NSLog("%@", "[Lumen][keys]   \(action.title) → \(combo?.displayOrDash ?? "—")\(tag)")

                guard let combo else { continue }
                if let other = taken[combo] {
                    clashes.append("\(action.title) 与 \(other.title) 都占着 \(combo.display)")
                } else {
                    taken[combo] = action
                }
            }
        }

        NSLog("%@", "[Lumen][keys] 撞车检查：\(clashes.isEmpty ? "无" : clashes.joined(separator: "；"))")

        let reserved = LumenAction.allCases.compactMap { action -> String? in
            guard let combo = store.combo(for: action), combo.isReservedBySystem else { return nil }
            return "\(action.title)=\(combo.display)"
        }
        NSLog("%@", "[Lumen][keys] 系统保留键占用：\(reserved.isEmpty ? "无" : reserved.joined(separator: "，"))")

        let cleared = LumenAction.allCases.filter { store.isCleared($0) }
        NSLog("%@", "[Lumen][keys] 已主动清空：\(cleared.isEmpty ? "无" : cleared.map(\.title).joined(separator: "，"))")
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

        // 13. 全角 → 半角 归一化：**表驱动**逐项实跑，别只验一个。
        //     这是用户 keybindings.json 里 `】` 能生效的前提。
        for (full, half) in KeyCombo.fullWidthMap {
            check("归一化「\(full)」→「\(half)」",
                  KeyCombo.normalizedKey(String(full)) == String(half))
        }
        check("归一化大写 S → 小写 s", KeyCombo.normalizedKey("S") == "s")
        check("归一化数字 1 原样", KeyCombo.normalizedKey("1") == "1")
        check("归一化斜杠 / 原样", KeyCombo.normalizedKey("/") == "/")
        check("归一化接受特殊键名 leftArrow",
              KeyCombo.normalizedKey(KeyCombo.SpecialKey.leftArrow) == KeyCombo.SpecialKey.leftArrow)
        check("归一化拒绝 é（非 ASCII 可键入字符）", KeyCombo.normalizedKey("é") == nil)
        check("归一化拒绝 emoji", KeyCombo.normalizedKey("🙂") == nil)
        check("归一化拒绝汉字", KeyCombo.normalizedKey("中") == nil)
        // 全角空格（U+3000）虽在「全角」范畴，但空格不是可键入的「键」——
        // 空格键用特殊键名 `space` 表示，裸空格字符一律拒绝。
        check("归一化拒绝全角空格", KeyCombo.normalizedKey("　") == nil)

        // 14. 载入期迁移：含全角 】 的文件读进来，应被迁移成 ]（modifiers 不动）。
        //     对应用户现有那份坏配置——不迁移，「显示 / 隐藏 AI 面板」永远按不出来。
        let fullWidthJSON = #"{"toggleAIPanel":{"key":"】","modifiers":["option"]}}"#
        try? fullWidthJSON.data(using: .utf8)?.write(to: temp)
        let migrated = KeyBindingStore(fileURL: temp)
        check("载入时把全角 】 迁移成 ]",
              migrated.combo(for: .toggleAIPanel) == KeyCombo(key: "]", modifiers: [.option]))
        check("迁移保留 modifiers（仍是 ⌥）",
              migrated.combo(for: .toggleAIPanel)?.modifiers == [.option])

        // 15. 载入期丢弃不可键入的绑定并回落默认。
        let badKeyJSON = #"{"toggleAIPanel":{"key":"é","modifiers":["option"]}}"#
        try? badKeyJSON.data(using: .utf8)?.write(to: temp)
        let dropped = KeyBindingStore(fileURL: temp)
        check("载入时丢弃不可键入的绑定，回落默认",
              dropped.combo(for: .toggleAIPanel) == LumenAction.toggleAIPanel.defaultCombo)

        // 16. 「所有生效绑定的 key 都在可键入集合内」。
        //     修正前，用户的 toggleAIPanel 是 ⌥】，这条会红；迁移生效后必须绿。
        //     注意读的是**用户真实文件**（只读载入 + 必要的一次性迁移），不是临时文件。
        let live = KeyBindingStore()
        let notTypeable = LumenAction.allCases.compactMap { action -> String? in
            guard let combo = live.combo(for: action), !combo.isTypeableKey else { return nil }
            return "\(action.title)=\(combo.display)"
        }
        check("所有生效绑定的 key 都在可键入集合内", notTypeable.isEmpty)

        // 17. 不可键入的键经 set() 会被拒绝（录制器归一化之后的第二道闸）。
        //     用临时文件上的 store，避免万一归一化逻辑退化时把测试值写进用户配置。
        if case .keyNotTypeable = dropped.set(KeyCombo(key: "é", modifiers: [.command]), for: .goToPage) {
            check("set() 拒绝不可键入的 key", true)
        } else {
            check("set() 拒绝不可键入的 key", false)
        }

        NSLog(
            "[Lumen][keys] 规则验证：通过 \(passed) 项，失败 \(failures.count) 项"
                + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；"))
        )
    }
}

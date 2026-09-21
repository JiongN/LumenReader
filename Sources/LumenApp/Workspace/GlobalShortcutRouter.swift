import AppKit
import SwiftUI
import LumenKit

/// 全局快捷键路由。
///
/// 存在的理由：阅读器窗口由 AppKit（`WindowManager`）显式创建，不再是 SwiftUI 的
/// `WindowGroup` 场景。SwiftUI 的 `.commands { … }` 挂在 `Settings` 场景上时，
/// 主菜单里的各项会装上、但 `.keyboardShortcut` 的键等价物不会落地（实测所有
/// 命令菜单项都没有 keyEquivalent，而系统工具栏自动生成的 "Toggle Sidebar ⌘⌥S"
/// 反而抢占了 ⌘⌥S）——于是用户按 ⌘⌥S 触发的是那个什么都不做的系统项，快捷键整体失灵。
///
/// 这个路由在 AppKit 层直接监听 `keyDown`，从 `KeyBindingStore` 现取每个 `LumenAction`
/// 的组合，命中后路由到 `WindowManager.activeWorkspace`。菜单仍保留（可鼠标点击、
/// 可发现性在），但按键不再依赖 SwiftUI 的菜单键等价机制。
@MainActor
final class GlobalShortcutRouter {

    static let shared = GlobalShortcutRouter()

    private var monitor: Any?
    private var services: AppServices?

    /// 自检钩子：喂一条合成 keyDown，返回「是否被消费」。用于在无辅助功能权限的
    /// 环境下证明「组合键 → 动作」这条路真正通着，而不是靠读代码猜。
    @discardableResult
    func routeTest(_ event: NSEvent) -> Bool {
        handle(event) == nil
    }

    private init() {}

    func install(services: AppServices) {
        guard monitor == nil else { return }
        self.services = services
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private var workspace: AppState? {
        WindowManager.shared.activeWorkspace
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let services else { return event }
        guard let workspace, NSApp.keyWindow === workspace.window,
              let pressed = Self.pressedCombo(for: event) else { return event }
        let isEditing = NSApp.keyWindow?.firstResponder is NSTextView

        for action in LumenAction.allCases {
            guard let combo = services.keyBindings.combo(for: action),
                  combo == pressed else { continue }
            // 编辑正文时保留光标操作，但面板与 zoom 的显式快捷键仍可使用。
            if isEditing && ![LumenAction.toggleSidebar, .toggleAIPanel, .toggleImmersive].contains(action) {
                return event
            }
            // 命中用户配置的组合即整包吞掉，不取决于 isEnabled；否则禁用菜单项
            // （如欢迎页无文档时 toggleSidebar 的 keyEquivalent 禁用）会让系统响冲突音。
            if action.isEnabled(in: workspace) {
                action.run(workspace)
            } else if let hint = action.disabledHint {
                // 只有主动声明了「禁用原因」的动作才弹提示（如 PDF 下的字号调整），
                // 其余禁用项维持原样——把「假可用被换成哑巴」变成「有解释的静默」。
                workspace.showToast(hint)
            }
            return nil
        }
        return event
    }

    /// 把一个 keyDown 事件翻译成 `KeyCombo`。翻译规则与「快捷键录制」一致，
    /// 保证「录到的组合」和「路由匹配的组合」用的是同一套键名。
    private static func keyName(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return KeyCombo.SpecialKey.leftArrow
        case 124: return KeyCombo.SpecialKey.rightArrow
        case 125: return KeyCombo.SpecialKey.downArrow
        case 126: return KeyCombo.SpecialKey.upArrow
        case 53:  return KeyCombo.SpecialKey.escape
        case 48:  return KeyCombo.SpecialKey.tab
        case 49:  return KeyCombo.SpecialKey.space
        case 36, 76:  return KeyCombo.SpecialKey.return
        case 51, 117: return KeyCombo.SpecialKey.delete
        case 116: return KeyCombo.SpecialKey.pageUp
        case 121: return KeyCombo.SpecialKey.pageDown
        case 115: return KeyCombo.SpecialKey.home
        case 119: return KeyCombo.SpecialKey.end
        default: break
        }
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty,
              let scalar = characters.unicodeScalars.first,
              scalar.value >= 32, scalar.value != 127 else { return nil }
        let raw = String(characters.prefix(1))
        return KeyCombo.normalizedKey(raw) ?? raw
    }

    private static func pressedCombo(for event: NSEvent) -> KeyCombo? {
        guard let name = keyName(for: event) else { return nil }
        var modifiers: Set<KeyModifier> = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift)   { modifiers.insert(.shift) }
        if flags.contains(.option)  { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard !modifiers.isEmpty else { return nil }
        return KeyCombo(key: name, modifiers: modifiers)
    }
}

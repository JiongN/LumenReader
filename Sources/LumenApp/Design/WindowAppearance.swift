import SwiftUI
import AppKit

/// 让整个窗口的外观跟随阅读主题。
///
/// 为什么需要这个：侧栏与 AI 面板用的是 `Material`，而材质是由 `NSWindow.appearance`
/// 决定的。如果只改阅读区背景、不动窗口外观，深色主题下就会出现「近黑的正文区旁边
/// 贴着刺眼的亮白面板」，前面板的可读性反而下降。
///
/// 选择在阅读时由阅读主题统辖全局外观，而不是跟随系统深浅色：读者选「深夜」就是
/// 想要整屏暗下来，此时若系统仍是浅色而只有正文变暗，是更差的结果。
///
/// 用 `NSAppearance` 而不是 SwiftUI 的 `preferredColorScheme`，是因为后者在 macOS 上
/// 对材质与系统控件的覆盖面不如直接设窗口外观来得彻底。
struct WindowAppearanceSync: NSViewRepresentable {

    let isDark: Bool

    func makeNSView(context: Context) -> AppearanceProbeView {
        let view = AppearanceProbeView()
        view.isDark = isDark
        return view
    }

    func updateNSView(_ nsView: AppearanceProbeView, context: Context) {
        nsView.isDark = isDark
    }
}

/// 只做一件事：把「期望的外观」落到应用上。
///
/// 为什么是 `NSView` 子类而不是在 `updateNSView` 里直接 `DispatchQueue.main.async`：
/// `updateNSView` 只在状态变化时调用，而它首次执行时视图往往**还没被挂进窗口**
/// （`view.window` 为 nil），此时异步设一次就永久错过。覆写 `viewDidMoveToWindow`
/// 让「挂上窗口」这件事本身成为触发点，就与调用时机无关了。
///
/// 为什么设 `NSApp.appearance` 而不是 `NSWindow.appearance`：后者会被 SwiftUI 重置回
/// `nil`。实测（`--capture` 自检，设置里选「深夜」）：
/// ```
/// 11.301 [探针] 已设置窗口外观：darkAqua
/// 11.397 [探针] updateNSView isDark=true      ← 此时窗口还是 darkAqua
/// 14.731 [Lumen] appearance=nil effective=Aqua ← 3 秒后又被抹掉了
/// ```
/// 应用层级的外观在 SwiftUI 的控制范围之外，设一次就稳定生效。
/// 代价是它同时管到菜单栏——而这正好符合「选了深夜就整屏暗下来」的设计意图。
final class AppearanceProbeView: NSView {

    var isDark: Bool = false {
        didSet {
            guard oldValue != isDark else { return }
            applyToApp()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToApp()
    }

    private func applyToApp() {
        // 还没挂进窗口说明应用尚未成型，等 viewDidMoveToWindow 再设
        guard window != nil else { return }
        let target = NSAppearance(named: isDark ? .darkAqua : .aqua)
        guard NSApp.appearance?.name != target?.name else { return }
        NSApp.appearance = target
    }
}

extension View {
    /// 让窗口外观跟随给定的阅读主题。
    ///
    /// 尺寸给 1×1 而不是 0×0：零尺寸的背景视图可能被布局系统跳过，
    /// 视图不进层级就收不到 `viewDidMoveToWindow`，整条链路静默失效。
    func windowAppearance(isDark: Bool) -> some View {
        background(
            WindowAppearanceSync(isDark: isDark)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        )
    }
}

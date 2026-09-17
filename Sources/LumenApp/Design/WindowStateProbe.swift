import SwiftUI
import AppKit

/// 把「窗口级状态」接进 SwiftUI：记录主窗口，并把系统全屏的进出回报给 `AppState`。
///
/// 为什么必须有它：全屏是 **AppKit 的窗口状态**，沉浸是 **SwiftUI 的状态**，
/// 两者不会互相感知。此前只有「沉浸 → 全屏」这一条单向推送，于是用户用系统方式
/// （绿灯按钮 / 菜单「显示 → 退出全屏」/ ⌃⌘F）退出全屏时没有任何回程，
/// `isImmersive` 永远停在 true —— 两侧面板收不回来、正文一直限宽 880、
/// 工具栏被 `.toolbar(.hidden)` 锁死。用户观察到的现象就是
/// 「退出 zoom 后回不到正常页面」外加「工具栏不见了」。这个探针补的就是那条回程。
///
/// 为什么用 `NSView` 子类而不是在 `updateNSView` 里注册：`updateNSView` 只在
/// 状态变化时调用，而它首次执行时视图往往**还没挂进窗口**（`view.window` 为 nil），
/// 那次注册就永久错过了。覆写 `viewDidMoveToWindow` 让「挂上窗口」这件事本身
/// 成为触发点，就与调用时机无关。
final class WindowStateProbeView: NSView {

    var onWindow: ((NSWindow) -> Void)?
    var onFullScreenChange: ((Bool) -> Void)?

    /// 当前在监听哪个窗口。窗口被换掉（关一本再开一本）时要重新注册，
    /// 否则通知会一直指向已经销毁的旧窗口对象。
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onWindow?(window)
        observeFullScreen(of: window)
    }

    /// 视图要从窗口上摘下来时先退订，避免观察者残留。
    ///
    /// 不放在 `deinit` 里：`NSView` 是 MainActor 隔离的，`deinit` 不是，
    /// 在那里碰 `observers`（非 Sendable 数组）在严格并发下是隐患。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopObserving() }
    }

    private func observeFullScreen(of window: NSWindow) {
        guard observedWindow !== window else { return }
        stopObserving()
        observedWindow = window

        let center = NotificationCenter.default
        let watched: [(NSNotification.Name, Bool)] = [
            (NSWindow.didEnterFullScreenNotification, true),
            (NSWindow.didExitFullScreenNotification, false)
        ]
        for (name, entered) in watched {
            observers.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFullScreenChange?(entered) }
            })
        }
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        observedWindow = nil
    }
}

private struct WindowStateProbeRepresentable: NSViewRepresentable {

    let onWindow: (NSWindow) -> Void
    let onFullScreenChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowStateProbeView {
        let view = WindowStateProbeView()
        view.onWindow = onWindow
        view.onFullScreenChange = onFullScreenChange
        return view
    }

    func updateNSView(_ nsView: WindowStateProbeView, context: Context) {
        // 闭包本身每次都会被换新，但注册只发生在挂窗口那一刻，
        // 所以这里只更新回调、不重复注册。
        nsView.onWindow = onWindow
        nsView.onFullScreenChange = onFullScreenChange
    }
}

extension View {
    /// 把窗口挂上探针，并把结果转交给 `AppState`。
    ///
    /// 收成一个只吃 `AppState` 的方法，而不是对外暴露两个闭包：
    /// 调用点写成 `.windowState(onWindow: { … }, onFullScreenChange: { … })` 时，
    /// 两个闭包的参数类型推断会叠在本就很长的修饰符链上，
    /// 直接把编译器拖到 `unable to type-check this expression in reasonable time`。
    ///
    /// 尺寸给 1×1 而不是 0×0：零尺寸的背景视图可能被布局系统跳过，
    /// 视图不进层级就收不到 `viewDidMoveToWindow`，整条链路静默失效。
    func windowState(_ state: AppState) -> some View {
        background(
            WindowStateProbeRepresentable(
                onWindow: { state.adoptMainWindow($0) },
                onFullScreenChange: { state.systemFullScreenChanged($0) }
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        )
    }
}

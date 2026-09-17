import SwiftUI
import AppKit
import LumenKit

/// 动效规格。
///
/// 为什么不让 `DS.Motion` 直接返回 `Animation`：`Animation` 是不透明类型，
/// 拿到手之后**改不了它的时长**。要支持「紧凑 / 标准 / 舒缓」三档重采样，
/// 必须在构造 `Animation` 之前把参数拿到手，所以令牌统一用规格声明、由门里实例化。
enum MotionSpec {
    case spring(response: Double, dampingFraction: Double)
    case easeInOut(duration: Double)
    case easeOut(duration: Double)
    case linear(duration: Double)

    func animation(timeScale: Double) -> Animation {
        switch self {
        case let .spring(response, damping):
            return .spring(response: response * timeScale, dampingFraction: damping)
        case let .easeInOut(duration):
            return .easeInOut(duration: duration * timeScale)
        case let .easeOut(duration):
            return .easeOut(duration: duration * timeScale)
        case let .linear(duration):
            return .linear(duration: duration * timeScale)
        }
    }
}

/// 全局动效门：所有动效令牌的唯一出口。
///
/// 三条策略都收在这里，改一处即全局生效：
/// 1. 用户关闭动效 → 零时长。注意**不是"把时长调小"**——调小之后位移依然可感知，
///    对前庭功能敏感的用户等于没关。
/// 2. 系统「减弱动态效果」→ 同上降级为零时长。默认尊重系统设置（HIG 要求），
///    但允许用户显式关掉这个尊重——系统偏好有时是给别的应用开的。
/// 3. 速度档 → 把时长乘以倍率（`spring(response:)` 也一并缩放，否则弹簧动效不听档位）。
///
/// **能力边界（不承诺"一处开关全静音"）**：SwiftUI 的隐式动画 `.animation(_:value:)`、
/// 系统 List 折叠、`NSMenu` 展开、以及 AppKit 控件自带的高亮/选中动画都不经过这里。
/// 要盖住它们得逐个替换成显式动画，代价大于收益。
@MainActor
enum MotionGate {

    static var isEnabled = true
    static var respectsSystemReduceMotion = true
    private(set) static var speedScale = 1.0

    /// 系统偏好缓存。不每次读 `NSWorkspace`——那是同步 IPC，不能出现在动画热路径上。
    private(set) static var systemReduceMotion =
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private static var preferenceObserver: NSObjectProtocol?

    /// 当前是否处于「动效静音」状态。设置页用它给出说明文案。
    static var isMuted: Bool {
        !isEnabled || (respectsSystemReduceMotion && systemReduceMotion)
    }

    /// 把设置灌进来。设置页每次改动都会走到这里。
    static func apply(_ ui: UISettings) {
        isEnabled = ui.animationsEnabled
        respectsSystemReduceMotion = ui.respectsSystemReduceMotion
        speedScale = ui.motionSpeed.timeScale

        NSLog(
            "[Lumen] 动效门：动效=\(isEnabled ? "开" : "关") 速度=\(speedScale)× "
                + "系统减弱动态=\(systemReduceMotion ? "是" : "否") → 静音=\(isMuted ? "是" : "否")"
        )
    }

    /// 订阅系统「减弱动态效果」的变化。只装一次，进程内长期有效。
    static func observeSystemPreference() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    /// 单一决策点。
    static func resolve(_ spec: MotionSpec) -> Animation {
        guard !isMuted else { return .linear(duration: 0) }
        return spec.animation(timeScale: speedScale)
    }
}

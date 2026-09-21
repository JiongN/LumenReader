import Foundation
import LumenKit

/// 字号调整这一步的纯函数结果。
///
/// 把「这一步是越界了还是真生效了」显式建模出来，快捷键路径（`LumenActionRunner`）
/// 才能据此决定要不要弹提示，而滑块路径（直接写 `settingsStore.reader.fontScale`）
/// 永远不弹——详见 `AppState.stepFontScale` 的注释。
enum FontScaleStep: Equatable {
    /// 真的调整到了 `scale`（已在 `[min, max]` 内吸附干净）。
    case applied(scale: Double)
    /// 撞到边界，`scale` 是夹取后的边界值，`isMin` 标是下限还是上限。
    case atLimit(scale: Double, isMin: Bool)

    /// 结果里最终落到的字号值（两种情形都取得到）。
    var scale: Double {
        switch self {
        case .applied(let s), .atLimit(let s, _): return s
        }
    }
}

/// 字号倍率调整策略（纯函数，不碰任何全局状态）。
///
/// 独立成纯函数的理由：旧的 `min(max(current + delta, 0.6), 2.4)` 写法在
/// `current` 是浮点脏值（用户 settings.json 里真实存在 `0.6000000000000001`）
/// 时，按 ⌘- 算出 `0.6`，但 `0.6 != 0.6000000000000001`（差 1e-16）——若有人用
/// 「新值 == 旧值 才判定到边界」这种写法，会判成「成功应用了」，
/// 于是「按了没反应」被伪装成「修好了」。这里改用「夹取 + 容差比较 + 吸附」：
///
/// 1. 先把 `current` 夹到 `[min, max]` 得到 `c`，清掉浮点脏值；
/// 2. 算 `n = min(max(c + delta, min), max)`；
/// 3. `abs(n - c) < 1e-9` → `.atLimit`（变化量小于容差，视为没动）；
/// 4. 否则 `.applied(n)`，并把 `n` 吸附写回（顺手把脏值清成干净边界）。
enum FontScale {
    static let min: Double = ReaderSettings.fontScaleMin
    static let max: Double = ReaderSettings.fontScaleMax

    /// 上限 1e-9：字号步长是 0.05/0.1，任何「真生效」的步子都远大于此；
    /// 只有浮点误差（1e-16 量级）和刻意抖动才会落在这个区间，应判为「没动」。
    private static let epsilon: Double = 1e-9

    static func next(current: Double, delta: Double) -> FontScaleStep {
        // 1) 先把当前值夹进合法区间，并把「贴着边界」的浮点脏值吸附成精确边界。
        // 必须写 `Swift.min` / `Swift.max`：本枚举自己声明了 `static let min` / `max`，
        // 类型体内的裸 `min`/`max` 会被它遮蔽掉，编译报
        // 「use of 'min' refers to instance method rather than global function」。
        let c = snapToBound(Swift.min(Swift.max(current, FontScale.min), FontScale.max))
        // 2) 目标值同样夹取 + 吸附。
        let n = snapToBound(Swift.min(Swift.max(c + delta, FontScale.min), FontScale.max))
        // 3) 容差判定：变化量小到可以忽略，视为已到边界。
        // 注意返回 `c` 而不是 `n`：`.atLimit` 的语义是「停在原地」，而 `n` 是夹取后的
        // 目标值——两者只在「真的越过边界」时相等。刻意抖动（如 delta=1e-10）的情形下
        // 应当如实返回「当前值没动」，而不是假装动了一个不可见的量。
        if Swift.abs(n - c) < FontScale.epsilon {
            return .atLimit(scale: c, isMin: delta < 0)
        }
        // 4) 真生效，吸附到 n 写回。
        return .applied(scale: n)
    }

    /// 把「与某个边界只差浮点误差」的脏值吸附成精确的边界值。
    ///
    /// 用户 `settings.json` 里真实存在 `reader.fontScale = 0.6000000000000001` ——
    /// 它是历史浮点误差累积的产物。不吸附的话这个脏值会永远留在配置里，
    /// 任何 `==` 比较都不可靠（本轮「按了 ⌘- 没反应」的根因之一正是它）。
    /// 吸附之后「连续按 ⌘-」能真正把配置收干净成 `0.6`。
    private static func snapToBound(_ value: Double) -> Double {
        if Swift.abs(value - FontScale.min) < FontScale.epsilon { return FontScale.min }
        if Swift.abs(value - FontScale.max) < FontScale.epsilon { return FontScale.max }
        return value
    }
}

import SwiftUI
import AppKit

// MARK: - 动态色工具

public extension Color {
    /// 同时提供浅色与深色取值，随系统外观自动切换。
    static func dual(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

public extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - 设计令牌

/// 全局视觉常量。所有颜色、间距、圆角、动效都从这里取，禁止在视图里写魔数。
public enum DS {

    // MARK: 间距

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: 圆角

    public enum Radius {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 10
        public static let l: CGFloat = 14
        public static let xl: CGFloat = 20
    }

    // MARK: 语义色

    public enum Palette {
        /// 主强调色：克制的靛蓝，接近 Apple 的 accent 但不抢阅读内容的注意力
        public static let accent = Color.dual(
            light: NSColor(hex: 0x2F5BEA),
            dark: NSColor(hex: 0x6B8CFF)
        )

        public static let accentSoft = Color.dual(
            light: NSColor(hex: 0x2F5BEA, alpha: 0.10),
            dark: NSColor(hex: 0x6B8CFF, alpha: 0.16)
        )

        /// 正文主色（UI 区域，不是阅读区）
        public static let textPrimary = Color.dual(
            light: NSColor(hex: 0x1C1C1E),
            dark: NSColor(hex: 0xF2F2F7)
        )

        public static let textSecondary = Color.dual(
            light: NSColor(hex: 0x6C6C70),
            dark: NSColor(hex: 0x9A9AA0)
        )

        public static let textTertiary = Color.dual(
            light: NSColor(hex: 0x9A9AA0),
            dark: NSColor(hex: 0x6C6C70)
        )

        public static let separator = Color.dual(
            light: NSColor(hex: 0x000000, alpha: 0.08),
            dark: NSColor(hex: 0xFFFFFF, alpha: 0.10)
        )

        public static let surfaceRaised = Color.dual(
            light: NSColor(hex: 0xFFFFFF),
            dark: NSColor(hex: 0x1E1E20)
        )

        public static let surfaceSunken = Color.dual(
            light: NSColor(hex: 0xF5F5F7),
            dark: NSColor(hex: 0x141416)
        )

        /// 状态色
        public static let success = Color.dual(light: NSColor(hex: 0x1DA05A), dark: NSColor(hex: 0x37D07A))
        public static let warning = Color.dual(light: NSColor(hex: 0xC77700), dark: NSColor(hex: 0xF0A93B))
        public static let danger  = Color.dual(light: NSColor(hex: 0xD22B2B), dark: NSColor(hex: 0xFF6B6B))
    }

    // MARK: 排版

    /// 界面字体令牌。
    ///
    /// 全部是计算属性而不是 `static let`：界面字体可以换成系统里的任意字体族，
    /// 而 SwiftUI 没有官方的"全局界面字体"开关，只能让每个取字体的地方都经过 `UIFontGate`。
    /// 没设界面字体时，这些令牌与 `Font.system(size:weight:design:)` 完全等价。
    @MainActor
    public enum Typo {

        /// 界面通用取字体入口。
        ///
        /// 全应用原本直接调用 `Font.system(size:weight:design:)` 的地方全部改走这里。
        /// 参数名与默认值刻意与 `Font.system` 保持一致，好让替换是纯粹的机械改写——
        /// 语义完全不变，要回退也只是把这里的转发改掉。
        public static func ui(
            size: CGFloat,
            weight: Font.Weight = .regular,
            design: Font.Design = .default
        ) -> Font {
            UIFontGate.font(size: size, weight: weight, design: design)
        }

        public static var display: Font { ui(size: 34, weight: .bold, design: .rounded) }
        public static var title: Font { ui(size: 22, weight: .semibold) }
        public static var headline: Font { ui(size: 15, weight: .semibold) }
        public static var body: Font { ui(size: 13.5) }
        public static var callout: Font { ui(size: 12.5) }
        public static var caption: Font { ui(size: 11, weight: .medium) }
        public static var mono: Font { ui(size: 12, design: .monospaced) }

        /// AI 回复正文：行高放宽，长文可读
        public static var aiBody: Font { ui(size: 13.5) }
    }

    // MARK: 动效

    /// 动效令牌。
    ///
    /// 形态是「参数化规格 + `MotionGate` 解析」，不是 `static let Animation`：
    /// 只有这样才能支持关闭动效与速度档（详见 `MotionGate`）。
    /// 调用点写法不变，仍是 `withAnimation(DS.Motion.panel)`。
    @MainActor
    public enum Motion {
        /// 面板展开 / 收起
        public static var panel: Animation {
            MotionGate.resolve(.spring(response: 0.34, dampingFraction: 0.86))
        }
        /// 小控件反馈
        public static var quick: Animation {
            MotionGate.resolve(.spring(response: 0.22, dampingFraction: 0.88))
        }
        /// 内容切换
        public static var content: Animation {
            MotionGate.resolve(.easeInOut(duration: 0.18))
        }
        /// 悬停
        public static var hover: Animation {
            MotionGate.resolve(.easeOut(duration: 0.12))
        }
        /// 入场（欢迎页、空状态、浮动条上浮）
        public static var reveal: Animation {
            MotionGate.resolve(.easeOut(duration: 0.26))
        }
        /// 主题切换。只作用于外壳（侧栏 / AI 面板 / 工具条），阅读内容层不参与——
        /// PDF 会重绘、WebView 会闪，把它们卷进动画是自找难看。
        public static var theme: Animation {
            MotionGate.resolve(.easeInOut(duration: 0.25))
        }
        /// 命令面板：遮罩淡入 + 卡片缩放弹入
        public static var palette: Animation {
            MotionGate.resolve(.spring(response: 0.26, dampingFraction: 0.82))
        }
    }

    // MARK: 尺寸

    public enum Size {
        public static let toolbarHeight: CGFloat = 44
        public static let sidebarMin: CGFloat = 200
        public static let sidebarIdeal: CGFloat = 248
        public static let sidebarMax: CGFloat = 360
        public static let aiPanelMin: CGFloat = 300
        public static let aiPanelIdeal: CGFloat = 380
        public static let aiPanelMax: CGFloat = 620
    }
}

import SwiftUI
import LumenKit

/// 阅读主题的唯一定义源。
///
/// 同时产出 SwiftUI 的 `Color` 和注入 WebView 的 CSS 变量字符串，避免两边色值漂移。
public struct ReadingTheme: Sendable, Equatable {

    public let id: ReadingThemeID
    public let backgroundHex: UInt32
    public let surfaceHex: UInt32
    public let textHex: UInt32
    public let secondaryTextHex: UInt32
    public let accentHex: UInt32
    public let isDark: Bool

    public var background: Color { Color(hex: backgroundHex) }
    public var surface: Color { Color(hex: surfaceHex) }
    public var text: Color { Color(hex: textHex) }
    public var secondaryText: Color { Color(hex: secondaryTextHex) }
    public var accent: Color { Color(hex: accentHex) }

    /// 选区高亮：浅色主题用低透明度强调色，深色主题需要提高透明度才看得见。
    public var selection: Color { Color(hex: accentHex, alpha: isDark ? 0.30 : 0.20) }

    // MARK: - 预设

    public static let paper = ReadingTheme(
        id: .paper, backgroundHex: 0xF5F4EF, surfaceHex: 0xEAECE8,
        textHex: 0x292D30, secondaryTextHex: 0x62686A, accentHex: 0x38657B, isDark: false
    )

    /// 暖黄（护眼）——本批降饱和后的取值（用户选定 B 档）。
    ///
    /// 换算依据：**色相不变**，饱和度 ×0.60、明度 +2%。压的是「视觉刺激」而不是「暖意」——
    /// 旧值在长时间阅读下偏「扎眼」，降的是刺激度，暖调本身保留（色相未动）。
    /// 换算后对比度（WCAG 相对亮度）：正文/背景 10.2:1、次要 4.6:1、强调 4.1:1。
    /// 旧值（供 `--theme-report` 的「只调了一个主题」断言核对）：
    /// 0xF3EBDD / 0xE8DFCF / 0x393229 / 0x71634F / 0x806344。
    public static let warm = ReadingTheme(
        id: .warm, backgroundHex: 0xF8F3EB, surfaceHex: 0xEDE8DE,
        textHex: 0x3E3A34, secondaryTextHex: 0x766D61, accentHex: 0x857360, isDark: false
    )

    public static let sage = ReadingTheme(
        id: .sage, backgroundHex: 0xE8ECE3, surfaceHex: 0xDDE3D7,
        textHex: 0x2E3730, secondaryTextHex: 0x5C685A, accentHex: 0x596C53, isDark: false
    )

    public static let dusk = ReadingTheme(
        id: .dusk, backgroundHex: 0x252E36, surfaceHex: 0x2E3841,
        textHex: 0xDBE2E5, secondaryTextHex: 0xAFBBC2, accentHex: 0x91AFC0, isDark: true
    )

    public static let midnight = ReadingTheme(
        id: .midnight, backgroundHex: 0x202326, surfaceHex: 0x292D30,
        textHex: 0xD5D8D6, secondaryTextHex: 0xAFB8B2, accentHex: 0x9BAEAA, isDark: true
    )

    /// 可选主题列表。
    ///
    /// **不含纯黑（`.oled`）**。去掉它不是审美偏好，是取舍结果：
    /// 纯黑只在 OLED 屏上省电，LCD 上并不省；而它把对比度推到极限，
    /// 白字贴在 #000000 上会让中文的细笔画发虚、光晕明显，长时间阅读的眼压反而更高。
    /// 「深夜」已经足够暗（#16181D），且保留了层次。
    /// `ReadingThemeID.oled` 这个 case 仍然保留，只为让旧配置能解码，
    /// 见该 case 上的注释与 `ReadingThemeID.migrated`。
    public static let all: [ReadingTheme] = [.paper, .warm, .sage, .dusk, .midnight]

    public static func theme(for id: ReadingThemeID) -> ReadingTheme {
        // 走 `.migrated`：废弃主题在这里也能拿到正确落点，
        // 而不是掉进 `?? .paper` 变成浅色——对选了深色的用户来说，
        // 「主题被重置成纸白」比「主题变成另一个深色」难受得多。
        all.first { $0.id == id.migrated } ?? .paper
    }

    // MARK: - CSS 生成

    private func cssHex(_ value: UInt32) -> String {
        String(format: "#%06X", value)
    }

    public static func cssFontStack(for family: ReadingFontFamily) -> String {
        switch family {
        case .system:
            return #"-apple-system, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", system-ui, sans-serif"#
        case .serif:
            return #""Songti SC", "Source Han Serif SC", "Noto Serif CJK SC", "SimSun", Georgia, serif"#
        case .rounded:
            return #""SF Pro Rounded", "PingFang SC", system-ui, sans-serif"#
        case .mono:
            return #""SF Mono", "Menlo", "PingFang SC", monospace"#
        }
    }

    /// 把族名安全地写进 CSS。
    ///
    /// 必须加引号：系统里带空格的族名一抓一大把（`Songti SC`、`Helvetica Neue`），
    /// 不加引号 CSS 解析器会把它当成多个字体名，等于换了个字体。
    /// 另外族名里理论上可能出现引号，一律去掉，避免把 `font-family` 声明截断——
    /// 这属于注入风险，不是排版问题。
    private static func quotedFamily(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        return "\"\(cleaned)\""
    }

    /// 正文的真实字体栈：用户显式挑的字体排在分组预设前面。
    ///
    /// 顺序不能反——后面那几个是兜底，用来接住选中字体缺字形的情况（尤其中文）。
    public static func cssFontStack(reader: ReaderSettings) -> String {
        let preset = cssFontStack(for: reader.fontFamily)
        guard let picked = reader.readingFontFamilyName?
            .trimmingCharacters(in: .whitespacesAndNewlines), !picked.isEmpty else {
            return preset
        }
        return "\(quotedFamily(picked)), \(preset)"
    }

    /// 生成注入 `:root` 的 CSS 变量。主题 / 字号 / 行高的切换只改这些值，
    /// 不需要重载文档，因而不会闪烁。
    public func cssVariables(reader: ReaderSettings) -> String {
        let baseSize = 17.0 * reader.fontScale
        return """
        :root {
          --lm-bg: \(cssHex(backgroundHex));
          --lm-surface: \(cssHex(surfaceHex));
          --lm-text: \(cssHex(textHex));
          --lm-text-secondary: \(cssHex(secondaryTextHex));
          --lm-accent: \(cssHex(accentHex));
          --lm-accent-soft: \(cssHex(accentHex))\(isDark ? "4D" : "33");
          --lm-font-family: \(Self.cssFontStack(reader: reader));
          --lm-font-size: \(String(format: "%.1f", baseSize))px;
          --lm-line-height: \(String(format: "%.2f", reader.lineHeight));
          --lm-letter-spacing: \(String(format: "%.3f", reader.letterSpacing))em;
          --lm-text-align: \(reader.textAlign.cssValue);
          --lm-para-spacing: \(String(format: "%.2f", reader.paragraphSpacing))em;
          --lm-content-width: \(Int(reader.contentWidth))px;
          --lm-columns: \(reader.epubDoubleColumn ? 2 : 1);
          --lm-paged: \(reader.epubDoubleColumn || reader.flowMode == .paged ? 1 : 0);
          --lm-selection: \(cssHex(accentHex))\(isDark ? "4D" : "33");
        }
        """
    }

    /// 阅读区基础样式表。与上面的变量配合使用。
    ///
    /// **为什么排版属性都带 `!important`**：这份样式表由 `WKUserScript` 在
    /// `documentStart` 时插进 `<head>`（或 `<html>`），而电子书自带的 CSS 是解析到
    /// `<link>` 时才插入的——也就是说**我们这份很可能排在书的 CSS 前面**，同权重比较时反而输。
    /// 不加 `!important` 的话，书里一句 `body { font-family: serif }` 就能让用户的字体设置失效，
    /// 而用户会以为是设置没生效。
    ///
    /// 但对齐是个例外：诗集、图注、引文块常常靠 `p.centered` 这类作者样式来居中，
    /// 强行覆盖会把排版压平。所以对齐只对**没有 class / 没有 style 的朴素段落**用 `!important`，
    /// 作者显式指定过的段落一律尊重。
    public static let readerStylesheet = """
    html { -webkit-text-size-adjust: 100%; }
    body {
      background: var(--lm-bg) !important;
      color: var(--lm-text) !important;
      font-family: var(--lm-font-family) !important;
      font-size: var(--lm-font-size) !important;
      line-height: var(--lm-line-height) !important;
      letter-spacing: var(--lm-letter-spacing) !important;
      margin: 0;
      box-sizing: border-box !important;
      width: 100% !important;
      min-width: 0 !important;
      max-width: none !important;
      padding: 28px clamp(24px, 5vw, 72px) 64px !important;
      margin: 0 !important;
      overflow-wrap: anywhere;
      /* 中文排版：两端对齐 + 行内避头尾 + 标点悬挂 */
      text-align: var(--lm-text-align);
      text-justify: inter-ideograph;
      line-break: strict;
      word-break: normal;
      overflow-wrap: break-word;
      hanging-punctuation: allow-end;
      -webkit-font-smoothing: antialiased;
      tab-size: 4;
    }
    p { margin: 0 0 var(--lm-para-spacing) 0; text-indent: 0; text-align: var(--lm-text-align); }
    /* 朴素段落：用户设置优先 */
    p:not([class]):not([style]),
    li:not([class]):not([style]) {
      text-align: var(--lm-text-align) !important;
      font-family: var(--lm-font-family) !important;
      font-size: var(--lm-font-size) !important;
      line-height: var(--lm-line-height) !important;
      letter-spacing: var(--lm-letter-spacing) !important;
    }
    /* 中文段落首行缩进两字符，西文段落不缩进 */
    p:lang(zh) { text-indent: 2em; }
    h1, h2, h3, h4, h5, h6 {
      color: var(--lm-text);
      line-height: 1.35;
      margin: 1.6em 0 0.7em 0;
      font-weight: 650;
      text-align: left;
      text-indent: 0;
      break-after: avoid;
    }
    h1 { font-size: 1.7em; }
    h2 { font-size: 1.4em; }
    h3 { font-size: 1.18em; }
    h4, h5, h6 { font-size: 1.04em; }
    a { color: var(--lm-accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    img, svg, video {
      max-width: 100%;
      height: auto;
      display: block;
      margin: 1.1em auto;
    }
    /* 单独成段的图片不要额外上边距，避免连续插图之间出现大空白 */
    figure { margin: 1.4em 0; text-align: center; }
    figcaption { font-size: 0.86em; color: var(--lm-text-secondary); margin-top: 0.6em; text-align: center; text-indent: 0; }
    blockquote {
      margin: 1.2em 0;
      padding: 0.1em 0 0.1em 1em;
      border-left: 3px solid var(--lm-accent);
      color: var(--lm-text-secondary);
      font-style: normal;
    }
    blockquote p { text-indent: 0; }
    code, pre, kbd, samp { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    code { font-size: 0.9em; background: var(--lm-surface); padding: 0.12em 0.34em; border-radius: 4px; }
    pre {
      background: var(--lm-surface);
      padding: 0.9em 1em;
      border-radius: 8px;
      overflow-x: auto;
      font-size: 0.86em;
      line-height: 1.55;
      text-align: left;
    }
    pre code { background: none; padding: 0; }
    table {
      border-collapse: collapse;
      width: 100%;
      margin: 1.2em 0;
      font-size: 0.92em;
      text-align: left;
    }
    th, td { border: 1px solid var(--lm-accent-soft); padding: 0.5em 0.7em; text-indent: 0; }
    th { background: var(--lm-surface); font-weight: 600; }
    hr { border: none; border-top: 1px solid var(--lm-accent-soft); margin: 2em 0; }
    ul, ol { padding-left: 1.5em; margin: 0 0 var(--lm-para-spacing) 0; }
    li { margin-bottom: 0.32em; text-indent: 0; text-align: var(--lm-text-align); }
    sup, sub { line-height: 0; font-size: 0.76em; }
    ::selection { background: var(--lm-selection); }
    /* 脚注返回链接不要撑乱版心 */
    a[epub|type~="noteref"], a[role="doc-noteref"] { font-size: 0.76em; vertical-align: super; line-height: 0; }
    """

    /// 分页模式的附加样式（EPUB 用 CSS 多列实现翻页）。
    public static let pagedStylesheet = """
    html, body { height: 100%; overflow: hidden; }
    body {
      column-width: var(--lm-content-width);
      column-gap: 0;
      height: 100%;
      padding-top: 0;
    }
    """
}

public extension ReaderSettings {
    var theme: ReadingTheme { ReadingTheme.theme(for: themeID) }
}

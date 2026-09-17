import SwiftUI
import LumenKit

/// 界面字体的唯一出口。
///
/// 为什么要有这一层：SwiftUI 里换掉全局界面字体没有官方办法——`.environment(\.font,)` 只影响
/// **没有显式 `.font(...)` 的**文本，而这个应用的界面文字几乎处处显式指定了字号。
///
/// 所以走的是"把调用点统一收口"的路子：全应用原本直接取系统字体的地方，
/// 统一改走 `DS.Typo.ui(size:weight:design:)`。这个替换是**语义等价**的——
/// 没设界面字体时 `ui(...)` 原样转发给 `Font.system(...)`，一个像素都不差。
@MainActor
enum UIFontGate {

    private(set) static var familyName: String?

    static func apply(_ ui: UISettings) {
        let trimmed = ui.uiFontFamilyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        familyName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// 取一个界面字体。
    ///
    /// `design` 不为 `.default` 时**忽略自定义字体、继续用系统字体**：等宽与圆体是 SF 的设计
    /// 变体，换成一个普通字体族就丢了这些语义——页码、代码块会从等宽变成比例字体，那是明确的功能退化。
    /// 宁可让这几处不跟随设置，也不让它们变得不对。
    static func font(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        guard let family = familyName, design == .default else {
            return .system(size: size, weight: weight, design: design)
        }
        return Font.custom(family, size: size).weight(weight)
    }
}

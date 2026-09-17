import SwiftUI

/// 全局提示。两种形态：单按钮的告知，和带确认按钮的询问。
///
/// `action` 是闭包，所以 `Equatable` 只能按 id 比——这正是我们想要的：
/// 两个内容相同的确认请求也应当各自独立地弹一次。
struct AppAlert: Identifiable, Equatable {

    enum Kind: Equatable {
        case message
        case confirm(confirmTitle: String, isDestructive: Bool)
    }

    let id = UUID()
    var title: String
    var message: String
    var kind: Kind = .message
    /// 点确认后执行。告知形态下为 nil。
    var action: (() -> Void)?

    static func == (lhs: AppAlert, rhs: AppAlert) -> Bool { lhs.id == rhs.id }
}

/// 轻量提示条。用于「已复制」这类不需要用户决策的反馈。
struct StatusToast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool = false
}

/// 长任务进度。`progress` 为 nil 表示还没法估进度（显示不确定态）。
struct BusyState: Equatable {
    var title: String
    var detail: String = ""
    var progress: Double?
}

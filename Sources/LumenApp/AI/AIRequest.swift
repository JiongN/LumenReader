import SwiftUI
import AppKit
import LumenKit

/// 划词浮动条投递的 AI 请求。
struct AIRequest: Identifiable, Equatable {

    enum Kind: String, Equatable {
        case explain      // 解释选中内容
        case translate    // 翻译
        case ask          // 就选中内容追问
        case summarize    // 总结本章
        case summarizeAll // 总结全书（命令面板用）
        case custom       // 自定义提示词

        var title: String {
            switch self {
            case .explain:      return "解释"
            case .translate:    return "翻译"
            case .ask:          return "追问"
            case .summarize:    return "总结"
            case .summarizeAll: return "总结全书"
            case .custom:       return "自定义"
            }
        }

        var systemImage: String {
            switch self {
            case .explain:      return "sparkles"
            case .translate:    return "character.book.closed"
            case .ask:          return "bubble.left.and.text.bubble.right"
            case .summarize:    return "text.append"
            case .summarizeAll: return "book.closed"
            case .custom:       return "wand.and.stars"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var selection: ReaderSelection?
    /// 该请求发生的定位（用于生成引用）
    var locator: DocumentLocator?
    /// 自定义提示词（kind == .custom 时使用）
    var customPrompt: String = ""

    init(kind: Kind, selection: ReaderSelection? = nil, locator: DocumentLocator? = nil, customPrompt: String = "") {
        self.kind = kind
        self.selection = selection
        self.locator = locator ?? selection?.locator
        self.customPrompt = customPrompt
    }

    static func == (lhs: AIRequest, rhs: AIRequest) -> Bool { lhs.id == rhs.id }
}

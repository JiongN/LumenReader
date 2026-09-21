import Foundation
import LumenKit

/// 跨文档引用降级策略（纯函数，可自检，见 `ConversationAudit`）。
///
/// 全局共享会话之后，一条回答的引用很可能指向**另一本书**——
/// 光看回答本身分不出它属于哪份文档，因此「点引用跳回原文」这个动作必须被精确门控：
/// 只有引用指向**当前正在看的这份文档**时才允许跳。否则会出现「点了第 5 页，
/// 却跳到了另一本书的第 5 页」这种事实性错误（正确性红线）。
///
/// 判定规则（fail-safe，任何拿不准的情况都降级为「不可跳」）：
/// - 先取来源文档路径：优先用气泡自己的 `bubbleDocPath`（最精确，逐条提问的真实出处），
///   它为空时退回会话的「出身」文档 `conversationDocPath`（首问时记下的那份书）；
/// - 两者都为 `nil`（从旧版本迁移来的会话、或一段没有文档上下文的整书总结）→ 不可跳；
/// - 来源与「当前正在看的文档」`currentDocPath` 不一致 → 跨文档引用，不可跳。
struct ConversationCitationPolicy {

    /// 这条引用在当前文档里能不能跳。
    ///
    /// - Parameters:
    ///   - locator: 引用指向的位置（页码 / 章节），本函数不读它的值——能否跳转只取决于
    ///     「来源文档是不是当前文档」，与具体位置无关。位置值留给视图去渲染编号。
    ///   - bubbleDocPath: 这条气泡（提问或回答）的来源文档路径，最精确。
    ///   - conversationDocPath: 会话整体的「出身」文档路径（首问时记下）。
    ///   - currentDocPath: 用户当前正在阅读的文档路径（`OpenDocument.id` 即其标准化路径）。
    static func isActive(
        locator: DocumentLocator,
        bubbleDocPath: String?,
        conversationDocPath: String?,
        currentDocPath: String?
    ) -> Bool {
        // 静默消费未使用参数告警：locator 仅用于让调用点语义自解释，不影响判定。
        _ = locator
        let source = bubbleDocPath ?? conversationDocPath
        guard let source, let current = currentDocPath else { return false }
        return source == current
    }
}

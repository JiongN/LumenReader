import Foundation
import SwiftUI
import Combine
import LumenKit

/// AI 面板头部「会话」菜单的项（纯数据，可自检，见 `ConversationAudit`）。
///
/// 与 `ActionEntries` / `PDFContextMenuPlanner` 同构：判定是纯数据，视图只负责把
/// 它翻译成控件。把菜单项的「长什么样、什么顺序、当前会话勾选在哪」收归一份数据，
/// 自检才能逐条核对（例如「历史会话必须最新在前」「当前会话带勾选」），
/// 而不是靠肉眼看菜单——这台机器没有视觉通道。
enum ConversationMenuItem: Identifiable, Equatable {

    /// 新建会话（永远在最顶）。
    case newConversation
    /// 分隔线。
    case divider
    /// 一条历史会话；`isActive` 表示它是当前活动会话（菜单里带勾选）。
    case conversation(id: UUID, title: String, isActive: Bool)
    /// 重命名当前会话…（分隔线之后、删除之前）。
    case renameCurrent
    /// 删除当前会话（菜单底部，破坏性动作）。
    case deleteCurrent

    var id: String {
        switch self {
        case .newConversation:  return "new"
        case .divider:          return "divider"
        case .conversation(let id, _, _): return "conv:\(id.uuidString)"
        case .renameCurrent:    return "rename"
        case .deleteCurrent:    return "delete"
        }
    }
}

/// 构造头部「会话」菜单的项（已按展示顺序排好）。
///
/// 顺序（用户定）：
/// 1. 新建会话
/// 2. 分隔线
/// 3. 历史会话（**最新在前**，当前活动项带勾选）
/// 4. 分隔线
/// 5. 重命名当前会话… / 删除当前会话
///
/// `store.conversations` 在 `ConversationStore` 里是按**创建时间升序**存的，
/// 这里反转成「最新在前」。当前活动会话（= `store.activeID`）标 `isActive` 供视图画勾选。
struct ConversationMenuPlanner {

    /// 必须 `@MainActor`：`ConversationStore` 整体是 `@MainActor`（它的 `@Published`
    /// 要驱动 SwiftUI），从 nonisolated 上下文读 `store.conversations` / `store.activeID`
    /// 会被严格并发拦下。本函数本来就只在主线程的视图/自检里被调用。
    @MainActor
    static func items(
        store: ConversationStore,
        currentDocPath: String?
    ) -> [ConversationMenuItem] {
        var items: [ConversationMenuItem] = []
        items.append(.newConversation)
        items.append(.divider)

        // 最新在前：反转创建时间升序的数组。
        for conv in store.conversations.reversed() {
            let isActive = conv.id == store.activeID
            items.append(.conversation(
                id: conv.id,
                title: conv.displayTitle,
                isActive: isActive
            ))
        }

        items.append(.divider)
        items.append(.renameCurrent)
        items.append(.deleteCurrent)

        // currentDocPath 当前仅用于未来可能的「按当前文档预筛」，本规划器不依赖它决定顺序。
        _ = currentDocPath
        return items
    }
}

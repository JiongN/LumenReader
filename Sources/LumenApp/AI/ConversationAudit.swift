import Foundation
import SwiftUI
import Combine
import LumenKit

/// 全局共享会话自检：`--conversation-report 1`（建议配合 `--capture <png>` 截图）。
///
/// 这一块逻辑全在数据与「内存 ↔ 磁盘」边界上，界面上**看不出对错**：
/// 菜单顺序错了、跨文档引用降级放错了、切会话没真正换内容、流式期间偷偷写盘——
/// 这些在截图里都不可见。所以把它们抽成纯函数（`ConversationMenuPlanner` /
/// `ConversationCitationPolicy` / `AIChatModel` 的落盘点），在这里逐条断言，且每条都可证伪：
/// 把断言里的判定反一反（例如把「最新在前」改成「最早在前」），这条自检立刻红。
@MainActor
enum ConversationAudit {

    /// 自检开关：裸写 `--conversation-report 1` 会被 `LaunchOptions.flag` 归一化，
    /// 这里只暴露语义名。
    static func run(services: AppServices) {
        guard LaunchOptions.conversationReport else { return }

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][conversation] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        let store = services.conversationStore
        let chat = services.activeChat

        // ── 1. 菜单规划器：表驱动（0/1/multi/active）──────────────────────────
        // 用一个独立 store 跑（audit 模式 supportRoot 已被重定向到临时目录，不污染真实数据）。
        let plannerStore = ConversationStore()
        // 先把已有内容删干净，从已知状态构造场景。
        //
        // 注意 `ConversationStore.delete` 的不变量：**列表永不为空**——删到最后一条时
        // 会自动补一个空会话（否则 `activeID` 变 nil，界面就失去了挂载点）。
        // 所以「清空」的结果是**恰好剩 1 条幸存会话**，而不是 0 条。
        // 下面所有条目数期望都由 `base` 推导，不写死数字——第一版这里写死了 3，
        // 于是恒差 1、两条断言假红（测试自己坏了，不是功能坏了）。
        for c in plannerStore.conversations { plannerStore.delete(id: c.id) }
        let survivors = plannerStore.conversations
        check("删空会话列表：仍保留恰好 1 条，且它就是活动项（不变量：activeID 永不为 nil）",
              survivors.count == 1 && plannerStore.activeID == survivors.first?.id)
        let base = survivors.count
        let alpha = plannerStore.createConversation(sourcePath: "A.pdf", sourceTitle: "A")
        let beta = plannerStore.createConversation(sourcePath: "B.pdf", sourceTitle: "B")
        let gamma = plannerStore.createConversation(sourcePath: "C.pdf", sourceTitle: "C")
        // gamma 最新（最后创建），应排在最前；把它设为活动项。
        plannerStore.setActive(gamma)

        func planItems(_ s: ConversationStore) -> [ConversationMenuItem] {
            ConversationMenuPlanner.items(store: s, currentDocPath: nil)
        }

        // 结构公式：1(new) + 1(divider) + N(conv) + 1(divider) + 2(rename/delete)
        let multiPlan = planItems(plannerStore)
        let convItems = multiPlan.compactMap { item -> UUID? in
            if case .conversation(let id, _, _) = item { return id }
            return nil
        }
        let dividers = multiPlan.filter { if case .divider = $0 { return true }; return false }.count
        check("菜单结构：1 新建 + 2 分隔线 + 2 管理项 + N 历史",
              multiPlan.first == .newConversation
                && multiPlan.last == .deleteCurrent
                && dividers == 2
                && multiPlan.contains(.renameCurrent)
                && multiPlan.contains(.deleteCurrent))

        // 「多」：最新在前（gamma 在最前），且恰好一个带勾选。
        check("菜单历史：最新创建的会话排在最前", convItems.first == gamma)
        check("菜单历史：只当前活动会话带勾选（恰好一个）",
              multiPlan.filter { item in
                  if case .conversation(_, _, let isActive) = item { return isActive }
                  return false
              }.count == 1)
        check("菜单历史：条目数 = 幸存 \(base) 条 + 新建 3 条", convItems.count == base + 3)

        // 「一」：删到只剩一条，这条必须带勾选且是活动项；顺序公式仍成立。
        // 「少」：删掉 alpha/beta，只剩幸存那条 + gamma；gamma 仍是活动项，顺序公式不变。
        plannerStore.delete(id: alpha)
        plannerStore.delete(id: beta)
        let singlePlan = planItems(plannerStore)
        let singleConv = singlePlan.compactMap { item -> (UUID, Bool)? in
            if case .conversation(let id, _, let isActive) = item { return (id, isActive) }
            return nil
        }
        check("菜单历史：删掉 alpha/beta 后剩 \(base + 1) 条，且 gamma 仍带勾选",
              singleConv.count == base + 1
                && singleConv.contains { $0.0 == gamma && $0.1 })

        _ = gamma

        // ── 2. 跨文档引用降级策略：四态 ──────────────────────────────────────
        let loc = DocumentLocator.pdf(page: 0, charOffset: 0)
        let sameDoc = "book.pdf"
        let otherDoc = "other.pdf"
        check("策略：引用指向当前文档 → 可跳",
              ConversationCitationPolicy.isActive(locator: loc, bubbleDocPath: sameDoc, conversationDocPath: nil, currentDocPath: sameDoc))
        check("策略：跨文档引用 → 不可跳",
              !ConversationCitationPolicy.isActive(locator: loc, bubbleDocPath: otherDoc, conversationDocPath: nil, currentDocPath: sameDoc))
        check("策略：来源未知（nil）→ 不可跳（fail safe）",
              !ConversationCitationPolicy.isActive(locator: loc, bubbleDocPath: nil, conversationDocPath: nil, currentDocPath: sameDoc))
        check("策略：当前文档未知（nil）→ 不可跳（fail safe）",
              !ConversationCitationPolicy.isActive(locator: loc, bubbleDocPath: sameDoc, conversationDocPath: nil, currentDocPath: nil))
        // 气泡来源优先：气泡指向 other、会话出身指向 same，当前是 same → 按气泡判为跨文档。
        check("策略：气泡来源优先于会话出身（精确降级）",
              !ConversationCitationPolicy.isActive(locator: loc, bubbleDocPath: otherDoc, conversationDocPath: sameDoc, currentDocPath: sameDoc))

        // ── 3. 新建会话行为：回读 ───────────────────────────────────────────
        // 注意：这里动的是**真实** services 的 store（audit 模式下落盘在临时目录）。
        let beforeCount = store.conversations.count
        let beforeActive = store.activeID
        let newID = chat.newConversation(sourcePath: "new.pdf", sourceTitle: "新书")
        check("新建会话：会话数 +1", store.conversations.count == beforeCount + 1)
        check("新建会话：新会话成为活动项", store.activeID == newID && newID != beforeActive)
        // 用 `map{}.isEmpty == true` 而不是 `?? []`：后者在 activeConversation 为 nil 时
        // 也会得到「空列表」而误判通过——这条断言要连「会话不存在」一起抓。
        check("新建会话：活动会话内容为空",
              store.activeConversation.map { $0.bubbles.isEmpty } == true)
        check("新建会话：记下了来源文档（跨文档降级可用）",
              store.activeConversation?.sourceDocPath == "new.pdf")

        // ── 3.5. 默认标题：文档标题 + 同书多会话序号 ────────────────────────
        // 用一份**独有的文档路径**，免得与上面/下面其它场景的会话互相干扰。
        let titleDoc = "TITLE-ONLY.pdf"
        let titleName = "教育的目的"
        let t1 = store.createConversation(sourcePath: titleDoc, sourceTitle: titleName)
        let t2 = store.createConversation(sourcePath: titleDoc, sourceTitle: titleName)
        let t3 = store.createConversation(sourcePath: titleDoc, sourceTitle: titleName)
        func titleOf(_ id: UUID) -> String { store.conversation(id: id)?.title ?? "<无这条会话>" }

        check("标题：同一文档第 1 个会话 = 纯书名（不加序号）", titleOf(t1) == titleName,
              "得到「\(titleOf(t1))」")
        check("标题：同一文档第 2 个会话 = 「2. 书名」", titleOf(t2) == "2. \(titleName)",
              "得到「\(titleOf(t2))」")
        check("标题：同一文档第 3 个会话 = 「3. 书名」", titleOf(t3) == "3. \(titleName)",
              "得到「\(titleOf(t3))」")

        // 不同文档互不干扰：另一本书的第 1 个会话仍是不带序号的纯书名。
        let otherFirst = store.createConversation(sourcePath: "OTHER-BOOK.pdf", sourceTitle: "另一本书")
        check("标题：不同文档互不干扰（另一本书的第 1 个仍是纯书名）",
              titleOf(otherFirst) == "另一本书", "得到「\(titleOf(otherFirst))」")

        // 删掉中间那条再新建：序号必须**推进**，不能退回去与活着的 3 号撞号。
        store.delete(id: t2)
        let t4 = store.createConversation(sourcePath: titleDoc, sourceTitle: titleName)
        check("标题：删掉中间一条后新建 → 序号推进到 4（不与活着的 3 号撞号）",
              titleOf(t4) == "4. \(titleName)", "得到「\(titleOf(t4))」")

        // 手动重命名：customTitle 胜出，且不改动其它会话的序号。
        store.rename(id: t1, "我的精读")
        check("标题：手动重命名后 customTitle 胜出",
              store.conversation(id: t1)?.displayTitle == "我的精读",
              "得到「\(store.conversation(id: t1)?.displayTitle ?? "<无>")」")
        check("标题：重命名不影响其它会话的序号",
              titleOf(t3) == "3. \(titleName)" && titleOf(t4) == "4. \(titleName)")

        // 书名本身以「数字.」开头时不能被误判成序号——解析按 `base` 后缀精确比对。
        // 这条是「不加字段、只靠字符串解析」这个取舍的护栏：没有它，这个方案就是不可信的。
        let numDoc = "1. 引言.pdf"
        let numName = "1. 引言"
        let n1 = store.createConversation(sourcePath: numDoc, sourceTitle: numName)
        let n2 = store.createConversation(sourcePath: numDoc, sourceTitle: numName)
        check("标题：书名以「数字.」开头时不误判（第 1 个仍是纯书名）",
              titleOf(n1) == numName, "得到「\(titleOf(n1))」")
        check("标题：同上，第 2 个是「2. 1. 引言」而不是「3. …」",
              titleOf(n2) == "2. \(numName)", "得到「\(titleOf(n2))」")

        // 没有文档上下文 / 迁移会话（sourceDocTitle 为 nil）：回退时间戳，且不崩。
        let noDoc = store.createConversation(sourcePath: nil, sourceTitle: nil)
        check("标题：无文档上下文时回退到时间戳兜底",
              ConversationStore.isFallbackTitle(titleOf(noDoc)), "得到「\(titleOf(noDoc))」")
        let legacy = store.createConversation(sourcePath: "LEGACY.pdf", sourceTitle: nil)
        check("标题：sourceDocTitle 为 nil（迁移会话）时回退时间戳，不参与序号",
              ConversationStore.isFallbackTitle(titleOf(legacy)), "得到「\(titleOf(legacy))」")

        // 落盘往返：重新解码 conversations.json，断言标题真的写进去了（不是只在内存里对）。
        store.persist()
        if let data = try? Data(contentsOf: AppPaths.conversationHistoryFile),
           let file = try? JSONDecoder().decode(ConversationFileProbe.self, from: data) {
            let titles = Set(file.conversations.map(\.title))
            check("标题：落盘往返后仍能读到带序号的标题",
                  titles.contains("3. \(titleName)") && titles.contains("4. \(titleName)"))
        } else {
            check("标题：落盘往返后仍能读到带序号的标题", false, "读不到或解不开 conversations.json")
        }

        // 出身文档第一次确定时，把「时间戳兜底」的标题升级成文档标题（含序号）。
        // 场景：在主页标签先开会话，之后打开某本书提问——标题要跟着变成那本书的名字。
        let lateDoc = "LATE-BIND.pdf"
        let late = store.createConversation(sourcePath: nil, sourceTitle: nil)
        check("标题：出身文档确定前是时间戳兜底", ConversationStore.isFallbackTitle(titleOf(late)))
        store.setSourceDocPath(id: late, path: lateDoc, title: "晚绑定的书")
        check("标题：出身文档确定后升级为书名（第 1 个，不加序号）",
              titleOf(late) == "晚绑定的书", "得到「\(titleOf(late))」")
        let late2 = store.createConversation(sourcePath: lateDoc, sourceTitle: "晚绑定的书")
        check("标题：同一本书再来一个 → 「2. 书名」",
              titleOf(late2) == "2. 晚绑定的书", "得到「\(titleOf(late2))」")

        // ── 4. 切换会话行为：哨兵字符串回读 ──────────────────────────────────
        let idA = store.createConversation(sourcePath: "A.pdf", sourceTitle: "A")
        let idB = store.createConversation(sourcePath: "B.pdf", sourceTitle: "B")
        let bubbleA = AIChatModel.Bubble(role: .user, text: "SENTINEL-ALPHA-9F3C")
        let bubbleB = AIChatModel.Bubble(role: .user, text: "SENTINEL-BRAVO-7D2E")
        store.replaceContent(id: idA, bubbles: [bubbleA], history: [])
        store.replaceContent(id: idB, bubbles: [bubbleB], history: [])
        chat.switchTo(idA)
        check("切换会话：装回 A 的哨兵内容",
              chat.bubbles.contains { $0.text == "SENTINEL-ALPHA-9F3C" })
        chat.switchTo(idB)
        check("切换会话：装回 B 的哨兵内容",
              chat.bubbles.contains { $0.text == "SENTINEL-BRAVO-7D2E" })
        check("切换会话：装回 B 后清掉 A 的内容（不串台）",
              !chat.bubbles.contains { $0.text == "SENTINEL-ALPHA-9F3C" })

        // ── 5. 磁盘往返 + 容错解码 ─────────────────────────────────────────
        var roundTrip = Conversation()
        roundTrip.sourceDocPath = "SRC-PATH"
        var rtBubble = AIChatModel.Bubble(role: .user, text: "hello")
        rtBubble.sourceDocPath = "BUB-SRC"
        roundTrip.bubbles = [rtBubble]
        do {
            let encoded = try JSONEncoder().encode(roundTrip)
            let decoded = try JSONDecoder().decode(Conversation.self, from: encoded)
            check("磁盘往返：会话 sourceDocPath 保留", decoded.sourceDocPath == "SRC-PATH")
            check("磁盘往返：气泡 sourceDocPath 保留", decoded.bubbles.first?.sourceDocPath == "BUB-SRC")
        } catch {
            check("磁盘往返：编码/解码不抛错", false, "\(error)")
        }
        // 容错：只给 id，其余键全缺 —— 必须不崩、用默认值（见 README 硬约束第 2 条）。
        let partial = "{\"id\":\"00000000-0000-0000-0000-0000000000AA\"}".data(using: .utf8)!
        do {
            let partialDecoded = try JSONDecoder().decode(Conversation.self, from: partial)
            check("容错解码：缺字段不崩、用默认值",
                  partialDecoded.title == "" && partialDecoded.bubbles.isEmpty
                    && partialDecoded.sourceDocPath == nil)
        } catch {
            check("容错解码：缺字段不崩、用默认值", false, "\(error)")
        }

        // ── 6. 流式不变量：流式期间不写盘，结束才落盘 ────────────────────────
        store.persist() // 确保基准文件存在，mtime 才有可比的起点。
        let fileURL = AppPaths.conversationHistoryFile
        let m1 = mtimeOf(fileURL) ?? .distantPast
        chat.beginFakeStream()
        for _ in 0..<5 { chat.appendFakeDelta("增量文本") }
        let m2 = mtimeOf(fileURL) ?? .distantPast
        check("流式期间不写盘（conversations.json mtime 不变）", m1 == m2)
        chat.endFakeStream()
        let m3 = mtimeOf(fileURL) ?? .distantPast
        check("流式结束后才落盘（mtime 推进）", m3 > m1)

        NSLog("%@", "[Lumen][conversation] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    /// 取文件 mtime（不存在返回 nil）。
    private static func mtimeOf(_ url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
}

extension LaunchOptions {
    /// 全局共享会话自检开关。
    static var conversationReport: Bool { flag("--conversation-report") }
}

/// 只用来把 `conversations.json` 读回来的壳（「标题落盘往返」断言用）。
/// 真正的落盘结构 `ConversationFile` 在 `ConversationStore.swift` 里是 private，
/// 自检从外面看不到；这里只需要 `conversations` 一个键。
private struct ConversationFileProbe: Decodable {
    var conversations: [Conversation] = []
}

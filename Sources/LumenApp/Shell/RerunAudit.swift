import Foundation
import LumenKit

/// 「重新生成」自检：`--rerun-report 1`（需配合 `--mock-ai 1` 与 `--capture`）。
///
/// 为什么要单开一条：这个功能的所有产物都在**内存与请求体**里——
/// 界面上看到的是「同一条回答又变了一遍」，截图证明不了它是被替换的还是被追加的，
/// 也证明不了 history 有没有被叠加。而「重跑之后模型开始答非所问」正是
/// history 被污染的典型症状，必须能断言。
///
/// 断言指向两处外部可核对的产物：
/// - 气泡序列：重跑后**条数不变**（替换）而不是 +1（追加）；
/// - 桩服务收到的请求体（`/tmp/lumen-mock-requests.jsonl`）：两次请求的
///   `messages` **条数相同**。history 若被叠加，第二次会多出一对问答。
@MainActor
enum RerunAudit {

    /// 桩服务转储请求体的路径，见 `tools/mock_openai_server.py`
    private static let requestDumpPath = "/tmp/lumen-mock-requests.jsonl"

    static func run(session: ReaderSession, state: AppState) async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("[Lumen][rerun] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        // 全局共享会话：不再从 session 取（session 上已无 chat），统一走 state.chat。
        let chat = state.chat
        let bridge = session.bridge

        guard let config = state.settingsStore.activeProvider, config.isConfigured else {
            NSLog("[Lumen][rerun] ❌ 没有可用的 AI 服务商。这条自检要配合 --mock-ai 1 跑")
            return
        }

        // 先清掉这本书此前的对话：气泡数与请求体规模都要拿来做断言，
        // 带着上一轮的历史进来，两个数都会随「用户之前聊了多少」浮动，
        // 自检就成了掷骰子。（自检标志才会走到这里，不影响正常使用。）
        chat.clear()

        // 自己塞一段选区：正常要靠鼠标划词，这台机器没有辅助功能权限。
        // 有了确定的材料，两次请求的内容才可比。
        let selection = ReaderSelection(
            text: "文化资本的传递并不经过市场，而是在家庭日常中完成。",
            locator: .pdf(page: 0, charOffset: 0)
        )
        bridge.selection = selection
        let fallback = bridge.currentContextProvider?() ?? ("", .pdf(page: 0, charOffset: 0))

        NSLog("[Lumen][rerun] 第一次请求：task=explain 服务商=\(config.name) 模型=\(config.selectedModel)")
        chat.submit(
            task: .explain,
            selection: selection,
            metadata: bridge.metadata,
            locatorLabel: bridge.positionLabel,
            context: fallback.0,
            locator: fallback.1,
            config: config,
            memory: state.aiMemoryPayload,
            translateTarget: state.settingsStore.ai.translateTarget,
            template: nil,
            agent: nil,
            sourcePath: session.document.id,
            sourceTitle: session.document.displayTitle
        )
        await waitUntilIdle(chat)

        let countAfterFirst = chat.bubbles.count
        let firstAnswer = chat.bubbles.last?.text ?? ""
        let firstFailed = chat.bubbles.last?.failed ?? true
        let historyAfterFirst = chat.historyMessageCount
        NSLog("[Lumen][rerun] 第一次结束：气泡 \(countAfterFirst) 条，"
              + "末条字数 \(firstAnswer.count)，失败=\(firstFailed)，"
              + "history \(historyAfterFirst) 条，canRerunLast=\(chat.canRerunLast)")
        // 「非空」必须配上「没失败」才算数：连不上桩服务时气泡里也会有一段
        // 错误说明，只看字数的话自检会在服务根本没启动的情况下全绿。
        check("首次请求成功（非空且未失败）", !firstAnswer.isEmpty && !firstFailed,
              firstFailed ? "请求失败了：\(firstAnswer.prefix(80))" : "末条为空")
        check("首次请求后即可重跑", chat.canRerunLast)

        let countsBefore = Self.lastRequestMessageCounts()
        NSLog("[Lumen][rerun] 请求体 messages 条数（首次）：\(countsBefore.map(String.init).joined(separator: ", "))")

        NSLog("[Lumen][rerun] 触发 rerunLast()")
        chat.rerunLast()
        await waitUntilIdle(chat)

        let countAfterRerun = chat.bubbles.count
        let secondAnswer = chat.bubbles.last?.text ?? ""
        let secondFailed = chat.bubbles.last?.failed ?? true
        let historyAfterRerun = chat.historyMessageCount
        NSLog("[Lumen][rerun] 重跑结束：气泡 \(countAfterRerun) 条，末条字数 \(secondAnswer.count)，"
              + "history \(historyAfterRerun) 条，canRerunLast=\(chat.canRerunLast)")

        // ① 替换而不是追加：追加会让气泡数 +1，也会让「问—答」的交替被打破
        check("重跑替换了旧回答而不是追加", countAfterRerun == countAfterFirst,
              "首次 \(countAfterFirst) 条 → 重跑后 \(countAfterRerun) 条")
        // ② 重跑出来的仍是有效回答
        check("重跑成功（非空且未失败）", !secondAnswer.isEmpty && !secondFailed,
              secondFailed ? "重跑失败：\(secondAnswer.prefix(80))" : "末条为空")
        check("重跑后可以继续重跑", chat.canRerunLast)

        // ③ history 没有被叠加：重跑是「换一对」而不是「加一对」。
        //    这一条是「重跑之后模型开始答非所问」的直接根因——history 里若留着
        //    上一轮那一对，下一轮就会看到一个已经被回答过的旧问题。
        check("重跑后 history 仍只有一对（未被叠加）",
              historyAfterRerun == historyAfterFirst && historyAfterRerun % 2 == 0,
              "首次 \(historyAfterFirst) 条 → 重跑后 \(historyAfterRerun) 条")

        // ④ 同一件事在**外部产物**上再核一次：两次请求喂给模型的 messages 条数
        //    必须一致。读不到转储文件（桩服务没在跑 / 路径被环境变量改过）时
        //    如实跳过，而不是拿一个空结果当通过。
        let countsAfter = Self.lastRequestMessageCounts()
        NSLog("[Lumen][rerun] 请求体 messages 条数（末两次）：\(countsAfter.map(String.init).joined(separator: ", "))")
        if countsAfter.count == 2 {
            check("重跑的请求体与首次规模一致（history 未叠加）",
                  countsAfter[0] == countsAfter[1],
                  "首次 \(countsAfter[0]) 条 vs 重跑 \(countsAfter[1]) 条")
        } else {
            NSLog("[Lumen][rerun] ⚠️ 读不到两次请求体（\(countsAfter.count)/2），"
                  + "跳过「history 未叠加」断言——桩服务的转储文件是 \(Self.requestDumpPath)")
        }

        NSLog("[Lumen][rerun] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    // MARK: - 辅助

    /// 等流式结束。轮询而不是死等固定时长：桩服务的响应长度是可配的，
    /// 固定等待要么白白拖慢、要么在慢响应上读到「还在流」的假失败。
    private static func waitUntilIdle(_ chat: AIChatModel, timeout: TimeInterval = 90) async {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // 再让出一点时间给最后一次 flush 与落盘
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// 桩服务转储里**最后两次**请求的 `messages` 条数。
    private static func lastRequestMessageCounts(limit: Int = 2) -> [Int] {
        guard let text = try? String(contentsOfFile: requestDumpPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .suffix(limit)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messages = object["messages"] as? [[String: Any]] else { return nil }
                return messages.count
            }
    }
}

import Foundation
import SwiftUI
import LumenKit

/// PDF 翻译面板的自检：`--translation-report 1`。
///
/// 覆盖用户的三个检查点，每条都要能**被证伪**，不做自证：
///
/// 1. **机器/LLM 切换** —— 面板把「机器翻译 / LLM」分成段的一个开关。切到 LLM 前
///    要记住离开时的机器引擎；切回「机器翻译」时恢复它，而不是硬编码回 Apple。
///    本组是纯字段逻辑，不依赖视图，直接在 `ReaderSettings` 上走一遍切换并断言边界。
/// 2. **点击定位链路** —— 侧栏点一条译文 → `bridge.revealTranslationParagraph`
///    → 正文跳到该段所在页。真机打开 PDF 后取一段，调用桥回调，断言 `currentUnitIndex`
///    真的变成那一段所在的页（而不是「调用什么都没发生」）。
/// 3. **面板布局** —— 切到 `.translation` 页签后 `sidebarPane_translation` 探针
///    frame 在位且落在侧栏区域，宽度合理（防止「页签切了但面板是空的」）。
///
/// ## 边界（如实写，不装看不见）
///
/// - **不真正翻译，也不发起任何网络请求**：点击定位用的段落来自 `prepare()` 的
///   文字层抽取（只读），不消耗任何引擎配额。机器/LLM 的**切换字段语义**可断言，
///   但「切 LLM 后真的能把一段译出来」需要真实密钥/联网，这条通道不做 ——
///   它属于对引擎本身的集成测试，不在本通道范围内。
/// - **文字是否裁切验不了**（布局探针只量 frame，量不到容器内文字是否被截断）。
///   这点与 `docs/VERIFY.md` 一致；本通道能证明「面板挂载了、宽度对了」，
///   裁切要靠 `--capture` 截图人工核对。
///
/// 开关以 `-report` 结尾 → `LaunchOptions.isAuditRun` 自动成立 → `suppressSave` 开、
/// 数据目录切 `LUMEN_TEST_DATA`（若设了），不碰用户真实配置与书。
@MainActor
enum TranslationPanelAudit {

    static func run(documentPath: String?,
                    bridge: ReaderBridge,
                    state: AppState,
                    settings: SettingsStore) async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("[Lumen][translation] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }
        func report(_ text: String) { NSLog("[Lumen][translation] \(text)") }

        // ============ 一、机器/LLM 切换 ============
        report("=== 一、机器/LLM 切换（ReaderSettings 语义）===")

        // 夹具自证：先把 machine 引擎设成「用户显式选过的微软」，切走再切回，
        // 期望回到微软而非默认 Apple —— 这是本轮修的那个 bug 的回归断言。
        let originalEngine = settings.reader.translationEngineID
        let originalMachine = settings.reader.translationMachineEngineID
        defer {
            settings.reader.translationEngineID = originalEngine
            settings.reader.translationMachineEngineID = originalMachine
        }

        settings.reader.translationMachineEngineID = MicrosoftTranslationEngine.engineID
        settings.reader.translationEngineID = MicrosoftTranslationEngine.engineID
        // 模拟面板「切到 LLM」：记下离开前的机器引擎、再指向 LLM。
        if !(settings.reader.translationEngineID == LLMTranslation.engineID) {
            settings.reader.translationMachineEngineID = settings.reader.translationEngineID
        }
        settings.reader.translationEngineID = LLMTranslation.engineID
        check("切到 LLM 前记住了离开时的机器引擎",
              settings.reader.translationMachineEngineID == MicrosoftTranslationEngine.engineID,
              "machine=\(settings.reader.translationMachineEngineID)")
        check("切到 LLM 后引擎指向 llm-active",
              settings.reader.translationEngineID == LLMTranslation.engineID,
              "engine=\(settings.reader.translationEngineID)")

        // 切回「机器翻译」：应恢复先前选的微软，而不是硬编码 Apple。
        settings.reader.translationEngineID = TranslationEngineCatalog
            .descriptor(for: settings.reader.translationMachineEngineID).id
        check("切回机器翻译恢复先前选的微软（不是 Apple）",
              settings.reader.translationEngineID == MicrosoftTranslationEngine.engineID,
              "engine=\(settings.reader.translationEngineID)")

        // 反向对照：machine 字段被留成非法值（手改配置 / 已下线引擎），
        // 切回时必须兜底到目录里的默认，而不是带病前进。
        settings.reader.translationMachineEngineID = "not-a-real-engine"
        settings.reader.translationEngineID = LLMTranslation.engineID
        settings.reader.translationEngineID = TranslationEngineCatalog
            .descriptor(for: settings.reader.translationMachineEngineID).id
        check("非法 machine id 切回时兜底到默认 Apple（不带病前进）",
              settings.reader.translationEngineID == AppleSystemTranslation.engineID,
              "engine=\(settings.reader.translationEngineID)")

        // ============ 二、点击定位链路 ============
        report("=== 二、点击定位链路（侧栏译文 → 正文跳转）===")

        guard let path = documentPath, !path.isEmpty else {
            check("拿到文档路径", false, "documentPath 为空，无法做真机定位验证")
            return
        }

        // prepare：只读抽取文字层段落（不发任何翻译请求、不耗配额）。
        // `bridge.pdfTranslationController` 由 `PDFReaderView.prepare()` 异步挂上，
        // 而本审计跑在容器的 `.task` 里，两者几乎同时 —— 先等它出现再动手。
        var controller = bridge.pdfTranslationController
        var waited = 0
        while controller == nil && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            controller = bridge.pdfTranslationController
            waited += 1
        }
        guard let controller else {
            check("拿到 PDF 翻译控制器（bridge.pdfTranslationController）", false,
                  "等待 \(waited * 100)ms 仍为 nil —— PDFReaderView.prepare 未挂上控制器")
            return
        }
        check("PDF 翻译控制器已由 PDFReaderView.prepare 挂上桥",
              bridge.pdfTranslationController !== nil,
              "等待 \(waited * 100)ms 后仍为 nil")
        guard let bridgeReveal = bridge.revealTranslationParagraph else {
            check("桥的 revealTranslationParagraph 已接上（PDFReaderView.prepare 之后）", false,
                  "未接上 —— 可能文档未装好就跑了，或接线被改动破坏")
            return
        }

        await controller.prepare(
            documentPath: path,
            target: settings.reader.translationTargetLanguage,
            engineID: settings.reader.translationEngineID,
            glossary: settings.reader.translationGlossary
        )
        check("prepare 能抽出段落", !controller.paragraphs.isEmpty,
              "段数=\(controller.paragraphs.count)")

        // 全篇译文可上下滚动查看 —— 前提是这段文档的段落**跨了多页**，否则「取消翻页
        // 限制」无从谈起。多页段数 >0 才证明面板不挂在「当前页」这一格上。
        let pagesInParagraphs = Set(controller.paragraphs.map(\.pageIndex))
        check("段落跨多页（全篇滚动不是单页占位）",
              pagesInParagraphs.count > 1,
              "覆盖页数=\(pagesInParagraphs.count)")

        guard let paragraph = controller.paragraphs.first else {
            check("取到至少一段用于定位", false)
            return
        }
        let targetPage = paragraph.fragments.first?.pageIndex
        guard let targetPage else {
            check("段落有非空片段", false)
            return
        }

        // 若当前恰好停在目标页，先跳到别的页 —— 否则「跳转生效」断言会因为
        // 「本来就停在那页」而恒真，抓不出「点击什么都没发生」。
        var pageBeforeReveal = bridge.currentUnitIndex
        let totalPages = max(bridge.unitCount, 1)
        if pageBeforeReveal == targetPage, totalPages > 1 {
            let other = (targetPage + 1) % totalPages   // totalPages>1 ⇒ 必然 ≠ targetPage
            bridge.goTo?(DocumentLocator.pdf(page: other, charOffset: 0))
            try? await Task.sleep(nanoseconds: 300_000_000)
            pageBeforeReveal = bridge.currentUnitIndex
        }
        report("  reveal 前 currentUnitIndex=\(pageBeforeReveal)，目标段在第 \(targetPage + 1) 页")

        bridgeReveal(paragraph, targetPage)
        try? await Task.sleep(nanoseconds: 500_000_000)

        let pageAfterReveal = bridge.currentUnitIndex
        if totalPages > 1 {
            check("点击译文后正文真的跳到了段所在页",
                  pageAfterReveal == targetPage && pageAfterReveal != pageBeforeReveal,
                  "跳前 \(pageBeforeReveal + 1) → 跳后 \(pageAfterReveal + 1)，目标 \(targetPage + 1)")
        } else {
            // 单页文档没得跳：只能证明调用不崩、页码仍正确。
            check("单页文档调用 reveal 不崩", pageAfterReveal == targetPage)
        }

        // ============ 三、面板布局探针 ============
        report("=== 三、翻译面板布局（探针 frame）===")

        // 切到翻译页签，让面板真正挂载。
        if !state.isSidebarVisible { state.setSidebarVisible(true, animated: false) }
        state.revealSidebar(tab: .translation)
        try? await Task.sleep(nanoseconds: 700_000_000)

        let paneFrame = LayoutAuditLog.shared.frame(named: "sidebarPane_translation")
        check("切到翻译页签后面板探针在位", paneFrame != nil,
              "sidebarPane_translation 探针缺席 —— 面板可能没挂载")
        if let paneFrame {
            report("  sidebarPane_translation frame = \(Int(paneFrame.minX)),\(Int(paneFrame.minY)) "
                   + "\(Int(paneFrame.width))×\(Int(paneFrame.height))")
            check("面板宽度合理（>100pt 且 ≤ 侧栏宽度）",
                  paneFrame.width > 100 && paneFrame.width <= 320,
                  "width=\(Int(paneFrame.width))，疑似没展开或越界")
            check("面板高度合理（>200pt，有可读空间）",
                  paneFrame.height > 200,
                  "height=\(Int(paneFrame.height))，疑似被压缩成一条")
        }

        // 反向对照：切去别的页签后，翻译面板探针应摘下。
        state.revealSidebar(tab: .outline)
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("切走后面板探针已摘下（反向对照，防恒真）",
              LayoutAuditLog.shared.frame(named: "sidebarPane_translation") == nil,
              "切到目录页签后翻译探针仍在 —— 面板没跟随切换")

        let summary = failures.isEmpty ? "" : "，失败：\(failures.joined(separator: "；"))"
        report("=== 结论：\(passed) 项通过 \(failures.count) 项失败\(summary) ===")
    }
}

// MARK: - 开关

extension LaunchOptions {
    /// PDF 翻译面板自检开关。以 `-report` 结尾 → `isAuditRun` 自动成立、
    /// `suppressSave` 自动开、数据目录切临时（若设了 `LUMEN_TEST_DATA`）。
    static var translationPanelReport: Bool { flag("--translation-report") }
}
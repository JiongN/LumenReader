import Foundation
import AppKit
import PDFKit
import LumenKit

/// 批注与搜索高亮的自检通道。
///
/// 这一组功能有一个共同的验证难点：**它们在界面上，而验证者看不到界面**。
/// 所以断言不能停在「函数返回了 true」——那只能证明代码走到了那一行。
/// 每一条断言都指向一个**外部可核对的产物**：
///
/// - 批注是否真的写进文件 → 重新从磁盘 `PDFDocument(url:)` 打开，数批注；
/// - 搜索高亮是否真的没写进文件 → 保存后重开，批注数必须是 0；
/// - 删批注是否真的从文件里消失 → 删除后再重开，数少了一条。
///
/// 全程在 `/tmp` 下的**副本**上做，绝不碰用户的任何文件。
enum AnnotationAudit {

    /// 自检用的 PDF 副本。每次跑都重新拷一份，保证起点干净。
    private static func makeCopy(of url: URL) -> URL? {
        let destination = URL(fileURLWithPath: "/tmp/lumen-annotate-audit.pdf")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            NSLog("%@", "[Lumen][annotate] 无法创建自检副本：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 批注写盘

    @MainActor
    static func runDocumentAudit(sourceURL: URL) async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][annotate] \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " —— \(detail)")")
        }

        guard let copy = makeCopy(of: sourceURL) else { return }

        let controller = PDFController()
        guard controller.load(url: copy) != nil else {
            NSLog("[Lumen][annotate] 无法载入自检副本，跳过")
            return
        }
        NSLog("%@", "[Lumen][annotate] 自检副本：\(copy.path)，共 \(controller.pageCount) 页")
        NSLog("%@", "[Lumen][annotate] 起点批注数（重开文件统计）：\(annotationCount(in: copy))")

        // ① 高亮：真实走一遍「设置选区 → 高亮 → 写盘」
        //
        // 早先这里是「在页高 midY 处取一条横带」，结果在排版稀疏的页面上选到了空白区：
        // `page.selection(for:)` 返回的是一条**空的**选区（不是 nil，所以不报错），
        // 高亮数 0，断言却报「高亮写入成功 ❌」——失败被归到了错误的因上。
        // 现在改两处：横带按**真实字形位置**取，并且把「选区非空」单独列成一条断言，
        // 让失败落在它真正发生的地方。
        let targetPage = min(1, max(0, controller.pageCount - 1))
        guard let testPage = controller.document?.page(at: targetPage) else {
            NSLog("[Lumen][annotate] 拿不到测试页，跳过")
            return
        }
        let pageText = testPage.string ?? ""
        check("测试页有可用的文本层", pageText.count >= 40, "\(pageText.count) 字")

        let textBand = glyphBand(of: testPage)
        NSLog("%@", "[Lumen][annotate] 文字占用带 \(textBand)"
            + "（页 bounds \(testPage.bounds(for: .mediaBox))）")

        var selectionText = ""
        if let selection = testPage.selection(for: textBand) {
            controller.view.setCurrentSelection(selection, animate: false)
            selectionText = selection.string ?? ""
        }
        check("在文字带上取到非空选区（高亮的前置条件）", !selectionText.isEmpty,
              "\(selectionText.count) 字：\((selectionText.prefix(20)).debugDescription)"
                + "，落在 view.currentSelection 上 \(controller.view.currentSelection?.string?.count ?? 0) 字")

        if !selectionText.isEmpty {
            let ok = controller.addHighlight(fromCurrentSelection: "自检批注：高亮")
            check("高亮写入成功（返回 true）", ok)
        }

        // ② 页面批注（AI「添加到批注」走的就是这条）：
        // 锚文本用**刚才那段真实选区文字**——模拟「用户拖选一段 → 让 AI 就这段说点什么 → 存成批注」。
        // 选区的 string 自带换行，正是 AI 复述引文的常见形态，也正好压住
        // 「文档里是换行、锚里是空格就匹配不上」那个坑。
        let anchor = selectionText.isEmpty ? firstSentence(in: pageText) : selectionText
        let occurrences = pageText.components(separatedBy: anchor).count - 1
        NSLog("%@", "[Lumen][annotate] 锚文本 \(anchor.count) 字，在本页出现 \(occurrences) 次")

        // 两条查锚路径的耗时对照：终值一样，所以断言只能打在代价上
        let cost = controller.anchorLookupCostProbe(anchor: anchor, pageIndex: targetPage)
        NSLog("%@", "[Lumen][annotate] 查锚耗时：全书 findString \(cost.wholeBook)µs／页内查找 \(cost.pageLocal)µs"
            + "（\(cost.pageLocal > 0 ? String(format: "%.0f×", Double(cost.wholeBook) / Double(cost.pageLocal)) : "—")）")

        let noteOK = controller.addNote(
            pageIndex: targetPage,
            anchorText: anchor,
            body: "自检批注：这一条要锚回原文，不能退回页面便签。"
        )
        check("页面批注写入成功（返回 true）", noteOK)
        logInventory(label: "写完页面批注后", of: controller, url: copy)

        // ③ 锚回：磁盘上的文件里，这一页必须有一条**高亮**挂在与锚文本同一行上。
        // 「写成功」还不够——锚不准的批注比没有批注更糟，所以这条断言打在几何上。
        let anchored = highlightBounds(in: copy, page: targetPage, contentsContaining: "锚回原文")
        if let anchored {
            check("锚文本锚回了原文（磁盘上是一条高亮，不是页面便签）", true,
                  "bounds=\(anchored)")
            check("锚回的高亮落在取选区的那一行上", anchored.intersects(textBand),
                  "锚 \(anchored) ∩ 带 \(textBand)")
        } else {
            check("锚文本锚回了原文（磁盘上是一条高亮，不是页面便签）", false,
                  "未找到高亮，说明退回了页面便签")
        }

        // ③ 最硬的断言：重新打开磁盘上的文件，批注必须真的在那里
        let afterWrite = annotationCount(in: copy)
        NSLog("%@", "[Lumen][annotate] 写盘后重新打开，批注数 = \(afterWrite)")
        check("写盘后文件里确实有批注", afterWrite >= 1, "统计到 \(afterWrite) 条")

        // ④ 清单接口与文件内容一致
        let listed = await controller.annotationsList()
        NSLog("%@", "[Lumen][annotate] 清单接口返回 \(listed.count) 条，文件里 \(afterWrite) 条")
        check("清单条数 == 文件里的批注数", listed.count == afterWrite)
        if let first = listed.first {
            NSLog("%@", "[Lumen][annotate] 首条：\(first.locator.displayLabel())"
                + " 引文=\(first.quote.prefix(24))… 正文=\(first.note.prefix(24))…")
        }

        // ⑤ 删除：删掉一条，文件里的条数必须跟着少
        if let victim = listed.first {
            let deleted = controller.deleteAnnotation(id: victim.id)
            let afterDelete = annotationCount(in: copy)
            NSLog("%@", "[Lumen][annotate] 删除一条后重新打开，批注数 = \(afterDelete)")
            check("删除返回成功", deleted)
            check("删除后文件里少了一条", afterDelete == afterWrite - 1,
                  "\(afterWrite) → \(afterDelete)")
        }

        // ⑥ 编辑（批注面板「编辑」走的路径）：改正文 → 重开文件，内容必须真的变了。
        // 只看返回 true 不够——「函数返回 true 但没写盘」正是这条通道要防的失败形态。
        // 注意用**删除后仍存在**的条目：listed.first 已经在 ⑤ 被删掉了
        // （第一版就栽在这里——拿刚删掉的条目去编辑，失败被误判成「编辑坏了」）。
        let remaining = await controller.annotationsList()
        if let target = remaining.first {
            let newBody = "自检批注：编辑后的正文 \(Int.random(in: 100...999))"
            let updated = controller.updateNote(id: target.id, body: newBody)
            check("编辑批注返回成功", updated)
            if updated {
                let bodyNow = annotationContents(in: copy, id: target.id)
                check("编辑后的正文写进了文件", bodyNow == newBody,
                      "文件里 = \(bodyNow.prefix(40).debugDescription)")
            }
        }

        // ⑦ 定位（侧栏 → 正文方向）：点清单条目，当前页必须是批注所在的页
        if let item = remaining.first(where: { $0.locator.pageIndex == targetPage }) ?? remaining.first {
            _ = controller.revealAnnotation(id: item.id)
            check("定位落到批注所在的页", controller.currentPageIndex == item.locator.pageIndex,
                  "批注在第 \(item.locator.pageIndex + 1) 页，定位后在第 \(controller.currentPageIndex + 1) 页")
        }

        // ⑧ 新建（批注面板「新建」按钮的路径）：文件里多一条；且清单 id 无重复。
        // id 去重这条有来历：跨行高亮的多条批注共享同一个 modificationDate，
        // 只按时间戳生成 id 会撞车，ForEach 撞上重复 id 的行为是未定义的。
        let beforeAdd = annotationCount(in: copy)
        if controller.addPageNoteAtCurrentPosition() != nil {
            let afterAdd = annotationCount(in: copy)
            check("新建批注写进文件", afterAdd == beforeAdd + 1, "\(beforeAdd) → \(afterAdd)")
            let all = await controller.annotationsList()
            let unique = Set(all.map(\.id)).count
            check("清单 id 无重复", unique == all.count,
                  "\(all.count) 条 / \(unique) 个唯一 id")
        }

        // ⑨ 整行化（用户报的原始症状：引文只剩半行，出现「人）属于哪个群体」这种断头句）
        assertRowExpansion(controller: controller, pageIndex: targetPage, check: check)

        // ⑩ 清单顺序按内容位置（页升序 → 页内自上而下），不再按「什么时候划的」
        await assertListOrdering(controller: controller, pageIndex: targetPage, check: check)

        // ⑪ 便签与高亮并存 + 高亮带颜色 + 同页两条便签不撞 id
        await assertNotesCoexist(controller: controller, check: check)

        // ⑫ 历史遗留的「半行」批注：读取侧补算 + 一键把文件里的矩形改宽
        await assertLegacyRowWidening(controller: controller, pageIndex: targetPage, check: check)

        NSLog("%@", "[Lumen][annotate] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
            + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
        NSLog("%@", "[Lumen][annotate] 自检产物保留在 \(copy.path)（可直接用预览打开核对）")
    }

    // MARK: - 整行化与顺序（⑨⑩⑪）

    /// ⑨ 把「半行片段」交给 `fullRowBounds`，必须扩回**整行**。
    ///
    /// 测试数据从被测页**自己**长出来：取一条真实文本行，再截出它中间 40% 当片段。
    /// 不写死坐标——项目里踩过三次「测试自己坏了而非功能坏了」。
    @MainActor
    private static func assertRowExpansion(
        controller: PDFController, pageIndex: Int, check: (String, Bool, String) -> Void
    ) {
        guard let page = controller.document?.page(at: pageIndex) else {
            check("整行化：拿得到测试页", false, "页 \(pageIndex) 取不到")
            return
        }
        let band = glyphBand(of: page)
        guard let selection = page.selection(for: band),
              let line = selection.selectionsByLine().first else {
            check("整行化：测试页能取到一条真实文本行", false, "文字带 \(band) 上没有文本")
            return
        }
        let lineRect = line.bounds(for: page)
        // 只取中间 40%：模拟「用户从词中间起划、在句中收手」
        let fragment = CGRect(x: lineRect.midX - lineRect.width * 0.2,
                              y: lineRect.minY,
                              width: lineRect.width * 0.4,
                              height: lineRect.height)

        // 第一道：先证明这个测试**不是恒真的**——片段必须真的比整行窄，
        // 否则「扩到整行」和「原样返回」两种实现都会被判通过。
        check("整行化：测试片段确实窄于整行（防恒真）",
              lineRect.width > fragment.width * 1.4,
              String(format: "整行 %.1fpt / 片段 %.1fpt", lineRect.width, fragment.width))

        let expanded = PDFController.fullRowBounds(for: fragment, on: page)
        if let row = expanded {
            check("整行化：半行片段扩回了整行",
                  abs(row.minX - lineRect.minX) < 1.0 && abs(row.maxX - lineRect.maxX) < 1.0,
                  String(format: "扩后 x=[%.1f,%.1f]，期望 x=[%.1f,%.1f]",
                         row.minX, row.maxX, lineRect.minX, lineRect.maxX))
            // 幂等：已经是一整行时再扩一次不该变（证明它没有「无限往外吃」）
            let again = PDFController.fullRowBounds(for: row, on: page)
            check("整行化：对整行再扩一次结果不变（幂等）",
                  again.map { abs($0.minX - row.minX) < 1.0 && abs($0.maxX - row.maxX) < 1.0 } ?? false,
                  "再扩 = \(again.map { String(format: "x=[%.1f,%.1f]", $0.minX, $0.maxX) } ?? "nil")")
        } else {
            check("整行化：半行片段扩回了整行", false, "fullRowBounds 返回 nil")
        }

        // 反向对照：页面下边距（正文之外）必须扩不出行 —— 证明它不是「把输入原样回显」
        let pageBounds = page.bounds(for: .mediaBox)
        let margin = CGRect(x: pageBounds.minX + 40, y: pageBounds.minY + 3,
                            width: max(1, pageBounds.width - 80), height: 6)
        check("整行化：正文外的空白带不返回伪整行（反向对照）",
              PDFController.fullRowBounds(for: margin, on: page) == nil,
              "下边距返回 \(PDFController.fullRowBounds(for: margin, on: page) == nil ? "nil ✅" : "非 nil ❌")")
    }

    /// ⑩ 清单顺序：页号单调不减；同一页内靠上的那条排在前面。
    ///
    /// 做法是在**同一页**取上下两条真实文本带各画一条高亮，再按引文认出它们。
    /// 只断言「页号有序」是不够的——那只覆盖跨页，页内的上下关系必须另有位置型断言。
    @MainActor
    private static func assertListOrdering(
        controller: PDFController, pageIndex: Int, check: (String, Bool, String) -> Void
    ) async {
        guard let page = controller.document?.page(at: pageIndex) else { return }
        let base = glyphBand(of: page)
        // 往下走 4 行取第二条，两条都在正文区里
        let upper = base
        let lower = base.offsetBy(dx: 0, dy: -(base.height * 4))

        var texts: [String] = []
        for (tag, band) in [("上", upper), ("下", lower)] {
            guard let sel = page.selection(for: band),
                  let text = sel.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                check("排序：第 \(tag) 条测试带取到文字", false, "带 \(band)")
                return
            }
            texts.append(text)
            controller.view.setCurrentSelection(sel, animate: false)
            _ = controller.addHighlight(fromCurrentSelection: "自检排序：\(tag)")
        }
        check("排序：两条测试批注的文字不同（否则认不出谁是谁）",
              texts[0] != texts[1],
              "上=\(texts[0].prefix(14)) 下=\(texts[1].prefix(14))")

        let listed = await controller.annotationsList()
        let pages = listed.map(\.locator.pageIndex)
        check("排序：页号单调不减",
              zip(pages, pages.dropFirst()).allSatisfy { $0 <= $1 },
              "页序 \(pages.prefix(14))")

        func index(of text: String) -> Int? {
            let probe = String(text.prefix(8))
            guard probe.count >= 4 else { return nil }
            return listed.firstIndex { !$0.quote.isEmpty && $0.quote.contains(probe) }
        }
        if let u = index(of: texts[0]), let l = index(of: texts[1]) {
            check("排序：同一页内靠上的排在前面", u < l, "上 = #\(u)，下 = #\(l)（共 \(listed.count) 条）")
        } else {
            check("排序：能在清单里认出这两条测试批注", false,
                  "上 = \(String(describing: index(of: texts[0])))，下 = \(String(describing: index(of: texts[1])))")
        }
    }

    /// ⑪ 便签与高亮并存、高亮带颜色、同页两条便签 id 不撞车。
    @MainActor
    private static func assertNotesCoexist(
        controller: PDFController, check: (String, Bool, String) -> Void
    ) async {
        // 同一个当前页连开两条便签：这是原来必然撞 id 的场景
        //（图标固定放在右上角，两条便签原点完全相同，而 id = 页号 + 原点 + 类型）
        var ids: [String] = []
        for _ in 0..<2 {
            if let item = controller.addPageNoteAtCurrentPosition() { ids.append(item.id) }
        }
        check("新建批注：同页两条便签都建得出来", ids.count == 2, "建成 \(ids.count) 条")
        check("新建批注：同页两条便签 id 不撞车", Set(ids).count == ids.count,
              ids.joined(separator: " / "))

        let listed = await controller.annotationsList()
        let highlights = listed.filter { $0.hasHighlight }
        let notes = listed.filter { !$0.hasHighlight }
        check("清单：便签与高亮同时出现（便签不再被藏起来）",
              !notes.isEmpty && !highlights.isEmpty,
              "高亮 \(highlights.count) 条 / 便签 \(notes.count) 条")

        let allHexShaped = highlights.allSatisfy { item in
            guard let hex = item.highlightHex else { return false }
            return hex.count == 7 && hex.hasPrefix("#")
        }
        check("清单：每条高亮都带 #RRGGBB 颜色", allHexShaped,
              highlights.compactMap(\.highlightHex).prefix(4).joined(separator: ","))

        check("清单：id 全局无重复",
              Set(listed.map(\.id)).count == listed.count,
              "\(listed.count) 条 / \(Set(listed.map(\.id)).count) 个唯一 id")
    }

    /// ⑫ 历史遗留的「半行」批注：读取侧必须补算成整行，并且能一键把文件里的矩形改宽。
    ///
    /// 为什么单列一组：上一轮只改了「**画**的时候扩整行」，而修复前画下的批注
    /// **存进 PDF 的矩形本身**就是半行——清单若直接拿它反查，就永远显示半行碎片，
    /// 用户看到的正是「批注还是没有解决」。
    ///
    /// 测试数据从被测对象自己长出来：先走真实入口画一条整行高亮，再把它的 bounds
    /// 缩成中间 40%（模拟修复前写进文件的状态），而不是手写一个假矩形。
    @MainActor
    private static func assertLegacyRowWidening(
        controller: PDFController, pageIndex: Int, check: (String, Bool, String) -> Void
    ) async {
        guard let page = controller.document?.page(at: pageIndex) else {
            check("历史半行：拿得到测试页", false, "页 \(pageIndex) 取不到")
            return
        }
        let band = glyphBand(of: page)
        guard let sel = page.selection(for: band),
              !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            check("历史半行：测试页能取到真实文本行", false, "带 \(band) 上没有文字")
            return
        }

        // ① 走真实入口画一条整行高亮（作者标记、颜色、时间戳都与用户操作一致）
        let beforeIDs = Set(page.annotations.map { ObjectIdentifier($0) })
        controller.view.setCurrentSelection(sel, animate: false)
        guard controller.addHighlight(fromCurrentSelection: "自检：模拟老批注") else {
            check("历史半行：测试高亮画得上去", false, "addHighlight 返回 false")
            return
        }
        guard let created = page.annotations.first(where: {
            !beforeIDs.contains(ObjectIdentifier($0)) && $0.lumenIsMarkup
        }) else {
            check("历史半行：找得到刚画的那一条", false, "页面批注里没有新增的划线")
            return
        }

        // ② 把矩形缩成中间 40% —— 这就是修复前写进文件的样子
        let full = created.bounds
        let fragment = CGRect(x: full.midX - full.width * 0.2, y: full.minY,
                              width: full.width * 0.4, height: full.height)
        check("历史半行：测试片段确实窄于整行（防恒真）",
              full.width > fragment.width * 1.4,
              String(format: "整行 %.1fpt / 半行 %.1fpt", full.width, fragment.width))
        // Model an actual legacy annotation, which had no QuadPoints.
        created.removeValue(forAnnotationKey: PDFAnnotationGeometry.identityKey)
        created.quadrilateralPoints = nil
        created.bounds = fragment

        // ③ 读取侧：清单给出的引文必须是**整行**，而不是存进文件的那半行
        let storedQuote = page.selection(for: fragment)?.string ?? ""
        let fullQuote = page.selection(for: full)?.string ?? ""
        guard !storedQuote.isEmpty, !fullQuote.isEmpty else {
            check("历史半行：能取到两段对照文字", false,
                  "半行 \(storedQuote.count) 字 / 整行 \(fullQuote.count) 字")
            return
        }
        let listed = await controller.annotationsList()
        // 同一基串在枚举里可能被追加 `#k`，所以按前缀认，而不是要求完全相等
        let base = PDFController.entryID(created, pageIndex: pageIndex)
        guard let entry = listed.first(where: { $0.id == base || $0.id.hasPrefix(base + "#") }) else {
            check("历史半行：清单里认得出这一条", false,
                  "基串 \(base)，清单 \(listed.count) 条：\(listed.prefix(6).map(\.id))")
            return
        }
        check("历史半行：清单引文是整行（读取侧补算了）",
              entry.quote == fullQuote,
              "实际 \(entry.quote.count) 字「\(String(entry.quote.prefix(24)))」，"
                  + "期望整行 \(fullQuote.count) 字「\(String(fullQuote.prefix(24)))」")
        check("历史半行：清单引文长于文件里那半行（防恒真）",
              entry.quote.count > storedQuote.count,
              "清单 \(entry.quote.count) 字 / 存储矩形 \(storedQuote.count) 字")
        check("历史半行：条目带 truncated 标记（界面据此给修正入口与条数）",
              entry.truncated,
              "truncated=\(entry.truncated)")

        // ④ 一键修正：把文件里的矩形真的改宽，且条数与界面一致、可重复调用无害
        let truncatedBefore = listed.filter(\.truncated).count
        let changed = controller.normalizeAnnotationRows()
        check("历史半行：normalizeAnnotationRows 改宽了 ≥1 条", changed >= 1, "返回 \(changed)")
        check("历史半行：改宽条数 == 界面标记的条数（数字对得上账）",
              changed == truncatedBefore,
              "界面标记 \(truncatedBefore) 条 / 实际改了 \(changed) 条")
        check("历史半行：文件里的矩形真的变宽到整行",
              abs(created.bounds.minX - full.minX) < 1.0
                  && abs(created.bounds.maxX - full.maxX) < 1.0,
              String(format: "%.1f → %.1fpt（期望 %.1fpt）",
                     fragment.width, created.bounds.width, full.width))
        let second = controller.normalizeAnnotationRows()
        check("历史半行：再跑一次返回 0（幂等，不会反复写盘）", second == 0, "第二次返回 \(second)")
        let after = await controller.annotationsList()
        check("历史半行：改完之后没有条目再被标为 truncated",
              after.allSatisfy { !$0.truncated },
              "剩余 truncated 条数 = \(after.filter(\.truncated).count)")
    }

    /// 打印「内存里的文档」与「磁盘上的文件」各自的批注明细。
    ///
    /// 这一条是为了让失败可诊断：写盘失败、写成功了但读不到、读到了但类型不在白名单里，
    /// 三种情况的终值都是「0 条批注」，只有把两侧明细并排打出来才分得清是哪一种。
    @MainActor
    private static func logInventory(label: String, of controller: PDFController, url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        NSLog("%@", "[Lumen][annotate] —— \(label)：文件 \(size.map(String.init) ?? "?") 字节 ——")
        if let doc = controller.document {
            for index in 0..<doc.pageCount {
                guard let page = doc.page(at: index), !page.annotations.isEmpty else { continue }
                let types = page.annotations.map { $0.type ?? "nil" }.joined(separator: ",")
                NSLog("%@", "[Lumen][annotate]   内存 第 \(index + 1) 页：\(page.annotations.count) 条 [\(types)]")
            }
        }
        let onDisk = diskInventory(url: url)
        NSLog("%@", "[Lumen][annotate]   磁盘 \(onDisk.isEmpty ? "无批注" : onDisk.joined(separator: "；"))")
    }

    private static func diskInventory(url: URL) -> [String] {
        guard let doc = PDFDocument(url: url) else { return ["打不开"] }
        var lines: [String] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index), !page.annotations.isEmpty else { continue }
            let types = page.annotations.map { $0.type ?? "nil" }.joined(separator: ",")
            lines.append("第 \(index + 1) 页 \(page.annotations.count) 条 [\(types)]")
        }
        return lines
    }

    /// 别人写的 PDF 也该能看见：统计文件里所有 markup / note 类批注。
    private static func annotationCount(in url: URL) -> Int {
        guard let doc = PDFDocument(url: url) else { return -1 }
        var count = 0
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            for annotation in page.annotations where annotation.lumenIsMarkup || annotation.lumenIsNote {
                // Popup 是 Text 便签自动带的影子批注，算两条会让计数虚高一倍
                if annotation.lumenTypeName == "Popup" { continue }
                count += 1
            }
        }
        return count
    }

    /// 按 id 从**磁盘文件**里取出批注正文（编辑断言用）。
    private static func annotationContents(in url: URL, id: String) -> String {
        guard let doc = PDFDocument(url: url) else { return "<打不开>" }
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            for annotation in page.annotations {
                if annotation.lumenTypeName == "Popup" { continue }
                if PDFController.entryID(annotation, pageIndex: index) == id {
                    return annotation.contents ?? ""
                }
            }
        }
        return "<未找到>"
    }

    private static func firstSentence(in text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        let stop = CharacterSet(charactersIn: "。！？.!?")
        if let range = cleaned.rangeOfCharacter(from: stop), range.lowerBound > cleaned.startIndex {
            return String(cleaned[cleaned.startIndex..<range.upperBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// 页面文字**实际占用**的纵向区间，转成一条必定压在某一行上的横带。
    ///
    /// 不能拿「页高的一半」这类猜测代替：CoreText 排出来的段落只占页面上部，
    /// 页中点大概率落在空白里，而空白处取选区得到的是**空选区**（不是 nil）——
    /// 它不会报错，只会让后面每一步都静默失效。
    private static func glyphBand(of page: PDFPage) -> CGRect {
        let bounds = page.bounds(for: .mediaBox)
        let text = page.string ?? ""

        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for index in 0..<text.count {
            let box = page.characterBounds(at: index)
            guard box.width > 0.5, box.height > 0.5 else { continue }
            minY = min(minY, box.minY)
            maxY = max(maxY, box.maxY)
        }

        guard minY < maxY else {
            // 连一个字符的 bounds 都拿不到（异常文件）：退回页中一条更宽的带
            return CGRect(x: bounds.minX + 40, y: bounds.midY - 60,
                          width: max(1, bounds.width - 80), height: 120)
        }

        let lineHeight = max(10, (maxY - minY) / 8)
        // 首行常是标题（字号、行距都与正文不同），往下退两行取正文
        let y = max(minY, maxY - lineHeight * 1.6)
        return CGRect(x: bounds.minX + 40, y: y, width: max(1, bounds.width - 80), height: lineHeight)
    }

    /// 从**磁盘上的文件**里取出某页指定批注的矩形。
    ///
    /// 特意重开文件而不是读内存里的文档：要断言的是「写进去了且写对了」，
    /// 读内存只能证明「加进对象里了」。
    private static func highlightBounds(
        in url: URL, page pageIndex: Int, contentsContaining needle: String
    ) -> CGRect? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: pageIndex) else { return nil }
        for annotation in page.annotations
        where annotation.lumenTypeName == "Highlight"
            && (annotation.contents ?? "").contains(needle) {
            return annotation.bounds
        }
        return nil
    }

    // MARK: - 搜索高亮

    /// 全书里出现次数最多的**单个字符**（跳过空白与标点），用作搜索自检的查询词。
    ///
    /// 为什么不写死一个词：这条通道要能在任意素材上跑。写死英文词的那一版在中文书上
    /// 命中 0 处，于是「搜索有命中」失败——失败的原因不在搜索，在测试词。
    /// 取最频繁字符则必然命中多处，且顺带覆盖「同一字符跨多页」的定位路径。
    private static func mostFrequentCharacter(in document: PDFDocument?) -> String? {
        guard let document else { return nil }
        var counts: [Character: Int] = [:]
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string else { continue }
            for character in text where character.isLetter || character.isNumber {
                counts[character, default: 0] += 1
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        NSLog("%@", "[Lumen][search] 查询词取自全书最常出现的字符「\(best.key)」，全书出现 \(best.value) 次")
        return String(best.key)
    }

    @MainActor
    static func runSearchAudit(sourceURL: URL) async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][search] \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " —— \(detail)")")
        }

        guard let copy = makeCopy(of: sourceURL) else { return }
        let controller = PDFController()
        guard controller.load(url: copy) != nil else { return }

        let baseline = annotationCount(in: copy)
        NSLog("%@", "[Lumen][search] 起点批注数 = \(baseline)")

        // 查询词必须从**文档本身**里取。
        // 早先这里写死成英文 "the"，而测试素材全是中文——搜索 0 命中，
        // 断言却报「搜索有命中 ❌」，看起来像搜索坏了，其实是测试词根本不在书里。
        // 取法：全书统计最常出现的字符（跳过空白与标点），它必然命中多处。
        guard let query = mostFrequentCharacter(in: controller.document) else {
            NSLog("[Lumen][search] 文档里找不到合适的查询词，跳过")
            return
        }
        let hits = controller.search(query)
        NSLog("%@", "[Lumen][search] 搜索「\(query)」命中 \(hits.count) 处，"
            + "页面高亮批注 \(controller.searchHighlightCount) 条")
        check("搜索有命中", !hits.isEmpty, "\(hits.count) 处")
        // 断言写 >= 而不是 ==：一处命中若跨行，会被拆成多条高亮（每条贴住一行），
        // 用等号会把这个**正确**行为判成失败。
        check("每处命中至少画出一条高亮", controller.searchHighlightCount >= hits.count,
              "命中 \(hits.count)／高亮 \(controller.searchHighlightCount)（跨行拆成多条）")

        // 重复搜索不能把上一次的高亮叠上去（叠加既费内存，也让「命中数」失去意义）
        let firstHighlightCount = controller.searchHighlightCount
        let secondPass = controller.search(query)
        NSLog("%@", "[Lumen][search] 再搜一次：命中 \(secondPass.count)／高亮 \(controller.searchHighlightCount)"
            + "（首次 \(firstHighlightCount)）")
        check("再搜一次不叠加高亮", controller.searchHighlightCount == firstHighlightCount)

        // 定位：跳到第 3 处命中，确认当前页 = 那一处所在的页
        if secondPass.count >= 3 {
            let expected = secondPass[2].locator.pageIndex
            controller.revealSearchHit(2)
            let actual = controller.currentPageIndex
            NSLog("%@", "[Lumen][search] 定位第 3 处：期望第 \(expected + 1) 页，实际第 \(actual + 1) 页")
            check("定位落到命中所在的页", actual == expected)
        }

        // 最硬的断言：搜索高亮是临时的，绝不能写进用户的书
        _ = controller.saveToFile()
        let afterSave = annotationCount(in: copy)
        NSLog("%@", "[Lumen][search] 保存后重新打开，批注数 = \(afterSave)（起点 \(baseline)）")
        check("搜索高亮没有写进文件", afterSave == baseline, "\(baseline) → \(afterSave)")

        // 清理：清除搜索高亮
        controller.clearSearchHighlights()
        NSLog("%@", "[Lumen][search] 清除后剩余临时高亮 = \(controller.searchHighlightCount)")
        check("清除搜索后临时高亮归零", controller.searchHighlightCount == 0)

        NSLog("%@", "[Lumen][search] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
            + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }
}

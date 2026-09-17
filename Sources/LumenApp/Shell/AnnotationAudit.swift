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
            NSLog("[Lumen][annotate] 无法创建自检副本：\(error.localizedDescription)")
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
            NSLog("[Lumen][annotate] \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " —— \(detail)")")
        }

        guard let copy = makeCopy(of: sourceURL) else { return }

        let controller = PDFController()
        guard controller.load(url: copy) != nil else {
            NSLog("[Lumen][annotate] 无法载入自检副本，跳过")
            return
        }
        NSLog("[Lumen][annotate] 自检副本：\(copy.path)，共 \(controller.pageCount) 页")
        NSLog("[Lumen][annotate] 起点批注数（重开文件统计）：\(annotationCount(in: copy))")

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
        NSLog("[Lumen][annotate] 文字占用带 \(textBand)"
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
        NSLog("[Lumen][annotate] 锚文本 \(anchor.count) 字，在本页出现 \(occurrences) 次")

        // 两条查锚路径的耗时对照：终值一样，所以断言只能打在代价上
        let cost = controller.anchorLookupCostProbe(anchor: anchor, pageIndex: targetPage)
        NSLog("[Lumen][annotate] 查锚耗时：全书 findString \(cost.wholeBook)µs／页内查找 \(cost.pageLocal)µs"
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
        NSLog("[Lumen][annotate] 写盘后重新打开，批注数 = \(afterWrite)")
        check("写盘后文件里确实有批注", afterWrite >= 1, "统计到 \(afterWrite) 条")

        // ④ 清单接口与文件内容一致
        let listed = await controller.annotationsList()
        NSLog("[Lumen][annotate] 清单接口返回 \(listed.count) 条，文件里 \(afterWrite) 条")
        check("清单条数 == 文件里的批注数", listed.count == afterWrite)
        if let first = listed.first {
            NSLog("[Lumen][annotate] 首条：\(first.locator.displayLabel())"
                + " 引文=\(first.quote.prefix(24))… 正文=\(first.note.prefix(24))…")
        }

        // ⑤ 删除：删掉一条，文件里的条数必须跟着少
        if let victim = listed.first {
            let deleted = controller.deleteAnnotation(id: victim.id)
            let afterDelete = annotationCount(in: copy)
            NSLog("[Lumen][annotate] 删除一条后重新打开，批注数 = \(afterDelete)")
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

        NSLog("[Lumen][annotate] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
            + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
        NSLog("[Lumen][annotate] 自检产物保留在 \(copy.path)（可直接用预览打开核对）")
    }

    /// 打印「内存里的文档」与「磁盘上的文件」各自的批注明细。
    ///
    /// 这一条是为了让失败可诊断：写盘失败、写成功了但读不到、读到了但类型不在白名单里，
    /// 三种情况的终值都是「0 条批注」，只有把两侧明细并排打出来才分得清是哪一种。
    @MainActor
    private static func logInventory(label: String, of controller: PDFController, url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        NSLog("[Lumen][annotate] —— \(label)：文件 \(size.map(String.init) ?? "?") 字节 ——")
        if let doc = controller.document {
            for index in 0..<doc.pageCount {
                guard let page = doc.page(at: index), !page.annotations.isEmpty else { continue }
                let types = page.annotations.map { $0.type ?? "nil" }.joined(separator: ",")
                NSLog("[Lumen][annotate]   内存 第 \(index + 1) 页：\(page.annotations.count) 条 [\(types)]")
            }
        }
        let onDisk = diskInventory(url: url)
        NSLog("[Lumen][annotate]   磁盘 \(onDisk.isEmpty ? "无批注" : onDisk.joined(separator: "；"))")
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
        NSLog("[Lumen][search] 查询词取自全书最常出现的字符「\(best.key)」，全书出现 \(best.value) 次")
        return String(best.key)
    }

    @MainActor
    static func runSearchAudit(sourceURL: URL) async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("[Lumen][search] \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " —— \(detail)")")
        }

        guard let copy = makeCopy(of: sourceURL) else { return }
        let controller = PDFController()
        guard controller.load(url: copy) != nil else { return }

        let baseline = annotationCount(in: copy)
        NSLog("[Lumen][search] 起点批注数 = \(baseline)")

        // 查询词必须从**文档本身**里取。
        // 早先这里写死成英文 "the"，而测试素材全是中文——搜索 0 命中，
        // 断言却报「搜索有命中 ❌」，看起来像搜索坏了，其实是测试词根本不在书里。
        // 取法：全书统计最常出现的字符（跳过空白与标点），它必然命中多处。
        guard let query = mostFrequentCharacter(in: controller.document) else {
            NSLog("[Lumen][search] 文档里找不到合适的查询词，跳过")
            return
        }
        let hits = controller.search(query)
        NSLog("[Lumen][search] 搜索「\(query)」命中 \(hits.count) 处，"
            + "页面高亮批注 \(controller.searchHighlightCount) 条")
        check("搜索有命中", !hits.isEmpty, "\(hits.count) 处")
        // 断言写 >= 而不是 ==：一处命中若跨行，会被拆成多条高亮（每条贴住一行），
        // 用等号会把这个**正确**行为判成失败。
        check("每处命中至少画出一条高亮", controller.searchHighlightCount >= hits.count,
              "命中 \(hits.count)／高亮 \(controller.searchHighlightCount)（跨行拆成多条）")

        // 重复搜索不能把上一次的高亮叠上去（叠加既费内存，也让「命中数」失去意义）
        let firstHighlightCount = controller.searchHighlightCount
        let secondPass = controller.search(query)
        NSLog("[Lumen][search] 再搜一次：命中 \(secondPass.count)／高亮 \(controller.searchHighlightCount)"
            + "（首次 \(firstHighlightCount)）")
        check("再搜一次不叠加高亮", controller.searchHighlightCount == firstHighlightCount)

        // 定位：跳到第 3 处命中，确认当前页 = 那一处所在的页
        if secondPass.count >= 3 {
            let expected = secondPass[2].locator.pageIndex
            controller.revealSearchHit(2)
            let actual = controller.currentPageIndex
            NSLog("[Lumen][search] 定位第 3 处：期望第 \(expected + 1) 页，实际第 \(actual + 1) 页")
            check("定位落到命中所在的页", actual == expected)
        }

        // 最硬的断言：搜索高亮是临时的，绝不能写进用户的书
        _ = controller.saveToFile()
        let afterSave = annotationCount(in: copy)
        NSLog("[Lumen][search] 保存后重新打开，批注数 = \(afterSave)（起点 \(baseline)）")
        check("搜索高亮没有写进文件", afterSave == baseline, "\(baseline) → \(afterSave)")

        // 清理：清除搜索高亮
        controller.clearSearchHighlights()
        NSLog("[Lumen][search] 清除后剩余临时高亮 = \(controller.searchHighlightCount)")
        check("清除搜索后临时高亮归零", controller.searchHighlightCount == 0)

        NSLog("[Lumen][search] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
            + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }
}

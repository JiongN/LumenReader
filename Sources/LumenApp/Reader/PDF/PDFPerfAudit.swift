import Foundation
import AppKit
import PDFKit
import Darwin
import LumenKit

/// PDF 浏览性能自检：`--perf-report 1`。
///
/// 用户报「PDF 浏览卡顿」，而「卡」是主观描述。这个通道把「卡」拆成三条可对比的读数，
/// 且**自己就能证伪**：
///
/// 1. **翻页耗时**：连翻 N 页（默认 120，覆盖测试文档全本），逐页记时，报 p50/p95/max。
/// 2. **滚动光栅化耗时**：按真实视口尺寸把每一页都真渲染一遍——这正是滚动时
///    新页进入视口要付的那笔钱。若这里 p95 顶穿 16.7ms，滚动就会掉帧；若翻页快、
///    这里慢，瓶颈就在渲染管线而不在翻页逻辑。
/// 3. **内存**：翻页前后各取一次 `task_vm_info.phys_footprint`，报增量。另外单独量
///    「把全本缩略图都留在内存里」的代价——这是大文档「内存持续增长」的头号嫌疑。
///
/// 翻页这条读数还带**两遍对照**：第一遍带正常回调（`onPositionChange` 会发布 `@Published`、
/// 触发 SwiftUI 失效、按 5% 台阶写「最近打开」）；第二遍把 `onPositionChange` 摘成 `nil`，
/// 只留 PDFKit 自身的翻页成本。**两者之差 = 我们这一层自己的每页开销**，差值接近 0
/// 就说明瓶颈在 PDFKit 内部，不该往我们这层使劲——这是本通道的第一处证伪点。
///
/// 为什么预热：PDFKit 首次 `page.string` / `thumbnail` 要建索引、加载字体资源，
/// 实测首调分别是 19ms / 42ms。不预热的话这两笔一次性冷启动噪声会直接顶穿 p95，
/// 读数就成了「测冷启动」而不是「测稳定态」。
@MainActor
enum PDFPerfAudit {

    /// 单页翻页耗时的目标上限（ms）。16.7ms = 60Hz 一帧；超过它这一页就会掉一帧。
    static let turnP95BudgetMs: Double = 16.7

    /// 单页滚动光栅化耗时的目标上限（ms）。判据同 60Hz 一帧。
    static let frameBudgetMs: Double = 16.7

    /// 二次遍历常驻内存增量的**参考预算**（MB）。**仅用于对照打印，不作断言**。
    ///
    /// 为什么降级成信息性读数：这个跨遍增量**不可复现**——同机多次实测落在
    /// −21 / +30 / +68 / +1MB，它由 PDFKit 内部渲染缓存在两遍之间的建立与回收主导，
    /// 不在我们这层、也压不稳。对一个时好时坏的读数下断言等于抛硬币：绿了不能证明
    /// 没泄漏，红了也不能证明有泄漏——那比不打这个断言更糟（会误导）。
    /// 「会不会持续增长」这件事改由**确定性**的 ④（缓存仍驻留的张数）来把关。
    static let footprintBudgetMB: Double = 24

    static func run(controller: PDFController) async {
        let pageCount = controller.pageCount
        guard pageCount > 1 else {
            NSLog("%@", "[Lumen][perf] 文档只有 \(pageCount) 页，不足以做翻页自检，跳过")
            return
        }

        let requested = LaunchOptions.perfPageTurns
        let turns = min(requested, pageCount)
        NSLog("%@", "[Lumen][perf] 文档 \(pageCount) 页；本轮翻 \(turns) 页（请求 \(requested) 页）")

        await warmUp(controller: controller, pageCount: pageCount)

        let footprintAfterWarmUp = footprintBytes()

        // —— ① 翻页：第一遍正常回调（含 @Published 发布、SwiftUI 失效、进度落盘节流）。
        let withCallbacks = await measureTurns(
            controller: controller, count: turns, pageCount: pageCount
        )
        await settle(milliseconds: 1_200)
        let footprintAfterFirstPass = footprintBytes()

        // —— 第二遍：摘掉位置回调，只留 PDFKit 自身的翻页成本；同时**再访问同一批页**。
        // 两个目的合一：
        //   1) 与第一遍的耗时之差 = 我们这一层自己的每页开销（证伪点）；
        //   2) 与第一遍的内存之差 = 「反复浏览同一批内容」的增量（真泄漏才涨）。
        let savedCallback = controller.onPositionChange
        controller.onPositionChange = nil
        controller.go(to: 0)
        await settle(milliseconds: 300)
        let bare = await measureTurns(
            controller: controller, count: turns, pageCount: pageCount
        )
        controller.onPositionChange = savedCallback
        await settle(milliseconds: 1_200)
        let footprintAfterSecondPass = footprintBytes()

        // —— ② 滚动光栅化：按视口尺寸把每一页渲染一遍（滚动进新页的真实代价）。
        let scroll = await measureScrollRasterization(controller: controller, pageCount: pageCount)

        // —— ③ 缩略图：把全本缩略图都留在内存里，量它到底占多少。
        let thumbs = await measureThumbnailFootprint(controller: controller, pageCount: pageCount)

        report(
            pageCount: pageCount,
            turns: turns,
            withCallbacks: withCallbacks,
            bare: bare,
            scroll: scroll,
            thumbs: thumbs,
            footprintAfterWarmUp: footprintAfterWarmUp,
            footprintAfterFirstPass: footprintAfterFirstPass,
            footprintAfterSecondPass: footprintAfterSecondPass
        )
    }

    // MARK: - 测量

    /// 预热：把冷启动的一次性成本（索引、字体、首帧）先付掉，别污染稳定态读数。
    private static func warmUp(controller: PDFController, pageCount: Int) async {
        controller.go(to: 0)
        await settle(milliseconds: 400)
        for index in 1..<min(5, pageCount) {
            controller.go(to: index)
            await settle(milliseconds: 80)
        }
        // 顺带把缩略图/文本的首调也预热掉——滚动路径上会遇到它们。
        if let doc = controller.document, pageCount > 0 {
            _ = doc.page(at: 0)?.string
            _ = doc.page(at: 0)?.thumbnail(of: CGSize(width: 264, height: 354), for: .mediaBox)
        }
        controller.go(to: 0)
        await settle(milliseconds: 300)
    }

    /// 连翻 `count` 页，返回每一页的耗时（ms）。
    ///
    /// 计时**只包住翻页调用本身**：`go(to:)` 里的版本落地 + 滚动 + 位置回调都在这一帧
    /// 必须做完，正是「会不会掉帧」要看的那一段。每翻一页让出一次主线程
    /// （`Task.yield`），让排队的主线程工作有机会跑——不这么做测的是「一路把任务堆到最后」，
    /// 不反映真实浏览。
    private static func measureTurns(
        controller: PDFController,
        count: Int,
        pageCount: Int
    ) async -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for step in 0..<count {
            let target = (step + 1) % pageCount
            let start = DispatchTime.now()
            controller.go(to: target)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            samples.append(Double(elapsed) / 1_000_000)
            await Task.yield()
        }
        return samples
    }

    /// 滚动光栅化：按**真实视口尺寸**把每一页渲染一遍，逐页记时，返回耗时（ms）。
    ///
    /// 为什么是它：翻页走的是 `view.go(to:)`，PDFKit 只把视口挪过去，真正的页面绘制
    /// 发生在「页进入可视区」那一刻。滚动时每一帧都可能有新页进来，那笔绘制成本就是
    /// 滚动卡顿的直接来源。用 `page.thumbnail(of: viewportSize, for: .mediaBox)`
    /// 走同一条绘制管线，且尺寸用实际视口，读数才有意义。
    private static func measureScrollRasterization(
        controller: PDFController,
        pageCount: Int
    ) async -> [Double] {
        guard let doc = controller.document else { return [] }
        let viewport = controller.view.bounds.size
        let size = CGSize(
            width: max(viewport.width, 320),
            height: max(viewport.height, 320)
        )
        var samples: [Double] = []
        samples.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            guard let page = doc.page(at: index) else { continue }
            let start = DispatchTime.now()
            _ = page.thumbnail(of: size, for: .mediaBox)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            samples.append(Double(elapsed) / 1_000_000)
            await Task.yield()
        }
        return samples
    }

    /// 缩略图内存：用与侧栏**完全相同的策略**模拟「把侧栏从头滚到尾」，
    /// 量缓存最终驻留多少张、常驻内存涨多少。
    ///
    /// 它是「大文档内存持续增长」的定点探针。侧栏每渲染一页就存进 `ThumbnailCache`，
    /// 而缓存只在换文档时清空——所以「滚完全本后仍驻留多少张」是**确定性**的，
    /// 与内存采样无关，作为主判据；`phys_footprint` 增量作为现场佐证（受分配器复用
    /// 影响会有抖动，故只报不断言）。
    ///
    /// 走的是**生产同一套** `ThumbnailCache`：所以这里的读数就是侧栏的真实行为，
    /// 不是在测一个只为自检而存在的旁路。`--perf-thumbnail-unbounded 1` 把容量上限
    /// 关掉——重跑时驻留张数会回到「等于页数」，这就是本优化可证伪的证据。
    private static func measureThumbnailFootprint(
        controller: PDFController,
        pageCount: Int
    ) async -> ThumbnailMeasurement {
        let capacity = LaunchOptions.perfThumbnailUnbounded ? nil : ThumbnailCache.defaultCapacity
        guard let doc = controller.document else {
            return ThumbnailMeasurement(rendered: 0, resident: 0, footprintDeltaMB: 0, capacity: capacity)
        }
        // 与 `ThumbnailPane` 一致的 2 倍尺寸（132pt × 2）。
        let size = CGSize(width: 264, height: 354)

        // 先渲染全本一遍但不持有，把 PDFKit 自己的缩略图缓存填满，
        // 这样后面量到的增量才主要是**我们这份缓存**的账。
        for index in 0..<pageCount {
            _ = doc.page(at: index)?.thumbnail(of: size, for: .mediaBox)
            await Task.yield()
        }
        await settle(milliseconds: 600)
        let baseline = footprintBytes()

        // 模拟滚动：逐页渲染并按侧栏策略存入（当前页 = 刚渲染的这一页）。
        var cache = ThumbnailCache(capacity: capacity)
        var rendered = 0
        for index in 0..<pageCount {
            if let image = doc.page(at: index)?.thumbnail(of: size, for: .mediaBox) {
                cache.store(image, at: index, current: index)
                rendered += 1
            }
            await Task.yield()
        }
        await settle(milliseconds: 600)
        let held = footprintBytes()
        // 保证 `cache` 活到读完之后再释放，否则编译器可能提前回收，读到的增量是假的。
        let delta = signedMB(from: baseline, to: held)
        let resident = cache.count
        withExtendedLifetime(cache) {}

        return ThumbnailMeasurement(
            rendered: rendered,
            resident: resident,
            footprintDeltaMB: delta,
            capacity: capacity
        )
    }

    private static func settle(milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    // MARK: - 报文

    private struct ThumbnailMeasurement {
        let rendered: Int
        /// 滚完全本后缓存里仍驻留的缩略图张数（确定性读数，主判据）。
        let resident: Int
        /// 现场常驻内存净增（MB）。受分配器复用影响会有抖动，只报不断言。
        let footprintDeltaMB: Double
        /// 本次测量所用的容量上限；`nil` = 无上限（当前基线 / `--perf-thumbnail-unbounded`）。
        let capacity: Int?
    }

    private static func report(
        pageCount: Int,
        turns: Int,
        withCallbacks: [Double],
        bare: [Double],
        scroll: [Double],
        thumbs: ThumbnailMeasurement,
        footprintAfterWarmUp: UInt64,
        footprintAfterFirstPass: UInt64,
        footprintAfterSecondPass: UInt64
    ) {
        let a = stats(withCallbacks)
        let b = stats(bare)
        let s = stats(scroll)

        NSLog("%@", "[Lumen][perf] ── PDF 浏览性能（\(pageCount) 页，翻 \(turns) 页）──")
        NSLog(String(
            format: "[Lumen][perf] ① 翻页·带回调（正常路径）：p50=%.2fms p95=%.2fms max=%.2fms 均值=%.2fms",
            a.p50, a.p95, a.max, a.mean
        ))
        NSLog(String(
            format: "[Lumen][perf] ① 翻页·摘掉回调（纯 PDFKit）：p50=%.2fms p95=%.2fms max=%.2fms 均值=%.2fms",
            b.p50, b.p95, b.max, b.mean
        ))
        NSLog(String(
            format: "[Lumen][perf] ① 我们这一层的每页开销（p95 之差）：%.2fms；均值之差：%.2fms",
            a.p95 - b.p95, a.mean - b.mean
        ))
        NSLog(String(
            format: "[Lumen][perf] ② 滚动光栅化·按视口尺寸逐页渲染：p50=%.2fms p95=%.2fms max=%.2fms 均值=%.2fms",
            s.p50, s.p95, s.max, s.mean
        ))

        let firstPassMB = signedMB(from: footprintAfterWarmUp, to: footprintAfterFirstPass)
        let secondPassMB = signedMB(from: footprintAfterFirstPass, to: footprintAfterSecondPass)
        NSLog(String(
            format: "[Lumen][perf] ③ 进程常驻内存 phys_footprint：预热后 %.1fMB → 首遍后 %.1fMB → 次遍后 %.1fMB",
            mb(footprintAfterWarmUp), mb(footprintAfterFirstPass), mb(footprintAfterSecondPass)
        ))
        NSLog(String(
            format: "[Lumen][perf] ③ 翻页内存增量：首次遍历（含 PDFKit 一次性渲染缓存填充）%+.1fMB；"
                + "第二次遍历（反复浏览同一批内容）%+.1fMB",
            firstPassMB, secondPassMB
        ))
        let policy = thumbs.capacity.map { "有上限 \($0) 张" } ?? "无上限"
        NSLog(String(
            format: "[Lumen][perf] ④ 缩略图缓存（%@）：滚完全本 %d 页后仍驻留 %d 张；现场常驻内存净增 %+.1fMB",
            policy, thumbs.rendered, thumbs.resident, thumbs.footprintDeltaMB
        ))

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][perf] \(ok ? "✅" : "❌") \(name)" + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        check(
            String(format: "① 翻页 p95 ≤ %.1fms（60Hz 一帧）", turnP95BudgetMs),
            a.p95 <= turnP95BudgetMs,
            String(format: "实测 p95=%.2fms", a.p95)
        )
        check(
            String(format: "② 滚动光栅化 p95 ≤ %.1fms（60Hz 一帧）", frameBudgetMs),
            s.p95 <= frameBudgetMs,
            String(format: "实测 p95=%.2fms", s.p95)
        )
        // ③ 内存增量只报不断言。详见 `footprintBudgetMB` 的说明：这个跨遍增量由 PDFKit
        // 内部缓存 churn 主导，同机多次跑到 −21…+68MB，不可复现；对它下断言等于抛硬币。
        // 「会不会持续增长」交给**确定性**的 ④（仍驻留的张数）把关。
        NSLog(String(
            format: "[Lumen][perf] ③ 二次遍历增量 %+.1fMB（信息性读数；参考预算 ±%.0fMB，非断言）",
            secondPassMB, footprintBudgetMB
        ))
        if let capacity = thumbs.capacity {
            check(
                "④ 缩略图缓存有上限：滚完全本后仍驻留 ≤ \(capacity) 张（内存不随页数增长）",
                thumbs.resident <= capacity,
                "实测驻留 \(thumbs.resident) 张 / 全本 \(thumbs.rendered) 页"
            )
        } else {
            // 证伪对照：关掉上限后驻留张数应当回到「等于全本页数」。
            NSLog("%@", "[Lumen][perf] ④ 缩略图缓存上限已关闭（`--perf-thumbnail-unbounded 1`）："
                  + "驻留 \(thumbs.resident) 张 = 全本 \(thumbs.rendered) 页（证伪对照，不作断言）")
        }

        // 「摘掉回调更快」本身不是断言——回调是功能的一部分，不能删。这里只把它记成
        // 一条**诊断结论**，供后续优化判断该往哪一层使劲（见上文 ① 的差值行）。
        NSLog("[Lumen][perf] 诊断：我们这层开销占带回调 p95 的 "
              + String(format: "%.0f%%", a.p95 > 0 ? (a.p95 - b.p95) / a.p95 * 100 : 0)
              + "（占比高 → 优化本层回调有意义；接近 0 → 瓶颈在 PDFKit 内部）")

        NSLog("%@", "[Lumen][perf] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    private static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    private static func signedMB(from: UInt64, to: UInt64) -> Double {
        Double(Int64(to) - Int64(from)) / 1_048_576
    }

    private struct Stats {
        let p50: Double
        let p95: Double
        let max: Double
        let mean: Double
    }

    private static func stats(_ samples: [Double]) -> Stats {
        guard !samples.isEmpty else { return Stats(p50: 0, p95: 0, max: 0, mean: 0) }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
            return sorted[index]
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        return Stats(p50: percentile(0.5), p95: percentile(0.95),
                     max: sorted.last ?? 0, mean: mean)
    }

    // MARK: - 内存

    /// 进程当前常驻内存（`phys_footprint`）。失败返回 0（调用方按「读不到」处理）。
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

import Foundation
import LumenKit

/// 一段译文的呈现状态。
enum EPUBTranslationState: String, Sendable {
    case loading
    case done
    case failed

    /// 占位 / 失败文案。写在 Swift 侧而不是 JS 里：界面上的措辞要能一处改，
    /// 也要能被单测直接读到。
    var placeholder: String {
        switch self {
        case .loading: return "翻译中…"
        case .done:    return ""
        case .failed:  return "翻译失败"
        }
    }
}

/// EPUB 逐段翻译的编排器：取段落 → 并发请求 → 逐段回填 → 收尾统计。
///
/// 单独成类的理由：**翻译是长任务，而章节随时会变**。换章、关开关、
/// 关标签，都要求它能被干净地取消，而且取消之后不能再往新 DOM 里写旧译文
/// （那是「张冠李戴」级别的错）。所以请求过程必须是一个可持有的 Task，
/// 不能散落在视图的 `.task` 里。
///
/// 它不认识 WebKit：段落从哪来、译文写到哪去，全由注入的两个闭包决定，
/// 这样单测里塞一对数组就能跑完整条链路。
@MainActor
final class EPUBTranslationController: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var totalCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var failureCount = 0

    /// 一次翻译跑完后的收尾回调（用来弹提示条）。参数是失败段数。
    var onFinish: ((_ failed: Int) -> Void)?

    private var task: Task<Void, Never>?
    private let translator: MicrosoftTranslator
    /// 并发上限。一段一个 HTTP 请求，无上限的话一章几十段会把接口打爆（429），
    /// 且译文回填顺序会乱得没法读。批内并发 + 批间串行，顺序可控也够快。
    private let batchSize = 4

    init(translator: MicrosoftTranslator = .shared) {
        self.translator = translator
    }

    /// 开始翻译一章。
    ///
    /// - Parameters:
    ///   - target: 目标语言标签（`zh-Hans` / `en`）。
    ///   - paragraphs: 取当前章的段落原文（顺便完成 DOM 标记）。
    ///   - markLoading: 一次性把所有段落标成「翻译中…」。
    ///   - apply: 把第 `index` 段的译文写回页面。
    ///
    /// `markLoading` 为什么单独成一个闭包而不是拿 `apply` 循环：
    /// 段落回填到 WebKit 里是一次 `evaluateJavaScript`，一章几十段就是几十次
    /// 跨进程调用。铺占位必须是**一次** JS 在页面里批量插入，逐段往返光 IPC
    /// 就要几百毫秒，还会让占位一块一块往外蹦。
    func start(
        target: String,
        paragraphs: @escaping () async -> [String],
        markLoading: @escaping () -> Void,
        apply: @escaping (Int, String, EPUBTranslationState) -> Void
    ) {
        task?.cancel()
        totalCount = 0
        completedCount = 0
        failureCount = 0
        isRunning = true

        let translator = self.translator
        let batchSize = self.batchSize
        task = Task { [weak self] in
            let texts = await paragraphs()
            guard !Task.isCancelled, !texts.isEmpty else {
                await MainActor.run { self?.isRunning = false }
                return
            }
            await MainActor.run { self?.totalCount = texts.count }

            // 先一次性铺满「翻译中…」：等待期间读者能看到进度发生在哪些段上，
            // 而不是整页毫无动静地卡十几秒。
            await MainActor.run { markLoading() }

            var failed = 0
            var done = 0

            for start in stride(from: 0, to: texts.count, by: batchSize) {
                if Task.isCancelled { break }
                let slice = Array(start..<min(start + batchSize, texts.count))
                let results = await Self.translateBatch(
                    slice.map { texts[$0] },
                    indices: slice,
                    to: target,
                    translator: translator
                )
                await MainActor.run {
                    for (index, text) in results {
                        if let text {
                            apply(index, text, .done)
                            done += 1
                        } else {
                            apply(index, EPUBTranslationState.failed.placeholder, .failed)
                            failed += 1
                        }
                    }
                    self?.completedCount = done + failed
                    self?.failureCount = failed
                }
            }

            await MainActor.run {
                self?.isRunning = false
                self?.onFinish?(failed)
            }
        }
    }

    /// 取消并清空统计。换章 / 关开关都要走这里。
    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        totalCount = 0
        completedCount = 0
        failureCount = 0
    }

    private static func translateBatch(
        _ texts: [String],
        indices: [Int],
        to target: String,
        translator: MicrosoftTranslator
    ) async -> [(Int, String?)] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (offset, text) in texts.enumerated() {
                let index = indices[offset]
                group.addTask {
                    do {
                        return (index, try await translator.translate(text, to: target))
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var out: [(Int, String?)] = []
            for await item in group { out.append(item) }
            return out
        }
    }
}

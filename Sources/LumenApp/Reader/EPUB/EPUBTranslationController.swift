import Foundation
import LumenKit
import Translation

enum EPUBTranslationState: String, Sendable {
    case loading
    case done
    case failed
}

/// EPUB 当前章节的逐段翻译编排器。每次切章、换引擎或关闭翻译都会递增代际，
/// 旧请求即使晚到也不能再写进新的页面。
@MainActor
final class EPUBTranslationController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var totalCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var failureCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var appleSessionRequest = 0

    var onFinish: ((_ failed: Int) -> Void)?
    var onError: ((_ message: String) -> Void)?
    var retryAction: (() -> Void)?

    private struct Item: Sendable {
        let index: Int
        let text: String
        let cacheKey: String
    }

    private var task: Task<Void, Never>?
    private var generation = 0
    private var queuedAppleItems: [Item] = []
    private var cache = TranslationCache()
    private var cacheURL: URL?
    private var apply: ((Int, String, EPUBTranslationState) -> Void)?
    private var pendingSinceSave = 0

    private static let concurrency = 4
    private static let saveEvery = 8

    func start(
        documentPath: String,
        chapterIndex: Int,
        target: String,
        engineID: String,
        glossary: [TranslationGlossaryEntry],
        customEngine: (any TranslationEngine)?,
        paragraphs: @escaping () async throws -> [String],
        markLoading: @escaping ([Int]) -> Void,
        apply: @escaping (Int, String, EPUBTranslationState) -> Void
    ) {
        cancelRun()
        let token = generation
        isRunning = true
        totalCount = 0
        completedCount = 0
        failureCount = 0
        errorMessage = nil
        queuedAppleItems = []
        self.apply = apply

        let normalizedTarget = TranslationLanguage.target(for: target).id
        let scope = Self.cacheScope(engineID: engineID, glossary: glossary)
        let cacheURL = AppPaths.translationCacheFile(forPath: documentPath)
        self.cacheURL = cacheURL
        cache = TranslationCache.load(from: cacheURL)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let texts = try await paragraphs()
                guard token == self.generation, !Task.isCancelled else { return }
                guard !texts.isEmpty else {
                    self.finishWithError("当前章节没有识别到可翻译的正文段落。")
                    return
                }

                let items = texts.enumerated().compactMap { index, text -> Item? in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.contains(where: { $0.isLetter }),
                          !TranslationEligibility.isAlreadyTargetLanguage(trimmed, target: normalizedTarget)
                    else { return nil }
                    let identity = AppPaths.stableHash(trimmed)
                    let key = "epub::\(scope)::\(normalizedTarget)::c\(chapterIndex)-p\(index)-\(identity)"
                    return Item(index: index, text: trimmed, cacheKey: key)
                }

                guard !items.isEmpty else {
                    self.finishWithError("当前章节的正文已经是目标语言，或只有页码和装饰文字。")
                    return
                }

                self.totalCount = items.count
                var queue: [Item] = []
                for item in items {
                    if let cached = self.cache.translation(for: item.cacheKey) {
                        apply(item.index, cached, .done)
                        self.completedCount += 1
                    } else {
                        queue.append(item)
                    }
                }

                guard !queue.isEmpty else {
                    self.finish(failed: 0)
                    return
                }
                markLoading(queue.map(\.index))

                if engineID == AppleSystemTranslation.engineID {
                    self.queuedAppleItems = queue
                    self.task = nil
                    self.appleSessionRequest &+= 1
                    return
                }

                guard let engine = customEngine ?? TranslationEngineCatalog.engine(for: engineID) else {
                    self.finishWithError(engineID == LLMTranslation.engineID
                        ? "尚未配置可用的 AI 服务商，无法使用 LLM 翻译。"
                        : "所选翻译引擎不可用。")
                    return
                }
                await self.run(queue, engine: engine, target: normalizedTarget, token: token)
            } catch is CancellationError {
                return
            } catch {
                guard token == self.generation else { return }
                self.finishWithError(Self.describe(error))
            }
        }
    }

    func runApple(session: TranslationSession, target: String) async {
        let items = queuedAppleItems
        guard !items.isEmpty, task == nil else { return }
        queuedAppleItems = []
        let token = generation
        let normalizedTarget = TranslationLanguage.target(for: target).id
        task = Task { [weak self] in
            guard let self else { return }
            await self.runApple(items, session: session, target: normalizedTarget, token: token)
            if token == self.generation { self.task = nil }
        }
        await task?.value
    }

    func stop() {
        cancelRun()
        persistCache()
        isRunning = false
        totalCount = 0
        completedCount = 0
        failureCount = 0
        errorMessage = nil
    }

    func retry() { retryAction?() }

    private func cancelRun() {
        task?.cancel()
        task = nil
        queuedAppleItems = []
        generation &+= 1
    }

    private func run(_ items: [Item], engine: any TranslationEngine,
                     target: String, token: Int) async {
        await withTaskGroup(of: (Item, Result<String, Error>).self) { group in
            var next = 0
            func submit() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    do {
                        var pieces: [String] = []
                        for chunk in TranslationTextSplitter.split(item.text) {
                            pieces.append(try await engine.translate(chunk, to: target, from: "auto-detect"))
                        }
                        return (item, .success(TranslationTextSplitter.join(pieces, target: target)))
                    } catch {
                        return (item, .failure(error))
                    }
                }
            }
            for _ in 0..<min(Self.concurrency, items.count) { submit() }
            for await (item, result) in group {
                guard token == generation, !Task.isCancelled else { continue }
                consume(result, for: item)
                submit()
            }
        }
        guard token == generation, !Task.isCancelled else { return }
        finish(failed: failureCount)
    }

    private func runApple(_ items: [Item], session: TranslationSession,
                          target: String, token: Int) async {
        for item in items {
            guard token == generation, !Task.isCancelled else { return }
            do {
                var translated: [String] = []
                for chunk in TranslationTextSplitter.split(item.text) {
                    let response = try await session.translate(chunk)
                    translated.append(response.targetText)
                }
                consume(.success(TranslationTextSplitter.join(translated, target: target)), for: item)
            } catch {
                consume(.failure(error), for: item)
            }
        }
        guard token == generation, !Task.isCancelled else { return }
        finish(failed: failureCount)
    }

    private func consume(_ result: Result<String, Error>, for item: Item) {
        switch result {
        case .success(let value):
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                recordFailure("翻译引擎返回了空译文", item: item)
            } else {
                apply?(item.index, text, .done)
                cache.store(text, for: item.cacheKey)
                completedCount += 1
                pendingSinceSave += 1
                if pendingSinceSave >= Self.saveEvery { persistCache() }
            }
        case .failure(let error):
            recordFailure(Self.describe(error), item: item)
        }
    }

    private func recordFailure(_ reason: String, item: Item) {
        apply?(item.index, "翻译失败：\(reason)", .failed)
        completedCount += 1
        failureCount += 1
        if errorMessage == nil { errorMessage = reason }
    }

    private func finish(failed: Int) {
        persistCache()
        isRunning = false
        task = nil
        onFinish?(failed)
    }

    private func finishWithError(_ message: String) {
        errorMessage = message
        isRunning = false
        task = nil
        onError?(message)
    }

    private func persistCache() {
        guard let cacheURL else { return }
        cache.save(to: cacheURL)
        pendingSinceSave = 0
    }

    private static func cacheScope(engineID: String,
                                   glossary: [TranslationGlossaryEntry]) -> String {
        let terms = glossary.filter(\.isUsable)
            .map { "\($0.source)=\($0.target)" }
            .joined(separator: "|")
        return terms.isEmpty ? engineID : "\(engineID)-\(AppPaths.stableHash(terms))"
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

import Foundation

/// 单本文档的阅读状态。按文档路径哈希分目录存放，因此同名文件不会互相覆盖。
public struct ReadingState: Codable, Sendable, Equatable {
    /// 定位符的稳定字符串形式
    public var locationKey: String = ""
    /// 0…1 阅读进度，用于「最近打开」列表展示
    public var progress: Double = 0
    /// PDF 缩放倍率（EPUB 忽略）
    public var zoom: Double = 1.0
    /// 本书覆盖的主题（为空则跟随全局设置）
    public var themeOverride: ReadingThemeID?
    public var lastOpened: Date = Date()

    public init() {}
}

@MainActor
public final class ReadingStateStore: ObservableObject {

    @Published public private(set) var state: ReadingState
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    public init(documentPath: String) {
        self.fileURL = AppPaths.readingStateFile(forPath: documentPath)
        self.state = Self.load(from: fileURL)
    }

    private static func load(from url: URL) -> ReadingState {
        guard let data = try? Data(contentsOf: url) else { return ReadingState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ReadingState.self, from: data)) ?? ReadingState()
    }

    public func update(_ mutate: (inout ReadingState) -> Void) {
        mutate(&state)
        state.lastOpened = Date()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = state
        let url = fileURL
        saveTask = Task { [snapshot, url] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: url)
        }
    }

    public func flush() {
        saveTask?.cancel()
        let snapshot = state
        let url = fileURL
        Task { await Self.write(snapshot, to: url) }
    }

    private static func write(_ state: ReadingState, to url: URL) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

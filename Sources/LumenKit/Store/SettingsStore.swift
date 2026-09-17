import Foundation
import Combine

/// 设置的加载 / 保存 / 防抖落盘。
///
/// UI 里任何一次拖动滑杆都会触发 setter，所以写盘必须防抖，否则会疯狂 IO。
@MainActor
public final class SettingsStore: ObservableObject {

    @Published public var settings: AppSettings {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    /// 抑制落盘。
    ///
    /// 给自检通道用：从命令行改设置（面板宽度、主题预览之类）目的是验证，
    /// 不该把用户的真实配置覆盖掉。注意 setter 的**防抖落盘救不了这一点**——
    /// 防抖是「延迟写」，不是「不写」，等够 400ms 照样落盘。
    public var suppressSave = false

    public init(fileURL: URL = AppPaths.settingsFile) {
        self.fileURL = fileURL
        self.settings = Self.load(from: fileURL)
    }

    // MARK: - 持久化

    private static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return AppSettings() }
        let decoder = JSONDecoder()
        return (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    private func scheduleSave() {
        guard !suppressSave else { return }
        saveTask?.cancel()
        let snapshot = settings
        let url = fileURL
        saveTask = Task { [snapshot, url] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: url)
        }
    }

    /// 立即落盘（退出前调用）。
    public func flush() {
        guard !suppressSave else { return }
        saveTask?.cancel()
        saveTask = nil
        let snapshot = settings
        let url = fileURL
        Task { await Self.write(snapshot, to: url) }
    }

    private static func write(_ settings: AppSettings, to url: URL) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 便捷访问

    public var reader: ReaderSettings {
        get { settings.reader }
        set { settings.reader = newValue }
    }

    public var ai: AISettings {
        get { settings.ai }
        set { settings.ai = newValue }
    }

    public var ui: UISettings {
        get { settings.ui }
        set { settings.ui = newValue }
    }

    public var activeProvider: AIProviderConfig? {
        guard let id = settings.ai.activeProviderID else { return settings.ai.providers.first }
        return settings.ai.providers.first { $0.id == id } ?? settings.ai.providers.first
    }

    public var hasConfiguredProvider: Bool {
        activeProvider != nil
    }

    public func upsertProvider(_ provider: AIProviderConfig) {
        if let index = settings.ai.providers.firstIndex(where: { $0.id == provider.id }) {
            settings.ai.providers[index] = provider
        } else {
            settings.ai.providers.append(provider)
        }
        if settings.ai.activeProviderID == nil {
            settings.ai.activeProviderID = provider.id
        }
    }

    public func removeProvider(id: UUID) {
        settings.ai.providers.removeAll { $0.id == id }
        if settings.ai.activeProviderID == id {
            settings.ai.activeProviderID = settings.ai.providers.first?.id
        }
    }
}

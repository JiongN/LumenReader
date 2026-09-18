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
        // 整份文件解不出来（JSON 语法坏 / 顶层类型不对）→ 备份原文件 + NSLog，退回默认。
        // 原文件已被改名，之后的防抖保存写的是新文件，不会把用户配置盖成一份默认值。
        guard let settings = PersistFile.decodeOrBackup(
            data: data,
            type: AppSettings.self,
            fileURL: url,
            decoder: decoder,
            reason: "settings.json"
        ) else {
            return AppSettings()
        }
        // 次级防线：整份文件可能「解得出」——因为逐字段容错把服务商配置吞成了空数组。
        // 判据：磁盘上列着服务商、解出来却是空的（见 providersLookLost）。
        // 命中就把 settings.json 备份掉，保住用户重录不出来的那部分配置。
        if settings.ai.providers.isEmpty, providersLookLost(inJSON: data) {
            PersistFile.backupCorrupt(url, reason: "AI 服务商配置解码失败（磁盘有条目、解出为空）")
        }
        return settings
    }

    /// `settings.json` 里「服务商条目被静默吞掉」的判据。
    ///
    /// 顶层结构是 `{ "ai": { "providers": [...] } }`（键名来自 `AISettings` / `AppSettings`
    /// 的合成 CodingKeys，此处硬编码——`SettingsStore` 与它们同文件同模块，键名改动时
    /// `PersistFileTests` 里那条「键路径」断言会立刻变红）。
    ///
    /// - 「磁盘上是非空数组、解出来是空」→ 解码坏了；
    /// - 「providers 键存在但不是数组」→ 一定是坏的；
    /// - 「键不存在」或「是空数组」→ 是合法的「用户没有服务商」，不备份。
    private static func providersLookLost(inJSON data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let ai = root["ai"] as? [String: Any],
              let raw = ai["providers"] else { return false }
        if let array = raw as? [Any] { return !array.isEmpty }
        return true
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
        PersistFile.write(data, to: url, label: "settings.json")
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

    // MARK: - 面板宽度

    /// 提交侧栏宽度。**兼容保留，布局已不再读取它。**
    ///
    /// 侧栏宽度自本批起固定为 `DS.Size.sidebarIdeal`（248pt），界面上也没有拖它的
    /// 入口了。这个方法保留下来只为「旧 `--panel-width` 的侧栏分量仍被写一处」——
    /// 写进去的值会经过与从前完全相同的钳制，但不会再影响版面。
    /// 新代码请用 `commitAIPanelWidth`。
    ///
    /// - Parameter maxWidth: 按当前窗口宽度算出的动态上限；`nil` 表示只按静态范围钳。
    public func commitSidebarWidth(_ value: Double, maxWidth: Double? = nil) {
        let clamped = maxWidth.map { UISettings.PanelWidth.clampSidebar(value, maxWidth: $0) }
            ?? UISettings.PanelWidth.clampSidebar(value)
        guard clamped != ui.sidebarWidth else { return }
        ui.sidebarWidth = clamped
    }

    /// 提交 AI 面板宽度。**所有入口都走这里**（拖拽松手、双击复位、自检通道），
    /// 于是「钳制」只有一份实现。
    ///
    /// 分开写迟早会漏一处：拖拽自己钳一次、设置页再钳一次，漏掉的那个入口
    /// 就能把宽度写成 5000，把阅读区整个挤没——而它平时根本用不到，
    /// 只有窗口被拖小之后才会现形。
    ///
    /// - Parameter maxWidth: 按当前窗口宽度算出的动态上限；`nil` 表示只按静态范围钳。
    /// - Note: 写入后仍会经过 `UISettings.aiPanelWidth` 的 `didSet`（第二道闸），
    ///   两道闸的取值范围一致，不会互相拉扯。
    public func commitAIPanelWidth(_ value: Double, maxWidth: Double? = nil) {
        let clamped = maxWidth.map { UISettings.PanelWidth.clampAI(value, maxWidth: $0) }
            ?? UISettings.PanelWidth.clampAI(value)
        guard clamped != ui.aiPanelWidth else { return }
        ui.aiPanelWidth = clamped
    }
}

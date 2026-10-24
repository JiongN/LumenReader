import SwiftUI
import LumenKit

/// AI 设置页。
///
/// 一个刻意的设计：把「测试连接」放在最显眼的位置。
/// 自备密钥最容易出的错是填错、过期、余额不足、Base URL 少了 `/v1`，
/// 这些都不该等到用户读完一段文字、点了提问才发现。
struct AISettingsPane: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var memory: MemoryStore

    @State private var keyInput: String = ""
    @State private var openAlexKeyInput = ""
    @State private var hasOpenAlexKey = false
    @State private var newMemory: String = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var isFetchingModels = false
    @State private var feedback: Feedback?
    @State private var editingProviderID: UUID?
    @State private var newModel = ""

    private struct Feedback: Equatable {
        enum Level { case success, failure, info }
        var level: Level
        var message: String
    }

    var body: some View {
        Form {
            providerSection

            if let binding = editingProviderBinding {
                credentialSection(binding)
                modelSection(binding)
            } else {
                Section {
                    Text("暂无服务商")
                        .font(DS.Typo.ui(size: 12))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }

            ModelPurposeSettings()
            behaviorSection

            openAlexSection
            DocumentAISettingsPane()
            memorySection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            editingProviderID = editingProviderID ?? settings.activeProvider?.id
            refreshKeyState()
            hasOpenAlexKey = AICredentialStore.hasKey(account: "openalex-api")
        }
        .onChange(of: editingProviderID) { _, _ in
            keyInput = ""
            newModel = ""
            refreshKeyState()
        }
    }

    // MARK: - 服务商列表

    private var openAlexSection: some View {
        Section("文献图谱 · OpenAlex") {
            HStack {
                SecureField(hasOpenAlexKey ? "已保存（留空不变）" : "可选 API Key", text: $openAlexKeyInput)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    let value = openAlexKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if AICredentialStore.save(value, account: "openalex-api") {
                        openAlexKeyInput = ""
                        hasOpenAlexKey = true
                    }
                }.disabled(openAlexKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasOpenAlexKey {
                    Button("移除") {
                        AICredentialStore.delete(account: "openalex-api")
                        hasOpenAlexKey = false
                    }
                }
            }
            Text("基础查询可免密钥使用；Key 单独保存在本机，仅发送到 OpenAlex。")
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }

    private var providerSection: some View {
        Section("服务商配置") {
            ForEach(settings.settings.ai.providers) { provider in
                providerRow(provider)
            }

            Menu {
                Section("预设") {
                    ForEach(Array(AIProviderConfig.presets.enumerated()), id: \.offset) { _, preset in
                        Button(preset.name) { add(preset) }
                    }
                }
                Divider()
                Button("自定义…") { add(nil) }
            } label: {
                Label("添加服务商", systemImage: "plus")
                    .font(DS.Typo.ui(size: 12.5))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 180)
        }
    }

    private func providerRow(_ provider: AIProviderConfig) -> some View {
        let isActive = editingProviderID == provider.id
        let ready = provider.isConfigured

        return HStack(spacing: DS.Space.s) {
            Button {
                editingProviderID = provider.id
                refreshKeyState()
            } label: {
                Image(systemName: isActive ? "pencil.circle.fill" : "pencil.circle")
                    .font(DS.Typo.ui(size: 13))
                    .foregroundStyle(isActive ? DS.Palette.accent : DS.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("编辑该服务商")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(provider.name)
                        .font(DS.Typo.ui(size: 12.5, weight: .medium))
                    Circle()
                        .fill(ready ? DS.Palette.success : DS.Palette.warning)
                        .frame(width: 5, height: 5)
                }
                Text(URL(string: provider.baseURL)?.host ?? provider.baseURL)
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                settings.removeProvider(id: provider.id)
                if editingProviderID == provider.id { editingProviderID = settings.ai.providers.first?.id }
                refreshKeyState()
            } label: {
                Image(systemName: "trash")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("删除该服务商")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingProviderID = provider.id
            refreshKeyState()
        }
    }

    // MARK: - 凭据

    private func credentialSection(_ binding: Binding<AIProviderConfig>) -> some View {
        Section("凭据") {
            LabeledField(label: "名称") {
                TextField("服务商名称", text: binding.name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            // `.labelsHidden()` 不能省。macOS 的分组表单会把行里出现的 `TextField`
            // 当成「带标签的控件」，把它的 **placeholder 抽出来当成这一行的标签**渲染在
            // 左半边，真正可编辑的输入框被挤到右半边。症状是 URL / 密钥 / 模型名各显示
            // 两遍——左边一遍（其实是 placeholder）右边一遍（真实值），且输入框只剩半宽。
            // 这一行已经有 `LabeledField` 给的标签了，把表单那套标签关掉即可复原。
            LabeledField(label: "Base URL") {
                TextField("https://api.deepseek.com/v1", text: binding.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typo.ui(size: 12, design: .monospaced))
                    .labelsHidden()
            }

            LabeledField(label: "API 密钥") {
                HStack(spacing: DS.Space.s) {
                    SecureField(hasStoredKey ? "已保存（重新填写可覆盖）" : "粘贴密钥", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.Typo.ui(size: 12, design: .monospaced))
                        .labelsHidden()

                    Button("保存") {
                        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        let ok = AICredentialStore.save(trimmed, account: binding.wrappedValue.keychainAccount)
                        if ok {
                            keyInput = ""
                            refreshKeyState()
                            feedback = Feedback(level: .success, message: "API Key 已保存在本机，下次无需重新输入。")
                        } else {
                            feedback = Feedback(level: .failure, message: "无法保存 API Key，请检查应用数据目录的写入权限。")
                        }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if hasStoredKey {
                        Button("清除") {
                            AICredentialStore.delete(account: binding.wrappedValue.keychainAccount)
                            refreshKeyState()
                            feedback = Feedback(level: .info, message: "已移除本机保存的 API Key。")
                        }
                    }
                }
            }

            HStack(spacing: DS.Space.s) {
                Label(hasStoredKey ? "已配置密钥" : "未配置密钥",
                      systemImage: hasStoredKey ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(DS.Typo.ui(size: 11.5))
                    .foregroundStyle(hasStoredKey ? DS.Palette.success : DS.Palette.warning)

                Spacer()

                Button {
                    Task { await testConnection(binding.wrappedValue) }
                } label: {
                    HStack(spacing: 5) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(isTesting ? "测试中…" : "测试连接")
                    }
                    .font(DS.Typo.ui(size: 12))
                }
                .disabled(isTesting)
            }

            Text("密钥保存在本机，文件未加密，不包含在设置导出中。")
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let feedback {
                Label(feedback.message, systemImage: icon(for: feedback.level))
                    .font(DS.Typo.ui(size: 11.5))
                    .foregroundStyle(color(for: feedback.level))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 模型

    private func modelSection(_ binding: Binding<AIProviderConfig>) -> some View {
        Section("模型") {
            LabeledField(label: "添加模型") {
                HStack(spacing: DS.Space.s) {
                    TextField("模型 ID", text: $newModel)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.Typo.ui(size: 12, design: .monospaced))
                        .labelsHidden()
                        .onSubmit { addModel(to: binding) }

                    Button("加入列表") { addModel(to: binding) }
                        .disabled(newModel
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await fetchModels(binding.wrappedValue) }
                    } label: {
                        HStack(spacing: 4) {
                            if isFetchingModels { ProgressView().controlSize(.small) }
                            Text("获取")
                        }
                        .font(DS.Typo.ui(size: 12))
                    }
                    .disabled(isFetchingModels)
                    .help("调用 GET /models 拉取可用模型")
                }
            }

            if !binding.wrappedValue.models.isEmpty {
                LabeledField(label: "可用模型") {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(binding.wrappedValue.models, id: \.self) { model in
                                HStack(spacing: DS.Space.s) {
                                    Text(model)
                                        .font(DS.Typo.ui(size: 11.5, design: .monospaced))
                                        .foregroundStyle(DS.Palette.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button {
                                        removeModel(model, from: binding)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(DS.Palette.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("从这个服务商移除模型")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            LabeledSlider(
                title: "温度",
                value: binding.temperature,
                range: 0...1.5,
                step: 0.05,
                valueText: { String(format: "%.2f", $0) }
            )

            LabeledField(label: "最大输出") {
                HStack {
                    let outputLimit = Binding<Int>(
                        get: { min(393216, max(1, binding.wrappedValue.maxTokens)) },
                        set: { binding.wrappedValue.maxTokens = min(393216, max(1, $0)) }
                    )
                    TextField("Tokens", value: outputLimit, format: .number)
                        .font(DS.Typo.mono)
                        .monospacedDigit()
                        .frame(width: 84)
                    Stepper("", value: outputLimit, in: 1...393216, step: 256)
                        .labelsHidden()
                    Spacer()
                }
            }

            Toggle("扩展思考（推理模型）", isOn: binding.extendedThinking)
                .font(DS.Typo.ui(size: 12.5))
                .help("DeepSeek 官方新版模型按此开关启用或关闭思考；思考与正文共用最大输出预算。其他接口不假定支持该参数。")

            LabeledField(label: "上下文容量") {
                TextField("Tokens", value: binding.contextWindow, format: .number)
                    .labelsHidden()
                    .onSubmit { binding.wrappedValue.contextWindow = max(4096, binding.wrappedValue.contextWindow) }
            }
            if let capacity = binding.wrappedValue.publishedContextWindow,
               capacity != binding.wrappedValue.contextWindow {
                Button { binding.wrappedValue.contextWindow = capacity } label: {
                    Label("采用官方容量 \(capacity / 1024)K", systemImage: "arrow.up.right")
                }
                .help("按华师大官方规格设置；更大的全文材料可能增加输入 token 与费用")
            }
            Text("输入可用：\(ContextBudget.inputLimit(binding.wrappedValue)) token（尚未扣除提示、历史与材料标记）")
                .font(DS.Typo.ui(size: 11)).foregroundStyle(DS.Palette.textSecondary)

        }
    }

    // MARK: - 行为

    private var behaviorSection: some View {
        Section("行为") {
            LabeledField(label: "翻译目标") {
                TextField("简体中文", text: $settings.settings.ai.translateTarget)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typo.ui(size: 12))
                    .labelsHidden()
            }
            Toggle("流式输出", isOn: $settings.settings.ai.streaming)
                .font(DS.Typo.ui(size: 12.5))
        }
    }

    // MARK: - 记忆

    @ViewBuilder
    private var memorySection: some View {
        Section("长期偏好") {
            TextEditor(text: $settings.settings.ai.persistentMemory)
                .font(DS.Typo.ui(size: 12))
                .frame(minHeight: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                )

            Text("每次对话发送给模型，留空则不发送。")
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("跨会话记忆") {
            HStack(alignment: .bottom, spacing: DS.Space.s) {
                TextField("记一条事实，例如：我这篇论文用的是扎根理论三级编码", text: $newMemory, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.ui(size: 12))
                    .lineLimit(1...4)
                    .labelsHidden()
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(DS.Palette.surfaceRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                    )
                    .onSubmit(addMemoryFromField)

                Button("记下") { addMemoryFromField() }
                    .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if memory.entries.isEmpty {
                Text("暂无记忆")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(memory.entries) { entry in
                    memoryRow(entry)
                }

                HStack {
                    Text("已用 \(memory.currentPromptCost) / \(MemoryStore.promptBudget) 字符，按时间从新到旧送入模型")
                        .font(DS.Typo.ui(size: 10.5))
                        .foregroundStyle(DS.Palette.textTertiary)
                    Spacer()
                    Button("全部清空", role: .destructive) { memory.removeAll() }
                        .font(DS.Typo.ui(size: 11))
                }
            }
        }
    }

    private func memoryRow(_ entry: MemoryEntry) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "brain")
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(DS.Typo.ui(size: 12))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(entry.originLabel) · \(Self.shortDate(entry.createdAt))")
                    .font(DS.Typo.ui(size: 10))
                    .foregroundStyle(DS.Palette.textTertiary)
            }

            Spacer(minLength: 0)

            Button {
                memory.remove(entry)
            } label: {
                Image(systemName: "trash")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("删除这条记忆")
        }
        .padding(.vertical, 2)
    }

    private func addMemoryFromField() {
        let text = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        memory.add(text: text)
        newMemory = ""
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    // MARK: - 动作

    private var editingProviderBinding: Binding<AIProviderConfig>? {
        let ai = settings.settings.ai
        guard let id = editingProviderID ?? ai.providers.first?.id,
              let index = ai.providers.firstIndex(where: { $0.id == id }) else { return nil }
        return $settings.settings.ai.providers[index]
    }

    private func add(_ preset: AIProviderConfig?) {
        let provider = preset ?? AIProviderConfig(
            name: "自定义服务商",
            baseURL: "https://",
            models: [],
            selectedModel: ""
        )
        settings.upsertProvider(provider)
        editingProviderID = provider.id
        keyInput = ""
        hasStoredKey = false
        feedback = nil
    }

    private func addModel(to binding: Binding<AIProviderConfig>) {
        let model = newModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        if !binding.wrappedValue.models.contains(model) {
            binding.wrappedValue.models.append(model)
        }
        newModel = ""
    }

    private func removeModel(_ model: String, from binding: Binding<AIProviderConfig>) {
        binding.wrappedValue.models.removeAll { $0 == model }
    }

    private func refreshKeyState() {
        guard let config = editingProviderBinding?.wrappedValue else {
            hasStoredKey = false
            return
        }
        hasStoredKey = AICredentialStore.hasKey(account: config.keychainAccount)
        feedback = nil
    }

    private func effectiveKey(for config: AIProviderConfig) -> String {
        let typed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (AICredentialStore.read(account: config.keychainAccount) ?? "") : typed
    }

    /// 真刀真枪发一次最小请求。
    /// 不用 `GET /models` 当唯一判据：部分网关不实现该端点，但对话本身是通的。
    private func testConnection(_ config: AIProviderConfig) async {
        isTesting = true
        defer { isTesting = false }

        var probe = config
        probe.maxTokens = 24
        probe.selectedModel = config.selectedModel.trimmingCharacters(in: .whitespaces)
        guard !probe.selectedModel.isEmpty else {
            feedback = Feedback(level: .failure, message: "请先填写模型名。")
            return
        }

        let provider = OpenAICompatibleProvider(config: probe, apiKey: effectiveKey(for: config))
        do {
            var received = false
            for try await event in provider.stream(messages: [.user("只回复两个字：收到")]) {
                if case .delta = event { received = true; break }
            }
            feedback = received
                ? Feedback(level: .success, message: "连接成功，模型 \(probe.selectedModel) 已响应。")
                : Feedback(level: .failure, message: "服务响应正常，但没有返回正文内容。可能模型名不对，或该模型不支持当前接口。")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feedback = Feedback(level: .failure, message: message)
        }
    }

    private func fetchModels(_ config: AIProviderConfig) async {
        isFetchingModels = true
        defer { isFetchingModels = false }

        let provider = OpenAICompatibleProvider(config: config, apiKey: effectiveKey(for: config))
        do {
            let models = try await provider.availableModels()
            guard !models.isEmpty else {
                feedback = Feedback(level: .info, message: "服务端返回了空的模型列表。手动填写模型名即可。")
                return
            }
            if let index = settings.settings.ai.providers.firstIndex(where: { $0.id == config.id }) {
                settings.settings.ai.providers[index].models = models
            }
            feedback = Feedback(level: .success, message: "获取到 \(models.count) 个模型。")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feedback = Feedback(level: .failure, message: "获取模型列表失败：\(message)")
        }
    }

    private func icon(for level: Feedback.Level) -> String {
        switch level {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private func color(for level: Feedback.Level) -> Color {
        switch level {
        case .success: return DS.Palette.success
        case .failure: return DS.Palette.danger
        case .info:    return DS.Palette.textSecondary
        }
    }
}

/// 左标签右控件的表单行。用它统一宽度，避免 macOS 表单里标签列跳动。
struct LabeledField<Content: View>: View {

    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Text(label)
                .font(DS.Typo.ui(size: 12))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 76, alignment: .leading)
                .padding(.top, 4)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

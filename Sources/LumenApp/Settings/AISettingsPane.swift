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
    @State private var newMemory: String = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var isFetchingModels = false
    @State private var feedback: Feedback?

    private struct Feedback: Equatable {
        enum Level { case success, failure, info }
        var level: Level
        var message: String
    }

    var body: some View {
        Form {
            providerSection

            if let binding = activeProviderBinding {
                credentialSection(binding)
                modelSection(binding)
                behaviorSection
            } else {
                Section {
                    Text("还没有服务商。点上面的「添加服务商」从预设里选一个，或手动新建。")
                        .font(DS.Typo.ui(size: 12))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }

            memorySection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear(perform: refreshKeyState)
        .onChange(of: settings.settings.ai.activeProviderID) { _, _ in refreshKeyState() }
    }

    // MARK: - 服务商列表

    private var providerSection: some View {
        Section("服务商") {
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
        let isActive = settings.settings.ai.activeProviderID == provider.id
        let ready = provider.isConfigured

        return HStack(spacing: DS.Space.s) {
            Button {
                settings.settings.ai.activeProviderID = provider.id
                refreshKeyState()
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(DS.Typo.ui(size: 13))
                    .foregroundStyle(isActive ? DS.Palette.accent : DS.Palette.textTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(provider.name)
                        .font(DS.Typo.ui(size: 12.5, weight: .medium))
                    Circle()
                        .fill(ready ? DS.Palette.success : DS.Palette.warning)
                        .frame(width: 5, height: 5)
                }
                Text(provider.models.isEmpty ? "未设置模型" : (provider.selectedModel.isEmpty ? "未选模型" : provider.selectedModel))
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                settings.removeProvider(id: provider.id)
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
            settings.settings.ai.activeProviderID = provider.id
            refreshKeyState()
        }
    }

    // MARK: - 凭据

    private func credentialSection(_ binding: Binding<AIProviderConfig>) -> some View {
        Section("凭据") {
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
                        let ok = AIKeychain.save(trimmed, account: binding.wrappedValue.keychainAccount)
                        if ok {
                            keyInput = ""
                            refreshKeyState()
                            feedback = Feedback(level: .success, message: "密钥已存入系统钥匙串。")
                        } else {
                            feedback = Feedback(level: .failure, message: "写入钥匙串失败。可能被系统权限拦下了，请重试。")
                        }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if hasStoredKey {
                        Button("清除") {
                            AIKeychain.delete(account: binding.wrappedValue.keychainAccount)
                            refreshKeyState()
                            feedback = Feedback(level: .info, message: "已从钥匙串移除密钥。")
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

            Text("密钥只写入 macOS 钥匙串（服务名 com.jn.lumen.ai），不会出现在 settings.json、日志或任何网络请求的正文里。")
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
            LabeledField(label: "模型名") {
                HStack(spacing: DS.Space.s) {
                    TextField("deepseek-chat", text: binding.selectedModel)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.Typo.ui(size: 12, design: .monospaced))
                        .labelsHidden()

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
                LabeledField(label: "已获取") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Space.xs) {
                            ForEach(binding.wrappedValue.models, id: \.self) { model in
                                Button {
                                    binding.wrappedValue.selectedModel = model
                                } label: {
                                    Text(model)
                                        .font(DS.Typo.ui(size: 11))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule().fill(
                                                model == binding.wrappedValue.selectedModel
                                                    ? DS.Palette.accent
                                                    : DS.Palette.surfaceSunken
                                            )
                                        )
                                        .foregroundStyle(
                                            model == binding.wrappedValue.selectedModel
                                                ? Color.white
                                                : DS.Palette.textSecondary
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 1)
                    }
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
                    Slider(
                        value: Binding(
                            get: { Double(binding.wrappedValue.maxTokens) },
                            set: { binding.wrappedValue.maxTokens = Int($0) }
                        ),
                        in: 256...16000,
                        step: 256
                    )
                    Text("\(binding.wrappedValue.maxTokens)")
                        .font(DS.Typo.mono)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }

            Toggle("扩展思考（推理模型）", isOn: binding.extendedThinking)
                .font(DS.Typo.ui(size: 12.5))

            Text("说明：DeepSeek-R1 / o 系列等推理模型会额外返回思考过程，Lumen 会把它折叠显示在回答上方。")
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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

            Text("这段话会在每一次对话中作为背景交给模型，写「你希望它怎么回答」——例如你的专业方向、正在做的研究、偏好的表述方式。留空即不发送。")
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
                Text("还没有记忆条目。也可以在阅读时用「记住选中内容」，或点 AI 回答下方的「记住」。")
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

    private var activeProviderBinding: Binding<AIProviderConfig>? {
        let ai = settings.settings.ai
        guard let id = ai.activeProviderID ?? ai.providers.first?.id,
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
        settings.settings.ai.activeProviderID = provider.id
        keyInput = ""
        hasStoredKey = false
        feedback = nil
    }

    private func refreshKeyState() {
        guard let config = activeProviderBinding?.wrappedValue else {
            hasStoredKey = false
            return
        }
        hasStoredKey = AIKeychain.hasKey(account: config.keychainAccount)
        feedback = nil
    }

    private func effectiveKey(for config: AIProviderConfig) -> String {
        let typed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (AIKeychain.read(account: config.keychainAccount) ?? "") : typed
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
                if settings.settings.ai.providers[index].selectedModel.isEmpty {
                    settings.settings.ai.providers[index].selectedModel = models.first ?? ""
                }
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

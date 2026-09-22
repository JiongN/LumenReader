import SwiftUI
import LumenKit

/// EPUB 的翻译入口与状态面板。译文仍直接插在正文段落上方，左侧栏只负责
/// 开关、引擎、目标语言、进度和可恢复的错误。
struct EPUBTranslationPane: View {
    @ObservedObject var controller: EPUBTranslationController
    @EnvironmentObject private var settings: SettingsStore

    private var reader: ReaderSettings { settings.reader }
    private var isLLM: Bool { reader.translationEngineID == LLMTranslation.engineID }
    private var targetName: String {
        TranslationLanguage.target(for: reader.translationTargetLanguage).displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            status
            Spacer(minLength: 0)
        }
        .background(DS.Palette.surfaceSunken)
        .task {
            if !settings.reader.epubTranslateEnabled {
                settings.reader.epubTranslateEnabled = true
            } else if !controller.isRunning && controller.totalCount == 0 {
                // 开关可能是上次启动保留的 true，此时 onChange 不会再触发。
                // 进入面板就走一次真实重试通道，避免永远停在“正在准备”。
                controller.retry()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("EPUB 逐段翻译")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Toggle("逐段翻译", isOn: $settings.reader.epubTranslateEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer(minLength: 0)
                Menu(targetName) {
                    ForEach(TranslationLanguage.targets) { language in
                        Button(language.displayName) {
                            settings.reader.translationTargetLanguage = language.id
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            Picker("翻译方式", selection: engineMode) {
                Text("机器翻译").tag(false)
                Text("LLM").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: DS.Space.s) {
                if isLLM {
                    Label(llmModelName, systemImage: "sparkles")
                        .lineLimit(1)
                        .help("使用当前 AI 服务商与模型")
                } else {
                    Menu {
                        machineEngineButton(AppleSystemTranslation.descriptor)
                        machineEngineButton(MicrosoftTranslationEngine().descriptor)
                    } label: {
                        Label(machineEngineName, systemImage: "gearshape.2")
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                }
                Spacer(minLength: 0)
                if controller.isRunning {
                    ProgressView().controlSize(.small)
                    Button("停止") {
                        settings.reader.epubTranslateEnabled = false
                    }
                    .buttonStyle(.plain)
                } else if controller.failureCount > 0 || controller.errorMessage != nil {
                    Button("重试") { controller.retry() }
                        .buttonStyle(.plain)
                }
            }
            .font(DS.Typo.ui(size: 11.5, weight: .medium))
            .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(DS.Space.m)
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !reader.epubTranslateEnabled {
                SidebarEmptyState(
                    icon: "character.book.closed",
                    title: "逐段翻译已关闭",
                    message: "打开后，译文会紧跟在当前章节每段原文的下方。"
                )
            } else if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DS.Typo.ui(size: 11.5))
                    .foregroundStyle(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.m)
            } else if controller.totalCount > 0 {
                Text("当前章节 \(controller.completedCount) / \(controller.totalCount) 段")
                    .font(DS.Typo.ui(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .monospacedDigit()
                    .padding(.horizontal, DS.Space.m)
                    .padding(.top, DS.Space.m)
                Text("译文直接显示在正文中；切换章节会自动翻译新章节，已完成的结果会从缓存恢复。")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.m)
            } else {
                SidebarEmptyState(
                    icon: "character.book.closed",
                    title: "正在准备逐段翻译",
                    message: "章节载入后会识别正文段落并开始翻译。"
                )
            }
        }
    }

    private var engineMode: Binding<Bool> {
        Binding(
            get: { isLLM },
            set: { useLLM in
                if useLLM {
                    if !isLLM { settings.reader.translationMachineEngineID = reader.translationEngineID }
                    settings.reader.translationEngineID = LLMTranslation.engineID
                } else {
                    settings.reader.translationEngineID = TranslationEngineCatalog
                        .descriptor(for: reader.translationMachineEngineID).id
                }
            }
        )
    }

    @ViewBuilder
    private func machineEngineButton(_ descriptor: TranslationEngineDescriptor) -> some View {
        Button {
            settings.reader.translationEngineID = descriptor.id
            settings.reader.translationMachineEngineID = descriptor.id
        } label: {
            if reader.translationEngineID == descriptor.id {
                Label(descriptor.displayName, systemImage: "checkmark")
            } else {
                Text(descriptor.displayName)
            }
        }
    }

    private var machineEngineName: String {
        TranslationEngineCatalog.descriptor(for: reader.translationEngineID).displayName
    }

    private var llmModelName: String {
        guard let provider = settings.activeProvider, provider.isConfigured else { return "未配置 AI" }
        return provider.selectedModel.isEmpty ? provider.name : provider.selectedModel
    }
}

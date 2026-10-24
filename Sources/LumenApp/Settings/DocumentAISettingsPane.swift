import SwiftUI
import LumenKit

struct DocumentAISettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var parserKey = ""
    @State private var translationKey = ""
    @State private var failure: String?
    private var options: Binding<DocumentAIOptions> { $settings.settings.ai.documentAI }

    var body: some View {
        Section("文档 AI") {
            Picker("语义索引服务", selection: options.embeddingProviderID) {
                Text("不使用").tag(UUID?.none)
                ForEach(settings.ai.providers) { provider in Text(provider.name).tag(Optional(provider.id)) }
            }
            if options.wrappedValue.embeddingProviderID != nil {
                TextField("Embedding 模型", text: options.embeddingModel)
            }
            Toggle("复杂页面增强解析", isOn: options.parsingEnabled)
            if options.wrappedValue.parsingEnabled {
                TextField("OCR Base URL", text: options.parsingBaseURL)
                TextField("OCR 模型", text: options.parsingModel)
                HStack {
                    SecureField(AICredentialStore.hasKey(account: "mistral-document-ocr") ? "OCR 密钥已保存" : "Mistral OCR 密钥", text: $parserKey)
                    Button("保存") { save(&parserKey, account: "mistral-document-ocr") }.disabled(parserKey.isEmpty)
                }
                Text("仅上传待增强页图。解析结果保存在本机；费用取决于服务商，当前未知。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("官方机器翻译 · Azure") {
            TextField("Translator Base URL", text: options.officialTranslationBaseURL)
            TextField("资源区域", text: options.officialTranslationRegion)
            HStack {
                SecureField(AICredentialStore.hasKey(account: "azure-translator") ? "密钥已保存" : "Translator 密钥", text: $translationKey)
                Button("保存") { save(&translationKey, account: "azure-translator") }.disabled(translationKey.isEmpty)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
    }

    private func save(_ value: inout String, account: String) {
        if AICredentialStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account) { value = ""; failure = nil }
        else { failure = "无法保存密钥，请检查应用数据目录权限。" }
    }
}

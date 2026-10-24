import Foundation

public struct OfficialTranslationEngine: TranslationEngine {
    public static let engineID = "azure-translator"
    public static let description = TranslationEngineDescriptor(id: engineID, displayName: "微软官方 API",
        requiresNetwork: true, note: "使用你配置的 Azure Translator 资源与额度。")
    public let descriptor = Self.description
    private var client: DocumentAIClient
    private var key: String
    private var region: String
    public init(baseURL: String, key: String, region: String, session: URLSession? = nil) {
        self.client = .init(baseURL: baseURL, apiKey: key, session: session); self.key = key; self.region = region
    }
    public func translate(_ text: String, to target: String, from source: String) async throws -> String {
        struct Item: Encodable, Sendable { var Text: String }
        struct Response: Decodable, Sendable {
            struct Translation: Decodable, Sendable { var text: String; var to: String }
            var translations: [Translation]
        }
        guard !key.isEmpty else { throw AIError.preparation("请在设置 → AI 配置微软官方翻译密钥和资源区域。") }
        let target = TranslationLanguage.target(for: target).id
        var parts = URLComponents()
        parts.queryItems = [.init(name: "api-version", value: "3.0"), .init(name: "to", value: target)]
        if !source.isEmpty, source != "auto-detect", source != "auto" { parts.queryItems?.append(.init(name: "from", value: source)) }
        var headers = ["Ocp-Apim-Subscription-Key": key]
        if !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["Ocp-Apim-Subscription-Region"] = region
        }
        headers["Authorization"] = ""
        let result: [Response] = try await client.post("/translate?" + (parts.percentEncodedQuery ?? ""),
            body: [Item(Text: text)], response: [Response].self,
            headers: headers)
        guard result.count == 1, let translation = result[0].translations.first,
              !translation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        return translation.text
    }
}

public extension SettingsStore {
    var configuredTranslationEngine: (any TranslationEngine)? {
        if reader.translationEngineID == OfficialTranslationEngine.engineID {
            return OfficialTranslationEngine(baseURL: ai.documentAI.officialTranslationBaseURL,
                key: AICredentialStore.read(account: "azure-translator") ?? "", region: ai.documentAI.officialTranslationRegion)
        }
        guard reader.translationEngineID == LLMTranslation.engineID, let config = translationProvider else { return nil }
        return LLMTranslationEngine(config: config, apiKey: AICredentialStore.read(account: config.keychainAccount) ?? "",
            glossary: reader.translationGlossary)
    }
}

import Foundation

public enum AIModelPurpose: String, CaseIterable, Sendable {
    case chat, translation, vision

    public var label: String {
        switch self {
        case .chat: return "对话"
        case .translation: return "LLM 翻译"
        case .vision: return "识图"
        }
    }
}

public extension AISettings {
    /// Translation never mutates or follows the chat model selection.
    func translationProvider(for reader: ReaderSettings) -> AIProviderConfig? {
        guard let id = reader.translationProviderID,
              var result = providers.first(where: { $0.id == id }),
              !reader.translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        result.selectedModel = reader.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    var visionProvider: AIProviderConfig? {
        guard let id = documentAI.visionProviderID,
              var result = providers.first(where: { $0.id == id }),
              !documentAI.visionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        result.selectedModel = documentAI.visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    var activeReadingMode: AgentConfig? {
        if let saved = agents.first(where: { $0.id == activeAgentID }) { return saved }
        if activeAgentID == AgentConfig.mindMapMode.id { return AgentConfig.mindMapMode }
        return nil
    }
}

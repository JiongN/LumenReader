import Foundation
import Testing
@testable import LumenKit

@Suite("模型用途隔离")
@MainActor
struct ModelPurposeTests {
    private func store() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-purpose-\(UUID()).json")
        let store = SettingsStore(fileURL: url)
        store.suppressSave = true
        return store
    }

    @Test func rolesShareCredentialsButNeverMutateEachOthersModels() throws {
        let store = store()
        let first = AIProviderConfig(name: "One", baseURL: "http://localhost/v1",
            models: ["chat", "translate", "vision"], selectedModel: "chat")
        let second = AIProviderConfig(name: "Two", baseURL: "http://localhost:8080/v1", models: ["second"], selectedModel: "second")
        store.upsertProvider(first)
        store.upsertProvider(second)
        store.selectProvider(id: first.id, for: .translation)
        store.selectProvider(id: first.id, for: .vision)
        store.selectModel("translate", for: .translation)
        store.selectModel("vision", for: .vision)
        store.selectModel("chat-updated", for: .chat)
        #expect(store.activeProvider?.selectedModel == "chat-updated")
        #expect(store.translationProvider?.selectedModel == "translate")
        #expect(store.visionProvider?.selectedModel == "vision")
        #expect(store.visionProvider?.keychainAccount == first.keychainAccount)
        store.selectProvider(id: second.id, for: .chat)
        #expect(store.translationProvider?.selectedModel == "translate")
        #expect(store.visionProvider?.selectedModel == "vision")
        // Picking the already selected service does not reset its role-specific model.
        store.selectProvider(id: first.id, for: .vision)
        #expect(store.visionProvider?.selectedModel == "vision")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(store.settings))
        #expect(restored.ai.visionProvider?.selectedModel == "vision")
        #expect(restored.ai.translationProvider(for: restored.reader)?.selectedModel == "translate")
        store.removeProvider(id: first.id)
        #expect(store.visionProvider == nil)
        #expect(store.translationProvider == nil)
        #expect(store.activeProvider?.selectedModel == "second")
    }

    @Test func legacyVisionAndTranslationSelectionsArePinnedOnce() throws {
        let id = UUID()
        let json = """
        {"ai":{"providers":[{"id":"\(id)","name":"Legacy","baseURL":"http://localhost/v1",
        "models":["old"],"selectedModel":"old"}],"activeProviderID":"\(id)",
        "documentAI":{"visionProviderID":"\(id)"}}}
        """
        var restored = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(restored.ai.visionProvider?.selectedModel == "old")
        #expect(restored.ai.translationProvider(for: restored.reader)?.selectedModel == "old")
        restored.ai.providers[0].selectedModel = "new-chat"
        let restarted = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(restored))
        #expect(restarted.ai.visionProvider?.selectedModel == "old")
        #expect(restarted.ai.translationProvider(for: restarted.reader)?.selectedModel == "old")
        #expect(restarted.ai.providers[0].selectedModel == "new-chat")
    }

    @Test func unsetVisionDoesNotFallBackToChatAndCatalogRefreshKeepsAssignments() {
        let store = store()
        let provider = AIProviderConfig(name: "Local", baseURL: "http://localhost/v1", models: ["chat"], selectedModel: "chat")
        store.upsertProvider(provider)
        #expect(store.visionProvider == nil)
        store.selectProvider(id: provider.id, for: .vision)
        store.selectModel("manual-vision-id", for: .vision)
        store.settings.ai.providers[0].models = ["different-catalog"]
        #expect(store.visionProvider?.selectedModel == "manual-vision-id")
        #expect(store.activeProvider?.selectedModel == "chat")
        store.selectModel("", for: .vision)
        #expect(store.visionProvider == nil)
    }

    @Test func explicitlyUnconfiguredRolesStayUnconfiguredAfterRestart() throws {
        let store = store()
        let provider = AIProviderConfig(name: "Local", baseURL: "http://localhost/v1", models: ["chat"], selectedModel: "chat")
        store.upsertProvider(provider)
        store.selectProvider(id: provider.id, for: .vision)
        store.selectProvider(id: provider.id, for: .translation)
        store.selectProvider(id: nil, for: .vision)
        store.selectProvider(id: nil, for: .translation)
        let restarted = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(store.settings))
        #expect(restarted.ai.visionProvider == nil)
        #expect(restarted.ai.translationProvider(for: restarted.reader) == nil)
    }
}

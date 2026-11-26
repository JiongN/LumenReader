import AppKit
import SwiftUI
import Testing
import LumenKit
@testable import LumenApp

@Suite("服务商编辑绑定生命周期", .serialized)
@MainActor
struct AIProviderBindingTests {
    private func provider(_ name: String) -> AIProviderConfig {
        AIProviderConfig(name: name, baseURL: "https://example.invalid/v1", models: ["test"], selectedModel: "test")
    }

    @Test func removedLastProviderAllowsLateTextFieldReadAndIgnoresWrite() throws {
        let original = provider("A")
        var values = [original]
        let source = Binding(get: { values }, set: { values = $0 })
        let editor = try #require(AIProviderBinding.make(in: source, id: original.id))
        let name = editor.name
        let url = editor.baseURL
        values.removeAll()
        #expect(name.wrappedValue == original.name)
        #expect(url.wrappedValue == original.baseURL)
        name.wrappedValue = "late commit"
        editor.models.wrappedValue.append("late model")
        #expect(values.isEmpty)
        #expect(AIProviderBinding.make(in: source, id: original.id) == nil)
    }

    @Test func deletingEarlierProviderAndReorderingKeepEditingTheSameIdentity() throws {
        let a = provider("A"), b = provider("B"), c = provider("C")
        var values = [a, b, c]
        let source = Binding(get: { values }, set: { values = $0 })
        let editor = try #require(AIProviderBinding.make(in: source, id: b.id))
        values.removeFirst()
        #expect(editor.name.wrappedValue == "B")
        editor.name.wrappedValue = "B edited"
        #expect(values[0].name == "B edited")
        #expect(values[1] == c)
        values.reverse()
        editor.baseURL.wrappedValue = "https://new.invalid/v1"
        #expect(values[1].baseURL == "https://new.invalid/v1")
        #expect(values[0] == c)
    }

    @Test func removedProviderCannotOverwriteItsReplacementOrResurrect() throws {
        let a = provider("A"), b = provider("B")
        var values = [a, b]
        let source = Binding(get: { values }, set: { values = $0 })
        let editor = try #require(AIProviderBinding.make(in: source, id: a.id))
        values.removeFirst()
        editor.name.wrappedValue = "stale A"
        #expect(values == [b])
        values = [provider("Replacement")]
        let replacement = values
        editor.selectedModel.wrappedValue = "stale model"
        #expect(values == replacement)
    }

    @Test func liveUpdatesAreReadAndWritesPreserveOtherFields() throws {
        let a = provider("A")
        var values = [a]
        let source = Binding(get: { values }, set: { values = $0 })
        let editor = try #require(AIProviderBinding.make(in: source, id: a.id))
        values[0].maxTokens = 8192
        values[0].name = "external update"
        #expect(editor.name.wrappedValue == "external update")
        editor.name.wrappedValue = "typed name"
        #expect(values[0].maxTokens == 8192)
        #expect(values[0].name == "typed name")
        editor.wrappedValue = provider("wrong identity")
        #expect(values[0].id == a.id)
        #expect(values[0].name == "typed name")
    }
    @Test func nativeSettingsFormSurvivesFocusedProviderDeletion() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        store.suppressSave = true
        let a = provider("Synthetic A"), b = provider("Synthetic B")
        store.settings.ai.providers = [a, b]
        store.settings.ai.activeProviderID = b.id
        let view = AISettingsPane()
            .environmentObject(AppState())
            .environmentObject(store)
            .environmentObject(MemoryStore(fileURL: directory.appendingPathComponent("memory.json")))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 780, height: 900),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        func textFields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields($0) }
        }
        let name = try #require(textFields(host).first { $0.stringValue == "Synthetic B" && $0.isEditable })
        #expect(window.makeFirstResponder(name))
        store.removeProvider(id: a.id) // the focused B moves from index 1 to index 0
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(store.settings.ai.providers.map(\.id) == [b.id])
        store.removeProvider(id: b.id) // old TextField callbacks may still run
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(store.settings.ai.providers.isEmpty)
        if let output = ProcessInfo.processInfo.environment["LUMEN_BINDING_SCREENSHOT"],
           let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
    }

}

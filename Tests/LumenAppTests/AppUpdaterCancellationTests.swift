import Foundation
import Testing
import LumenKit
@testable import LumenApp

@MainActor
struct AppUpdaterCancellationTests {
    @Test func cancellingReturnsToAvailableAndIgnoresOldCompletion() async throws {
        let name = "LumenUpdaterTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let updater = AppUpdater(defaults: defaults)
        let first = UpdateInfo(version: AppVersion(major: 8, minor: 0, patch: 0), tagName: "v8.0.0",
                               htmlURL: "", downloadURL: nil, releaseNotes: "")
        let second = UpdateInfo(version: AppVersion(major: 9, minor: 0, patch: 0), tagName: "v9.0.0",
                                htmlURL: "", downloadURL: nil, releaseNotes: "")

        updater.install(first)
        #expect(updater.busy)
        updater.cancel()
        #expect(updater.phase == .available(first))
        #expect(!updater.busy)
        updater.install(second)
        updater.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(updater.phase == .available(second))
        #expect(!updater.busy)
    }
}

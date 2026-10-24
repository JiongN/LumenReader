import Foundation
import Testing
import LumenKit

struct RegenerableCachePolicyTests {
    @Test func expiresOnlyPassedFilesHonorsPinnedFilesAndCapacity() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.json"), fresh = dir.appendingPathComponent("fresh.json")
        let pinned = dir.appendingPathComponent("active.json"), original = dir.appendingPathComponent("annotations.json")
        for file in [old, fresh, pinned, original] { try Data(repeating: 65, count: 100).write(to: file) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-1000)], ofItemAtPath: old.path)
        RegenerableCachePolicy.prune(files: [old, fresh, pinned], maximumBytes: 200, maximumAge: 100, keeping: [pinned])
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: pinned.path))
        #expect(fm.fileExists(atPath: original.path))
        RegenerableCachePolicy.prune(files: [fresh, pinned], maximumBytes: 100, maximumAge: 100, keeping: [pinned])
        #expect(!fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: pinned.path))
    }
}

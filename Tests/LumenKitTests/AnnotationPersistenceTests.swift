import Foundation
import Testing
@testable import LumenKit

@Suite struct AnnotationPersistenceTests {
    private func item(_ id: String) -> AnnotationItem {
        .init(id: id, locator: .epub(chapterIndex: 0, anchor: "", charOffset: 0), quote: id,
              note: "正文\n[[知识]]", hasHighlight: true, createdAt: .distantPast)
    }
    @Test func anotherWindowCannotReplaceNewerAnnotationsWithStaleArchive() throws {
        let path = "/fixture/\(UUID()).epub"
        defer { try? FileManager.default.removeItem(at: AppPaths.documentDirectory(forPath: path)) }
        let first = AnnotationStore(documentPath: path)
        let second = AnnotationStore(documentPath: path)
        #expect(first.add(item("first")))
        let bytes = try Data(contentsOf: first.fileURL)
        #expect(!second.add(item("second")))
        #expect(second.items.isEmpty)
        #expect(try Data(contentsOf: first.fileURL) == bytes)
        let fresh = AnnotationStore(documentPath: path)
        #expect(fresh.add(item("second")))
        #expect(fresh.items.map(\.id) == ["first", "second"])
    }
    @Test func unreadableExistingFileAndEmptyCorruptionPreserveOriginals() throws {
        let path = "/fixture/\(UUID()).epub"
        let folder = AppPaths.documentDirectory(forPath: path)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = AppPaths.annotationsFile(forPath: path)
        try Data().write(to: file)
        let recovered = AnnotationStore(documentPath: path)
        #expect(recovered.add(item("recovered")))
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("annotations.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)).isEmpty)
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let unreadable = AnnotationStore(documentPath: path)
        #expect(!unreadable.add(item("must not replace")))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }
}

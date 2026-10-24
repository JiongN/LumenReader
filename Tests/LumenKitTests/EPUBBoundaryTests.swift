import Testing
import Foundation
@testable import LumenKit

@Suite("EPUB 资源边界与目录")
struct EPUBBoundaryTests {
    @Test func extractionCacheReopensAndTracksSubsecondChanges() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let book = directory.appendingPathComponent("book")
        try manager.createDirectory(at: book.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        var extracted: Set<URL> = []
        defer {
            try? manager.removeItem(at: directory)
            for root in extracted { try? manager.removeItem(at: root) }
        }
        let container = #"<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>"#
        let package = #"<package><metadata><title>Cache test</title></metadata><manifest><item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>"#
        try Data(container.utf8).write(to: book.appendingPathComponent("META-INF/container.xml"))
        try Data(package.utf8).write(to: book.appendingPathComponent("book.opf"))
        try Data("<html><body><h1>Chapter</h1><p>完整内容。</p></body></html>".utf8).write(to: book.appendingPathComponent("chapter.xhtml"))
        let archive = directory.appendingPathComponent("book.epub")
        try await Task.detached {
            try EPUBExtractionProcess.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-c", "-k", book.path, archive.path])
        }.value
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.1)], ofItemAtPath: archive.path)
        let first = try await EPUBDocumentSource.open(url: archive)
        extracted.insert(first.rootURL)
        let reopened = try await EPUBDocumentSource.open(url: archive)
        #expect(reopened.rootURL == first.rootURL)
        #expect(first.fullText() == reopened.fullText())
        #expect(first.fullText().contains("完整内容。"))
        #expect(first.text(around: .epub(chapterIndex: Int.max, anchor: "", charOffset: 0), radius: 1).isEmpty)
        #expect(first.text(around: .epub(chapterIndex: 0, anchor: "", charOffset: 0), radius: Int.min).isEmpty)
        #expect(first.text(around: .epub(chapterIndex: 0, anchor: "", charOffset: 0), radius: Int.max) == first.fullText())
        #expect(first.search("内容", limit: 0).isEmpty)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.9)], ofItemAtPath: archive.path)
        let changed = try await EPUBDocumentSource.open(url: archive)
        extracted.insert(changed.rootURL)
        #expect(changed.rootURL != first.rootURL)
        #expect(changed.fullText() == first.fullText())
    }

    @Test func rejectsEscapesAndAllowsInBookParentPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = root.appendingPathComponent("OPS/Text")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try EPUBDocumentSource.resourceURL("../Images/a%20b.png", relativeTo: base, root: root)
        #expect(valid.lastPathComponent == "a b.png")
        for path in ["../../../outside.txt", "%2E%2E/%2E%2E/%2E%2E/outside", "/etc/passwd", "https://example.com"] {
            #expect(throws: EPUBError.self) {
                try EPUBDocumentSource.resourceURL(path, relativeTo: base, root: root)
            }
        }
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        #expect(throws: EPUBError.self) {
            try EPUBDocumentSource.resourceURL("escape/outside", relativeTo: base, root: root)
        }
    }
    @Test func nestedTOCResolvesRelativeToNavigationFile() {
        let base = URL(fileURLWithPath: "/book/OPS")
        let nav = base.appendingPathComponent("Navigation/nav.xhtml")
        #expect(EPUBDocumentSource.navigationHref("../Text/chapter%202.xhtml#section", from: nav, relativeTo: base) == "Text/chapter 2.xhtml#section")
    }
    @Test func versionRejectsEmptyOrSignedComponents() {
        for value in ["1..2", "1.", ".1", "+1.2.3", "1.+2.3"] {
            #expect(AppVersion(parsing: value) == nil)
        }
    }
}

@Suite("EPUB ZIP 预检")
struct EPUBArchiveTests {
    private func entry(_ name: String, mode: UInt32 = 0x81a4, size: UInt32 = 1) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 46)
        func put(_ value: UInt32, at i: Int, count: Int) {
            for n in 0..<count { b[i+n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
        }
        put(0x02014b50, at: 0, count: 4)
        put(size, at: 24, count: 4)
        put(UInt32(name.utf8.count), at: 28, count: 2)
        put(mode << 16, at: 38, count: 4)
        return b + Array(name.utf8)
    }
    @Test func acceptsOrdinaryFiles() throws {
        try EPUBArchiveSafety.validateDirectory(entry("OPS/chapter.xhtml"), entryCount: 1)
    }
    @Test func rejectsMaliciousAndTruncatedEntries() {
        for bytes in [entry("../escape"), entry("/absolute"), entry("OPS/link", mode: 0xa1ff),
                      entry("huge", size: 600 * 1024 * 1024), Array(entry("ok").dropLast())] {
            #expect(throws: EPUBError.self) {
                try EPUBArchiveSafety.validateDirectory(bytes, entryCount: 1)
            }
        }
        #expect(throws: EPUBError.self) {
            try EPUBArchiveSafety.validateDirectory(entry("A") + entry("a"), entryCount: 2)
        }
    }
}

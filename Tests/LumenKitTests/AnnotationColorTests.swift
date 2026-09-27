import Foundation
import Testing
@testable import LumenKit

@Suite("EPUB 批注颜色兼容")
struct AnnotationColorTests {
    @Test func oldArchiveWithoutColorStillDecodes() throws {
        let json = """
        {"items":[{"id":"old","locatorKey":"epub:0::0","quote":"text","note":"",
        "hasHighlight":true,"createdAt":0}]}
        """
        let archive = try JSONDecoder().decode(AnnotationArchive.self, from: Data(json.utf8))
        #expect(archive.items.count == 1)
        #expect(archive.items[0].highlightHex == nil)
    }

    @Test func colorRoundTrips() throws {
        let source = AnnotationArchive(items: [StoredAnnotation(id: "new", locatorKey: "epub:0::0",
            quote: "text", note: "", hasHighlight: true, createdAt: .now,
            highlightHex: "#64B5F6")])
        let decoded = try JSONDecoder().decode(AnnotationArchive.self,
            from: JSONEncoder().encode(source))
        #expect(decoded.items[0].highlightHex == "#64B5F6")
    }
}

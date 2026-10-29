import Foundation
import Testing
import LumenKit
@testable import LumenApp

@Suite("社科 PDF 目录回归", .serialized)
struct SmartOutlineSocialRegressionTests {
    @Test func nonprintingSeparatorIsNotAMissingPageButBrokenGlyphStillIs() {
        #expect(PDFSmartOutlineSource.cleanedOutlineText("References\u{3}\nAuthors") == "References\nAuthors")
        #expect(TextLayerTrust.needsVisualCheck(PDFSmartOutlineSource.cleanedOutlineText("bad\u{FFFD}font")))
        #expect(PDFSmartOutlineSource.cleanedOutlineText("\u{0}\u{3}").isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUMEN_SOCIAL_OUTLINE_DIR"] != nil))
    func realScannedPaperKeepsSmallCapitalHeadings() async throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_SOCIAL_OUTLINE_DIR"]!
        let source = try await Task.detached {
            try PDFSmartOutlineSource.read(url: URL(fileURLWithPath: root + "/The Strength of Weak Ties.pdf"), cachedOCR: [:])
        }.value
        #expect(source.missingUnits.isEmpty)
        for (title, page) in [("THE STRENGTH OF TIES", 2), ("WEAK TIES IN DIFFUSION PROCESSES", 4), ("CONCLUSION", 18), ("REFERENCES", 19)] {
            #expect(source.candidates.contains { $0.title == title && $0.unitIndex == page })
        }
        #expect(!source.candidates.contains { $0.title == "The Strength of Weak Ties" && $0.unitIndex > 1 })
        for c in source.candidates { print("[social scanned] \(c.unitIndex+1) \(c.title)") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUMEN_SOCIAL_OUTLINE_DIR"] != nil))
    func realNativePaperWithControlCharacterRetainsAllPages() async throws {
        let root = ProcessInfo.processInfo.environment["LUMEN_SOCIAL_OUTLINE_DIR"]!
        let source = try await Task.detached {
            try PDFSmartOutlineSource.read(url: URL(fileURLWithPath: root + "/Social Media and Fake News in the 2016 Election.pdf"), cachedOCR: [:])
        }.value
        #expect(source.unitCount == 26)
        #expect(source.missingUnits.isEmpty)
        #expect(source.candidates.contains { $0.title == "Background: The Market for Fake News" && $0.unitIndex == 2 })
        #expect(source.candidates.contains { $0.title == "References" && $0.unitIndex == 22 })
        for c in source.candidates { print("[social native] \(c.unitIndex+1) \(c.title)") }
    }
}

import Foundation
import Testing
@testable import LumenApp

@Suite("系统翻译会话刷新")
struct AppleTranslationConfigurationTests {
    @Test func everyRequestChangesConfiguration() {
        let first = AppleTranslationConfiguration.next(nil, source: "en", target: "zh-Hans")
        let second = AppleTranslationConfiguration.next(first, source: "en", target: "zh-Hans")
        let third = AppleTranslationConfiguration.next(second, source: "en", target: "zh-Hans")
        #expect(first.source == Locale.Language(identifier: "en"))
        #expect(first != second)
        #expect(second != third)
        #expect(third.version == first.version + 2)
        let changed = AppleTranslationConfiguration.next(third, source: "zh-Hans", target: "en")
        #expect(changed != third)
        #expect(changed.target == Locale.Language(identifier: "en"))
        #expect(changed.source == Locale.Language(identifier: "zh-Hans"))
        #expect(AppleTranslationConfiguration.next(changed, source: "zh-Hans", target: "en") != changed)
        #expect(AppleTranslationConfiguration.next(changed, source: "de", target: "en").source == Locale.Language(identifier: "de"))
    }

    @Test func languageComesFromConnectedProseNotAKeyword() async throws {
        let resolver = TranslationSourceResolver()
        #expect(try await resolver.resolve(texts: ["KEYWORDS", "curriculum; construction", "Using the notion of risk aversion, this study explores the decisions teachers make when constructing a curriculum."]) == "en")
        #expect(try await resolver.resolve(texts: ["这篇研究主要讨论教师如何设计课程，以及他们在教育改革过程中如何作出教学决策。学校的制度和评价方式对这些决策具有重要影响。"], pdfPath: nil) == "zh-Hans")
        #expect(try await resolver.resolve(texts: ["Die Untersuchung beschäftigt sich mit den Entscheidungen, die Lehrkräfte bei der Entwicklung eines Lehrplans treffen."]) == "de")
        #expect(try await resolver.resolve(texts: ["1234 / 5678", "—"]) == nil)
    }

    @Test func longDocumentsUseRepresentativeParagraphVotes() async throws {
        let resolver = TranslationSourceResolver()
        let english = "Using the notion of risk aversion, this study explores the decisions teachers make when constructing a curriculum. The findings show that teachers largely adopt a low-risk approach when constructing a curriculum. "
        #expect(try await resolver.resolve(texts: (0..<20).map { _ in String(repeating: english, count: 10) }) == "en")
        let german = "Die Untersuchung beschäftigt sich mit den Entscheidungen, die Lehrkräfte bei der Entwicklung eines Lehrplans treffen. Die Ergebnisse zeigen, dass Lehrkräfte meist einen risikoarmen Ansatz für die Gestaltung des Unterrichts wählen. "
        #expect(try await resolver.resolve(texts: [english] + (0..<7).map { _ in String(repeating: german, count: 5) }) == "de")
    }
}

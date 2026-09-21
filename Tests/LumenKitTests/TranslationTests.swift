import Testing
@testable import LumenKit

@Suite("PDF 段落翻译基础")
struct TranslationTests {

    @Test("默认优先 Apple 系统翻译，保留微软后备")
    func engineCatalog() {
        #expect(TranslationEngineCatalog.defaultID == AppleSystemTranslation.engineID)
        #expect(TranslationEngineCatalog.all.map(\.id) == [
            AppleSystemTranslation.engineID,
            MicrosoftTranslationEngine.engineID,
            LLMTranslation.engineID,
        ])
        #expect(TranslationEngineCatalog.engine(for: AppleSystemTranslation.engineID) == nil)
        #expect(TranslationEngineCatalog.engine(for: MicrosoftTranslationEngine.engineID) != nil)
        #expect(TranslationEngineCatalog.engine(for: LLMTranslation.engineID) == nil)
    }

}

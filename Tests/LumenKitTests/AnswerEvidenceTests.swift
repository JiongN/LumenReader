import Foundation
import Testing
import LumenKit

struct AnswerEvidenceTests {
    private func document(_ path: String = "/one.pdf") -> DocumentContext {
        .init(version: "v1", path: path, evidence: [
            .init(id: "p0", path: path, label: "第 1 页", locator: .pdf(page: 0, charOffset: 0),
                  text: "The source explains why evidence matters.\nAnother sentence follows.",
                  pdfFragments: [.init(pageIndex: 0, bounds: CGRect(x: 20, y: 40, width: 200, height: 30))])
        ], unitCount: 1)
    }

    private func reply(id: String, quote: String, number: Int = 1) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["citations": [["number": number, "id": id, "quote": quote]]])
        return "依据原文说明 [原文\(number)]\n<!-- lumen-evidence: \(String(decoding: data, as: UTF8.self)) -->"
    }

    @Test func exactQuoteResolvesWithVersionAndGeometryAndSurvivesCoding() throws {
        let doc = document(), evidence = document().evidence[0]
        let result = AnswerEvidence.resolve(try reply(id: evidence.citationID, quote: "why evidence matters."),
            documents: [doc], supplied: doc.evidence)
        #expect(result.answer == "依据原文说明 [原文1]")
        #expect(result.citations.count == 1)
        let source = try #require(result.citations.first)
        #expect(source.version == "v1")
        #expect(source.quote == "why evidence matters.")
        #expect(source.pdfFragments == evidence.pdfFragments)
        #expect(try JSONDecoder().decode(DocumentCitation.self, from: JSONEncoder().encode(source)) == source)
    }

    @Test func fabricatedQuoteOrUnsentMaterialDoesNotBecomeNavigationTarget() throws {
        let doc = document(), id = doc.evidence[0].citationID
        #expect(AnswerEvidence.resolve(try reply(id: id, quote: "This was never said."), documents: [doc], supplied: doc.evidence).citations.isEmpty)
        #expect(AnswerEvidence.resolve(try reply(id: id, quote: "why evidence matters."), documents: [doc], supplied: []).citations.isEmpty)
        #expect(AnswerEvidence.resolve(try reply(id: "wrong", quote: "why evidence matters."), documents: [doc], supplied: doc.evidence).citations.isEmpty)
    }

    @Test func copiedInstructionPrefixStillRequiresExactSourceAndQuote() throws {
        let doc = document(), id = doc.evidence[0].citationID
        #expect(AnswerEvidence.resolve(try reply(id: "COPY " + id, quote: "why evidence matters."),
            documents: [doc], supplied: doc.evidence).citations.count == 1)
        #expect(AnswerEvidence.resolve(try reply(id: "COPY " + id, quote: "This was never said."),
            documents: [doc], supplied: doc.evidence).citations.isEmpty)
        #expect(AnswerEvidence.resolve(try reply(id: "COPY wrong", quote: "why evidence matters."),
            documents: [doc], supplied: doc.evidence).citations.isEmpty)
        #expect(AnswerEvidence.resolve(try reply(id: "COPY " + id, quote: "why evidence matters."),
            documents: [doc], supplied: []).citations.isEmpty)
    }

    @Test func followupRetainsEvidenceRequirementAfterVisibleHistory() {
        let messages = PromptLibrary.messages(task: .ask(question: "继续说明"), selection: nil, metadata: .init(),
            locatorLabel: "全文", context: document().text, memory: "",
            history: [.user("旧问题"), .assistant("旧回答 [原文1]")], evidenceInstruction: AnswerEvidence.instruction)
        #expect(messages.first?.content.contains(AnswerEvidence.instruction) == true)
        #expect(messages.last?.content.contains("Required: append lumen-evidence") == true)
        #expect(messages.last?.content.contains("继续说明") == true)
        #expect(messages.filter { $0.content.contains(document().text) }.count == 1)
    }

    @Test func sameParagraphIDInTwoDocumentsDoesNotCrossLink() throws {
        let a = document(), b = document("/two.pdf")
        let result = AnswerEvidence.resolve(try reply(id: b.evidence[0].citationID, quote: "why evidence matters."),
            documents: [a, b], supplied: a.evidence + b.evidence)
        #expect(result.citations.first?.path == "/two.pdf")
    }

    @Test func suppliedSectionHeaderResolvesOnlyUniqueOriginalQuote() throws {
        let doc = document(), part = try #require(WholeDocumentPlan.parts([document()]).first)
        let header = String(part.header.dropFirst().dropLast())
        let result = AnswerEvidence.resolve(try reply(id: header, quote: "why evidence matters."), documents: [doc], supplied: doc.evidence)
        #expect(result.citations.first?.id == doc.evidence[0].id)
        #expect(result.citations.first?.pdfFragments == doc.evidence[0].pdfFragments)
        #expect(AnswerEvidence.resolve(try reply(id: part.id, quote: "why evidence matters."), documents: [doc], supplied: []).citations.isEmpty)
        var ambiguous = doc
        ambiguous.evidence.append(.init(id: "duplicate", path: doc.path, label: "第 1 页", locator: .pdf(page: 0, charOffset: 40), text: doc.evidence[0].text))
        #expect(AnswerEvidence.resolve(try reply(id: part.id, quote: "why evidence matters."), documents: [ambiguous], supplied: ambiguous.evidence).citations.isEmpty)
        #expect(AnswerEvidence.resolve(try reply(id: "D9S9", quote: "why evidence matters."), documents: [doc], supplied: doc.evidence).citations.isEmpty)
    }

    @Test func sectionRecoveryNeverCrossesDocumentsOrAcceptsWhitespaceQuote() throws {
        var a = document(), b = document("/two.pdf")
        a.evidence[0].text = "Different source with no matching phrase."
        let replyB = try reply(id: "D2S1", quote: "why evidence matters.")
        #expect(AnswerEvidence.resolve(replyB, documents: [a, b], supplied: a.evidence + b.evidence).citations.first?.path == b.path)
        #expect(AnswerEvidence.resolve(try reply(id: "D1S1", quote: "why evidence matters."), documents: [a, b], supplied: a.evidence + b.evidence).citations.isEmpty)
        #expect(AnswerEvidence.resolve(try reply(id: b.evidence[0].citationID, quote: "        "), documents: [b], supplied: b.evidence).citations.isEmpty)
    }

    @Test func protocolIsHiddenAndCompatibleWithWholeCoverage() throws {
        let doc = document()
        let text = try reply(id: doc.evidence[0].citationID, quote: "matters. Another sentence")
        let resolved = AnswerEvidence.resolve(text + "\n<!-- lumen-coverage: {\"sections\":[\"D1S1\"]} -->",
            documents: [doc], supplied: doc.evidence)
        #expect(resolved.citations.count == 1)
        #expect(try WholeAnswerCoverage.validatedAnswer(resolved.answer, ids: ["D1S1"], mindMap: false) == "依据原文说明 [原文1]")
        #expect(WholeAnswerCoverage.visibleAnswer("正文\n<!-- lumen-evidence: {broken") == "正文")
    }

    @Test func legacyCitationMissingNewFieldsRemainsReadable() throws {
        let citation = DocumentCitation(evidence: document().evidence[0], version: "v1")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(citation)) as? [String: Any])
        json.removeValue(forKey: "pdfFragments")
        let restored = try JSONDecoder().decode(DocumentCitation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.quote == nil)
        #expect(restored.pdfFragments == nil)
    }
}

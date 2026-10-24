import Foundation
import Testing
@testable import LumenKit

@Suite("统一阅读方式")
struct ReadingModeTests {
    @Test func editedUnselectedBuiltinTemplateRemainsAccessible() {
        var settings = AISettings()
        settings.readingModeRevision = 0
        settings.templates[0].systemPrompt = "保留我的改写"
        settings.migrateReadingModes()
        #expect(settings.agents.contains { $0.persona.contains("保留我的改写") })
        #expect(settings.activeAgentID == nil)
    }

    @Test func selectedTemplateAndAgentBecomeOneReversibleChoice() throws {
        var old = AISettings()
        old.readingModeRevision = 0
        old.skillLibrary = AgentSkill.legacyCatalog
        let template = PromptTemplate(name: "我的读法", systemPrompt: "只用简短句子。", instruction: "检查限定条件。")
        old.templates = [template]
        old.activeTemplateID = template.id
        old.agents = [.init(id: "mine", name: "审读", persona: "区分事实和推断。", skills: ["argumentChain", "counterArgument"])]
        old.activeAgentID = "mine"
        old.migrateReadingModes()
        let active = try #require(old.agents.first { $0.id == old.activeAgentID })
        #expect(active.persona.contains("只用简短句子。"))
        #expect(active.persona.contains("区分事实和推断。"))
        #expect(active.skills.isEmpty)
        #expect(active.persona.contains("【"))
        #expect(old.activeTemplateID == nil)
        #expect(old.templates == [template])
        #expect(old.readingModeArchive?.activeTemplateID == template.id)
        #expect(old.readingModeArchive?.skills == AgentSkill.legacyCatalog)
        let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(old))
        #expect(decoded == old)
        old.migrateReadingModes()
        #expect(old == decoded)
    }

    @Test func customizedLegacySkillSurvives() {
        var settings = AISettings()
        settings.readingModeRevision = 0
        let custom = AgentSkill(id: "argumentChain", name: "论证链", instruction: "我的独特指令。")
        settings.skillLibrary = [custom]
        settings.agents = [.init(name: "个人阅读", skills: [custom.id])]
        settings.migrateReadingModes()
        #expect(settings.retiredReadingSkills.contains(custom))
        #expect(settings.agents.first?.persona.contains(custom.instruction) == true)
        #expect(settings.agents.first?.skills.isEmpty == true)
    }

    @Test func groundingSurvivesCustomInstructionsAndSkillsAreOptIn() {
        let template = PromptTemplate(name: "自定义", systemPrompt: "特殊阅读要求")
        let base = PromptLibrary.systemPrompt()
        let custom = PromptLibrary.systemPrompt(template: template)
        #expect(custom.contains(base))
        #expect(custom.contains("特殊阅读要求"))
        #expect(AgentSkill.catalog.map(\.id) == [AgentSkill.evidenceID, AgentSkill.chartID, AgentSkill.searchID])
        let agent = AgentConfig(name: "结构梳理", skills: [AgentSkill.evidenceID])
        let selected = PromptLibrary.systemPrompt(agent: agent, skills: AgentSkill.catalog)
        #expect(!selected.contains("lumen-evidence"))
        #expect(!selected.contains("mindmap 代码块"))
        #expect(!base.contains("限定条件与待核查问题"))
    }

    @Test func retiredDiagramSkillIsReplacedOnceAndOriginalIsArchived() throws {
        let original = AgentSkill(id: "mindMap", name: "思维导图", instruction: "保留我的旧导图指令")
        var settings = AISettings()
        settings.readingModeRevision = 1
        settings.skillLibrary = [original]
        settings.agents = [.init(name: "个人阅读", skills: ["mindMap", "evidenceTable"])]
        settings.migrateReadingModes()
        #expect(settings.skillLibrary.map(\.id) == AgentSkill.catalog.map(\.id))
        #expect(settings.agents.first?.skills.isEmpty == true)
        #expect(settings.agents.first?.persona.contains("限定条件与待核查问题") == true)
        #expect(settings.retiredReadingSkills.contains(original))
        let restored = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
        settings.migrateReadingModes()
        #expect(settings == restored)
    }

    @Test func evidenceCapabilityIsOptInAndMigrationDoesNotDuplicateInstructions() {
        var settings = AISettings()
        #expect(settings.agents.allSatisfy { !$0.skills.contains(AgentSkill.evidenceID) })
        settings.readingModeRevision = 2
        settings.skillLibrary = AgentSkill.catalog + AgentSkill.retiredPromptCatalog
        settings.agents = [.init(name: "我的读法", skills: [AgentSkill.evidenceID, "critique"])]
        settings.migrateReadingModes()
        #expect(settings.agents.first?.skills == [AgentSkill.evidenceID])
        let migrated = settings
        settings.migrateReadingModes()
        #expect(settings == migrated)
    }
}

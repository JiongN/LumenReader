import Foundation

public struct ReadingModeArchive: Codable, Sendable, Equatable {
    public var agents: [AgentConfig]
    public var skills: [AgentSkill]
    public var activeAgentID: String?
    public var activeTemplateID: UUID?
}

public extension AISettings {
    mutating func migrateReadingModes() {
        guard readingModeRevision < 1 else { migrateDiagramSkill(); migrateCapabilitySkills(); migrateDocumentSkills(); return }
        readingModeArchive = .init(agents: agents, skills: skillLibrary,
            activeAgentID: activeAgentID, activeTemplateID: activeTemplateID)
        let originalSkills = skillLibrary
        let unchanged = Set(originalSkills.filter { skill in
            AgentSkill.legacyCatalog.contains { $0 == skill }
        }.map(\.id))
        let aliases = ["termShift": "concepts", "argumentChain": "critique", "counterArgument": "critique"]
        skillLibrary.removeAll { unchanged.contains($0.id) }
        for skill in AgentSkill.retiredPromptCatalog where !originalSkills.isEmpty && !skillLibrary.contains(where: { $0.id == skill.id }) {
            skillLibrary.append(skill)
        }
        for index in agents.indices {
            let old = agents[index].skills
            if old.contains("socratic"), unchanged.contains("socratic") {
                agents[index].persona += "\n用 2–4 个递进问题引导读者，不先给出完整结论。"
            }
            if old.contains("plainLanguage"), unchanged.contains("plainLanguage") {
                agents[index].persona += "\n用日常语言表达，必要术语给一句简短解释。"
            }
            if old.contains("writableParagraph"), unchanged.contains("writableParagraph") {
                agents[index].persona += "\n将阅读所得组织为主题句、证据与限定条件。"
            }
            var ids: [String] = []
            for id in old {
                let replacement = unchanged.contains(id) ? (aliases[id] ?? AgentSkill.retiredPromptCatalog.first { $0.id == id }?.id) : id
                if let replacement, skillLibrary.contains(where: { $0.id == replacement }), !ids.contains(replacement) {
                    ids.append(replacement)
                }
            }
            agents[index].skills = ids
        }
        for template in templates where !template.isBuiltIn || template.id == activeTemplateID || !PromptTemplate.presets.contains(template) {
            let id = "template-" + template.id.uuidString
            if !agents.contains(where: { $0.id == id }) {
                agents.append(.init(id: id, name: template.name,
                    persona: [template.systemPrompt, template.instruction].filter { !$0.isEmpty }.joined(separator: "\n")))
            }
        }
        if let templateID = activeTemplateID,
           let template = templates.first(where: { $0.id == templateID }) {
            let importedID = "template-" + templateID.uuidString
            if let index = agents.firstIndex(where: { $0.id == activeAgentID }) {
                var combined = agents[index]
                combined.id = "combined-" + templateID.uuidString + "-" + combined.id
                combined.name = template.name + " · " + combined.name
                combined.isBuiltIn = false
                combined.persona = [template.systemPrompt, template.instruction, combined.persona]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                agents.append(combined)
                activeAgentID = combined.id
            } else { activeAgentID = importedID }
        }
        activeTemplateID = nil
        readingModeRevision = 1
        migrateDiagramSkill()
        migrateCapabilitySkills()
        migrateDocumentSkills()
    }

    private mutating func migrateDiagramSkill() {
        guard readingModeRevision < 2 else { return }
        let retired = skillLibrary.filter { $0.id == "mindMap" }
        retiredReadingSkills.append(contentsOf: retired.filter { !retiredReadingSkills.contains($0) })
        skillLibrary.removeAll { $0.id == "mindMap" }
        if !retired.isEmpty, !skillLibrary.contains(where: { $0.id == "evidenceTable" }),
           let replacement = AgentSkill.retiredPromptCatalog.first(where: { $0.id == "evidenceTable" }) {
            skillLibrary.append(replacement)
        }
        for index in agents.indices {
            var seen = Set<String>()
            agents[index].skills = agents[index].skills.map { $0 == "mindMap" ? "evidenceTable" : $0 }
                .filter { seen.insert($0).inserted }
        }
        readingModeRevision = 2
    }

    private mutating func migrateCapabilitySkills() {
        guard readingModeRevision < 3 else { return }
        let old = skillLibrary.filter { $0.id != AgentSkill.evidenceID }
        retiredReadingSkills.append(contentsOf: old.filter { !retiredReadingSkills.contains($0) })
        for index in agents.indices {
            let instructions = agents[index].skills.compactMap { id -> String? in
                guard let skill = old.first(where: { $0.id == id }), !skill.instruction.isEmpty else { return nil }
                return "【\(skill.name)】\(skill.instruction)"
            }
            if !instructions.isEmpty {
                agents[index].persona = ([agents[index].persona] + instructions).filter { !$0.isEmpty }.joined(separator: "\n")
            }
            agents[index].skills.removeAll { $0 != AgentSkill.evidenceID }
        }
        skillLibrary = AgentSkill.catalog
        readingModeRevision = 3
    }

    private mutating func migrateDocumentSkills() {
        guard readingModeRevision < 4 else { return }
        for skill in AgentSkill.catalog where !skillLibrary.contains(where: { $0.id == skill.id }) { skillLibrary.append(skill) }
        for index in agents.indices where agents[index].usesWebSearch {
            if !agents[index].skills.contains(AgentSkill.searchID) { agents[index].skills.append(AgentSkill.searchID) }
            agents[index].usesWebSearch = false
        }
        readingModeRevision = 4
    }
}

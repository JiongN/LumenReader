import SwiftUI
import LumenKit

/// Agent 编辑器。
///
/// 与提示词编辑器同样的取舍：独立 sheet、编辑副本、保存才写回。
/// 差别在于这里编辑的是**三件事**——角色设定、技能勾选、要不要联网，
/// 它们的组合很多，所以表单要能一眼看全，而不是让人翻页。
///
/// 关于联网检索，界面上把话说全：走的是 Crossref / Semantic Scholar / arXiv，
/// 知网、万方、Web of Science 没有可用的公开接口。写在按钮旁边，
/// 而不是等人用了发现没有知网再来问——那种失望比少一个功能更伤。
struct AgentEditor: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var editing: AgentConfig?
    @State private var isNew = false

    private var agents: [AgentConfig] { state.settingsStore.ai.agents }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Palette.separator)
            form
            Divider().overlay(DS.Palette.separator)
            footer
        }
        .frame(width: 620, height: 560)
        .background(DS.Palette.surfaceSunken)
        .onAppear(perform: loadInitial)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text("Agent")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Palette.textPrimary)

            Spacer(minLength: 0)

            Menu {
                ForEach(agents) { agent in
                    Button(agent.name) { load(agent) }
                }
                Divider()
                Button("新建 Agent") { startNew() }
            } label: {
                Text(editing?.name ?? "选择 Agent")
                    .font(DS.Typo.ui(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: DS.Size.toolbarHeight)
    }

    // MARK: - 表单

    @ViewBuilder
    private var form: some View {
        if let binding = Binding($editing) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    field("名称") {
                        TextField("Agent 名称", text: binding.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("角色设定") {
                        editor(text: binding.persona, minHeight: 110)
                    }

                    field("技能") {
                        skillGrid(binding.skills)
                    }

                    field("联网检索文献") {
                        webSearchToggle(binding.usesWebSearch)
                    }

                    explanation
                }
                .padding(DS.Space.l)
            }
        } else {
            Text("没有可编辑的 Agent")
                .font(DS.Typo.body)
                .foregroundStyle(DS.Palette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(DS.Typo.ui(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
            content()
        }
    }

    private func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(DS.Typo.ui(size: 12))
            .scrollContentBackground(.hidden)
            .padding(DS.Space.s)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(DS.Palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
            )
    }

    /// 技能勾选。两列平铺而不是下拉多选：
    /// 「有哪些技能可用」本身就是用户需要看到的信息，藏进下拉等于让人先猜再找。
    private func skillGrid(_ selection: Binding<[AgentSkill]>) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s), GridItem(.flexible(), spacing: DS.Space.s)],
                  spacing: DS.Space.xs) {
            ForEach(AgentSkill.allCases) { skill in
                let isOn = selection.wrappedValue.contains(skill)
                Button {
                    var current = selection.wrappedValue
                    if let index = current.firstIndex(of: skill) {
                        current.remove(at: index)
                    } else {
                        current.append(skill)
                    }
                    selection.wrappedValue = current
                } label: {
                    HStack(alignment: .top, spacing: DS.Space.xs) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(DS.Typo.ui(size: 11, weight: .semibold))
                            .foregroundStyle(isOn ? DS.Palette.accent : DS.Palette.textTertiary)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(skill.title)
                                .font(DS.Typo.ui(size: 11.5, weight: .medium))
                                .foregroundStyle(DS.Palette.textPrimary)
                            Text(skill.detail)
                                .font(DS.Typo.ui(size: 10.5))
                                .foregroundStyle(DS.Palette.textTertiary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(DS.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(isOn ? DS.Palette.accentSoft : DS.Palette.surfaceRaised)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func webSearchToggle(_ binding: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Toggle("提问前先联网检索文献，并把结果作为可引用的材料喂给模型", isOn: binding)
                .font(DS.Typo.ui(size: 11.5))

            Text("""
            检索源是三个免密钥的公开学术库：Crossref、Semantic Scholar、arXiv。\
            知网没有公开接口，万方需要申请审批，Web of Science 是机构订阅接口——\
            这三家目前接不了，所以中文文献的覆盖以在 Crossref 注册过 DOI 的期刊为主。

            开启后每次提问会多花几秒等检索回来；勾选「列文献」技能才会要求模型把来源写进回答。
            """)
            .font(DS.Typo.ui(size: 10.5))
            .foregroundStyle(DS.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: some View {
        Text("""
        Agent 的角色与技能是**追加**在默认系统提示之后的，不会顶掉其中的防幻觉与可追溯要求——\
        换个角色不该让模型开始编。留空角色、不勾技能，就等同不用 Agent。

        内置的四个预设可以改，但删不掉；想还原就清空角色、取消所有技能。
        """)
        .font(DS.Typo.ui(size: 11))
        .foregroundStyle(DS.Palette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            if let editing, !editing.isBuiltIn {
                Button("删除") { delete(editing) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DS.Palette.danger)
            }

            Spacer(minLength: 0)

            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: DS.Size.toolbarHeight + 8)
    }

    private var canSave: Bool {
        guard let editing else { return false }
        return !editing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 动作

    private func loadInitial() {
        guard editing == nil else { return }
        if let id = state.settingsStore.ai.activeAgentID,
           let current = agents.first(where: { $0.id == id }) {
            editing = current
        } else {
            editing = agents.first
        }
        isNew = false
    }

    private func load(_ agent: AgentConfig) {
        editing = agent
        isNew = false
    }

    private func startNew() {
        editing = AgentConfig(name: "新 Agent")
        isNew = true
    }

    private func save() {
        guard let editing else { return }
        var toSave = editing
        toSave.name = toSave.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if toSave.name.isEmpty { toSave.name = "未命名 Agent" }

        var all = state.settingsStore.ai.agents
        if let index = all.firstIndex(where: { $0.id == toSave.id }) {
            all[index] = toSave
        } else {
            all.append(toSave)
        }
        state.settingsStore.settings.ai.agents = all

        if isNew {
            state.settingsStore.settings.ai.activeAgentID = toSave.id
        }
        dismiss()
    }

    private func delete(_ agent: AgentConfig) {
        var all = state.settingsStore.ai.agents
        all.removeAll { $0.id == agent.id }
        state.settingsStore.settings.ai.agents = all

        // 删掉的正好是当前生效的那个，把选择一并退回「不用 Agent」，
        // 避免 activeAgentID 指向一个不存在的 id
        if state.settingsStore.ai.activeAgentID == agent.id {
            state.settingsStore.settings.ai.activeAgentID = nil
        }
        editing = all.first
    }
}

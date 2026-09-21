import SwiftUI
import LumenKit

/// Agent 编辑器。
///
/// 与提示词编辑器同样的取舍：独立 sheet、编辑副本、保存才写回。
/// 差别在于这里编辑的是**四件事**——角色设定、勾选的技能、温度覆盖、要不要联网，
/// 它们的组合很多，所以表单要能一眼看全，而不是让人翻页。
///
/// 技能这一块的形状（2026-09-21 定）：
/// - **选项是卡片，不是行内编辑框**。「有哪些技能可选」本身就是用户要看到的信息，
///   藏进下拉或摊成一行行输入框，等于让他先猜再找。勾选状态用卡片上的圆圈表示，
///   一眼看得出这个 Agent 带了哪些装备。
/// - **卡片可以改、可以删、可以新增**，改的删的都是**共用的那条样式**：技能存在
///   全局技能库里（`AISettings.skillLibrary`），Agent 只记勾了哪些 id。
///   所以卡片是「样式」的入口，不是「这个 Agent 的一条设置」。
/// - 「取消」能撤销全部改动（技能库草稿与 Agent 一起在保存时才写回）。
struct AgentEditor: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var editing: AgentConfig?
    @State private var isNew = false
    /// 技能库草稿。与 Agent 一起在「保存」时才写回——「取消」必须是能撤销的，
    /// 否则用户点开编辑器随手删了两条技能，取消之后才发现技能库已经变了。
    @State private var library: [AgentSkill] = []
    /// 待确认删除的 Agent。删除不可逆（没有「恢复被删掉的 Agent」这条路），所以要问一次。
    @State private var pendingDeletion: AgentConfig?
    /// 指针停在哪张技能卡上（编辑 / 删除两个小按钮只在悬停时出现）。
    @State private var hoveredSkillID: String?
    /// 正在编辑的技能。非 nil 时弹一层小 sheet。
    @State private var editingSkill: AgentSkill?
    @State private var pendingSkillDeletion: AgentSkill?

    private var agents: [AgentConfig] { state.settingsStore.ai.agents }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Palette.separator)
            form
            Divider().overlay(DS.Palette.separator)
            footer
        }
        .frame(width: 680, height: 680)
        .background(DS.Palette.surfaceSunken)
        .onAppear(perform: loadInitial)
        .confirmationDialog(
            "删除 Agent「\(pendingDeletion?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let agent = pendingDeletion { delete(agent) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("删掉之后不会再出现，也找不回来。")
        }
        .sheet(item: $editingSkill, onDismiss: pruneBlankSkill) { skill in
            SkillEditSheet(skill: skillBinding(id: skill.id) ?? .constant(skill)) {
                // 在编辑层里点删除：直接删掉并关掉这一层，不再叠一次确认——
                // 删除本身还在外层草稿里，外层「取消」能整份撤销。
                pendingSkillDeletion = nil
                deleteSkill(skill)
                editingSkill = nil
            }
        }
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
                        editor(text: binding.persona, minHeight: 96)
                    }

                    field("技能") {
                        skillGrid(selection: binding.skills, webSearchOn: binding.usesWebSearch)
                    }

                    field("温度（创造性）") {
                        temperatureField(binding.temperatureOverride)
                    }

                    field("联网检索文献") {
                        webSearchToggle(binding.usesWebSearch)
                    }
                }
                .padding(DS.Space.l)
            }
        } else {
            VStack(spacing: DS.Space.s) {
                Text("还没有 Agent")
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textTertiary)
                Button("新建 Agent") { startNew() }
            }
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

    // MARK: - 技能

    /// 技能选项：两列平铺的卡片，点一下就勾上 / 取消。
    ///
    /// 卡片来路是技能库（草稿），不是 Agent 自己那份——所以「改的删的都是共用样式」，
    /// 界面上那句提示必须写清楚，否则用户会以为只影响当前这个 Agent。
    private func skillGrid(selection: Binding<[String]>, webSearchOn: Binding<Bool>) -> some View {
        let missingBuiltins = AgentSkill.catalog.filter { builtin in
            !library.contains { $0.id == builtin.id }
        }
        let webSearchOn = webSearchOn.wrappedValue

        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DS.Space.s),
                    GridItem(.flexible(), spacing: DS.Space.s)
                ],
                spacing: DS.Space.xs
            ) {
                ForEach(library) { skill in
                    skillCard(skill, selection: selection, webSearchOn: webSearchOn)
                }
            }

            HStack(spacing: DS.Space.l) {
                Button {
                    addSkill(to: selection)
                } label: {
                    Label("新建技能", systemImage: "plus.circle")
                        .font(DS.Typo.ui(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)

                // 删掉的内置技能不会自己长回来（与 Agent 同一条规则），留一个恢复入口。
                if !missingBuiltins.isEmpty {
                    Button {
                        library.append(contentsOf: missingBuiltins)
                    } label: {
                        Text("恢复内置技能（\(missingBuiltins.count)）")
                            .font(DS.Typo.ui(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            Text("点卡片勾选；指针停在卡片上可编辑或删除（也可以右键），改的是共用样式——用它的 Agent 一起变。")
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func skillCard(_ skill: AgentSkill, selection: Binding<[String]>, webSearchOn: Bool) -> some View {
        let isOn = selection.wrappedValue.contains(skill.id)
        let isHovered = hoveredSkillID == skill.id

        return HStack(alignment: .top, spacing: DS.Space.xs) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(DS.Typo.ui(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? DS.Palette.accent : DS.Palette.textTertiary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name.isEmpty ? "未命名技能" : skill.name)
                    .font(DS.Typo.ui(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Palette.textPrimary)

                Text(skill.instruction.isEmpty ? "还没写具体要求" : skill.instruction)
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(skill.instruction.isEmpty
                                     ? DS.Palette.textTertiary
                                     : DS.Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // 这条技能在当前配置下**不会生效**——不说的话，用户勾了却没见模型照做，
                // 只会以为是模型不听话。
                if skill.id == AgentSkill.literatureID && !webSearchOn {
                    Text("要打开「联网检索文献」才会生效")
                        .font(DS.Typo.ui(size: 10))
                        .foregroundStyle(DS.Palette.warning)
                }
            }

            Spacer(minLength: 0)

            if isHovered {
                HStack(spacing: DS.Space.xs) {
                    Button { editingSkill = skill } label: {
                        Image(systemName: "pencil").font(DS.Typo.ui(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("编辑这条技能")

                    Button { pendingSkillDeletion = skill } label: {
                        Image(systemName: "trash").font(DS.Typo.ui(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("删除这条技能")
                }
                .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(isOn ? DS.Palette.accentSoft : DS.Palette.surfaceRaised)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggle(skill.id, in: selection) }
        .onHover { inside in
            if inside { hoveredSkillID = skill.id }
            else if hoveredSkillID == skill.id { hoveredSkillID = nil }
        }
        .contextMenu {
            Button("编辑…") { editingSkill = skill }
            Button("删除", role: .destructive) { pendingSkillDeletion = skill }
        }
        .help(skill.instruction.isEmpty ? "还没写具体要求" : skill.instruction)
        // 「删除」要走一次确认：技能是共用的，删掉之后所有 Agent 都没它了。
        // 对话框挂在卡片上（而不是顶层），这样同时只有一个能被触发，
        // 不必和「删除 Agent」那个对话框抢同一个修饰符。
        .confirmationDialog(
            "删除技能「\(skill.name.isEmpty ? "未命名技能" : skill.name)」？",
            isPresented: Binding(
                get: { pendingSkillDeletion?.id == skill.id },
                set: { if !$0 { pendingSkillDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deleteSkill(skill)
                pendingSkillDeletion = nil
            }
            Button("取消", role: .cancel) { pendingSkillDeletion = nil }
        } message: {
            Text("所有 Agent 都不再能勾选它；已经勾了的会一起摘掉。")
        }
    }

    /// 温度覆盖。默认跟随服务商设置，所以开关语义是「跟随 / 覆盖」而不是一个裸滑杆。
    private func temperatureField(_ binding: Binding<Double?>) -> some View {
        // 开关的两态写作「跟随 / 覆盖」而不是「开 / 关」：
        // 「开启温度」这种说法没有信息量（温度一直都在，只是谁说了算）。
        let followsProvider = Binding(
            get: { binding.wrappedValue == nil },
            set: { follows in
                // 打开覆盖时从 0.7 起步（与服务商的默认值相同），而不是从 0：
                // 从 0 开始的第一印象是「模型变呆了」，用户会直接放弃这个功能。
                binding.wrappedValue = follows ? nil : 0.7
            }
        )

        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Toggle("跟随服务商设置", isOn: followsProvider)
                .font(DS.Typo.ui(size: 11.5))

            if binding.wrappedValue != nil {
                HStack(spacing: DS.Space.s) {
                    Slider(
                        value: Binding(
                            get: { binding.wrappedValue ?? 0.7 },
                            set: { binding.wrappedValue = $0 }
                        ),
                        in: AgentConfig.temperatureRange,
                        step: 0.05
                    )
                    Text(String(format: "%.2f", binding.wrappedValue ?? 0.7))
                        .font(DS.Typo.ui(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Text("只影响对话请求（提问 / 解释 / 翻译 / 总结）；跟随服务商设置时用设置页里的温度。")
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func webSearchToggle(_ binding: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Toggle("提问前先联网检索文献，并把结果作为可引用的材料喂给模型", isOn: binding)
                .font(DS.Typo.ui(size: 11.5))

            Text("检索源是 Crossref / OpenAlex / arXiv（都免密钥）；知网、万方、Web of Science 没有可公开调用的接口，接不了，中文文献的覆盖以在 Crossref 注册过 DOI 的期刊为主。开启后每次提问会先多等几秒。")
                .font(DS.Typo.ui(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            // 内置预设也可以删（删掉之后不再自动补回），所以这里不再按 isBuiltIn 分叉。
            if let editing {
                Button("删除") { pendingDeletion = editing }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DS.Palette.danger)
            }

            // 与「删除」不是一回事：预设被改乱了可以退回出厂内容，删掉的则找不回来。
            if let editing, editing.isBuiltIn,
               AgentConfig.presets.contains(where: { $0.id == editing.id }) {
                Button("恢复内置预设") { restorePreset(editing) }
                    .buttonStyle(.borderless)
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
        library = state.settingsStore.ai.skillLibrary
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

    private func toggle(_ id: String, in selection: Binding<[String]>) {
        var current = selection.wrappedValue
        if let index = current.firstIndex(of: id) {
            current.remove(at: index)
        } else {
            current.append(id)
        }
        selection.wrappedValue = current
    }

    /// 新建一条技能：进技能库，并且**顺手勾上**——用户点「新建技能」就是想用它，
    /// 建完还要再点一次卡片是多余的一步。
    private func addSkill(to selection: Binding<[String]>) {
        let blank = AgentSkill(name: "", instruction: "")
        library.append(blank)
        selection.wrappedValue.append(blank.id)
        editingSkill = blank
    }

    private func deleteSkill(_ skill: AgentSkill) {
        library.removeAll { $0.id == skill.id }
        editing?.skills.removeAll { $0 == skill.id }
    }

    /// 编辑技能的小 sheet 关掉时，把「名字与要求都还是空的」那条清掉：
    /// 新建之后直接放弃会在列表里留下一张永远用不上的空卡。
    private func pruneBlankSkill() {
        let blanks = library.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !blanks.isEmpty else { return }
        let ids = Set(blanks.map(\.id))
        library.removeAll { ids.contains($0.id) }
        editing?.skills.removeAll { ids.contains($0) }
    }

    private func skillBinding(id: String) -> Binding<AgentSkill>? {
        guard let index = library.firstIndex(where: { $0.id == id }) else { return nil }
        return $library[index]
    }

    private func save() {
        guard let editing else { return }
        var toSave = editing
        toSave.name = toSave.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if toSave.name.isEmpty { toSave.name = "未命名 Agent" }

        // 技能库与 agents 是两份数据、一次写入：库里删掉的技能要从**所有** Agent 的
        // 勾选里摘掉，否则会留下悬空 id（面板上看不出错，只是那条技能**静默**不生效）。
        let known = Set(library.map(\.id))
        var all = state.settingsStore.ai.agents
        if let index = all.firstIndex(where: { $0.id == toSave.id }) {
            all[index] = toSave
        } else {
            all.append(toSave)
        }
        for index in all.indices {
            all[index].skills.removeAll { !known.contains($0) }
        }
        state.settingsStore.settings.ai.skillLibrary = library
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

    private func restorePreset(_ agent: AgentConfig) {
        guard let preset = AgentConfig.presets.first(where: { $0.id == agent.id }) else { return }
        editing = preset
    }
}

// MARK: - 技能编辑

/// 编辑一条技能（名称 + 具体要求）。
///
/// 只有「完成」没有「取消」：这里是**实时改草稿**，写进去的每个字都还在外层编辑器的
/// 草稿里，外层的「取消」仍然能整份撤销。摆一个「取消」按钮反而会让人以为它只撤销
/// 这一层——点了没效果，比没有这个按钮更让人困惑。
private struct SkillEditSheet: View {

    @Binding var skill: AgentSkill
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Text(skill.name.isEmpty ? "新建技能" : skill.name)
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: DS.Size.toolbarHeight)

            Divider().overlay(DS.Palette.separator)

            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("名称")
                        .font(DS.Typo.ui(size: 11.5, weight: .medium))
                        .foregroundStyle(DS.Palette.textSecondary)
                    TextField("技能名称", text: $skill.name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("具体要求")
                        .font(DS.Typo.ui(size: 11.5, weight: .medium))
                        .foregroundStyle(DS.Palette.textSecondary)
                    TextEditor(text: $skill.instruction)
                        .font(DS.Typo.ui(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(DS.Space.s)
                        .frame(minHeight: 150)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                                .fill(DS.Palette.surfaceRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                        )
                }

                Text("它会作为一条独立的行为要求发给模型（「- 【名称】要求」接在角色设定之后）。名称只用于辨认，具体要求要写成清楚、可执行的句子。")
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.l)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider().overlay(DS.Palette.separator)

            HStack(spacing: DS.Space.s) {
                Button("删除") { onDelete() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DS.Palette.danger)

                Spacer(minLength: 0)

                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: DS.Size.toolbarHeight + 8)
        }
        .frame(width: 480, height: 400)
        .background(DS.Palette.surfaceSunken)
    }
}

import SwiftUI
import LumenKit

/// Reading instructions are text; skills activate app capabilities.
struct AgentEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AgentConfig?
    @State private var pendingDeletion: AgentConfig?

    private var agents: [AgentConfig] {
        let saved = state.settingsStore.ai.agents
        return saved.contains { $0.id == AgentConfig.mindMapMode.id } ? saved : saved + [AgentConfig.mindMapMode]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("阅读方式").font(DS.Typo.headline)
                Spacer()
                Menu(editing?.name ?? "选择阅读方式") {
                    ForEach(agents) { agent in Button(agent.name) { editing = agent } }
                    Divider()
                    Button("新建阅读方式") { editing = AgentConfig(name: "新阅读方式") }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: DS.Size.toolbarHeight)
            Divider()
            if let binding = Binding($editing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        field("名称") {
                            TextField("名称", text: binding.name).textFieldStyle(.roundedBorder)
                        }
                        field("阅读指令") {
                            TextEditor(text: binding.persona)
                                .font(DS.Typo.ui(size: 12))
                                .scrollContentBackground(.hidden)
                                .padding(DS.Space.s)
                                .frame(minHeight: 180)
                                .background(DS.Palette.surfaceRaised)
                        }
                        field("技能") {
                            ForEach(AgentSkill.catalog) { skill in
                                Toggle(skill.name, isOn: Binding(
                                    get: { binding.wrappedValue.skills.contains(skill.id) },
                                    set: { enabled in
                                        binding.wrappedValue.skills.removeAll { $0 == skill.id }
                                        if enabled { binding.wrappedValue.skills.append(skill.id) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .help(skill.instruction)
                            }
                        }
                        field("温度") { temperatureField(binding.temperatureOverride) }
                    }
                    .padding(DS.Space.l)
                }
            } else {
                Spacer()
            }
            Divider()
            HStack {
                if let current = editing {
                    if current.id != AgentConfig.mindMapMode.id {
                        Button("删除", role: .destructive) { pendingDeletion = current }
                            .disabled(!state.settingsStore.ai.agents.contains { $0.id == current.id })
                    }
                    if let preset = AgentConfig.presets.first(where: { $0.id == current.id }) {
                        Button("恢复预设") { editing = preset }
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并使用") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editing?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: DS.Size.toolbarHeight + 8)
        }
        .frame(width: 680, height: 680)
        .background(DS.Palette.surfaceSunken)
        .onAppear { editing = state.settingsStore.ai.activeReadingMode ?? agents.first }
        .confirmationDialog("删除阅读方式「\(pendingDeletion?.name ?? "")」？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let agent = pendingDeletion {
                    state.settingsStore.settings.ai.agents.removeAll { $0.id == agent.id }
                    if state.settingsStore.ai.activeAgentID == agent.id {
                        state.settingsStore.settings.ai.activeAgentID = nil
                    }
                    editing = agents.first
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).font(DS.Typo.ui(size: 11.5, weight: .medium)).foregroundStyle(DS.Palette.textSecondary)
            content()
        }
    }

    private func temperatureField(_ binding: Binding<Double?>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Toggle("跟随服务商设置", isOn: Binding(
                get: { binding.wrappedValue == nil },
                set: { binding.wrappedValue = $0 ? nil : 0.7 }
            ))
            if binding.wrappedValue != nil {
                HStack {
                    Slider(value: Binding(get: { binding.wrappedValue ?? 0.7 },
                                          set: { binding.wrappedValue = $0 }),
                           in: AgentConfig.temperatureRange, step: 0.05)
                    Text(String(format: "%.2f", binding.wrappedValue ?? 0.7)).monospacedDigit()
                }
            }
        }
    }

    private func save() {
        guard var agent = editing else { return }
        agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.name.isEmpty else { return }
        agent.skills.removeAll { $0 != AgentSkill.evidenceID }
        var all = state.settingsStore.ai.agents
        if let index = all.firstIndex(where: { $0.id == agent.id }) { all[index] = agent }
        else { all.append(agent) }
        state.settingsStore.settings.ai.skillLibrary = AgentSkill.catalog
        state.settingsStore.settings.ai.agents = all
        state.settingsStore.settings.ai.activeAgentID = agent.id
        dismiss()
    }
}

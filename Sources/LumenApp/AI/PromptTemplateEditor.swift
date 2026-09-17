import SwiftUI
import LumenKit

/// 提示词模板编辑器。
///
/// 为什么是一个独立 sheet、而不是把编辑塞进 AI 面板里：写提示词是**低频且需要专注**
/// 的事，得有个能放开写几段话的地方。挤在 380pt 宽的面板里，文本框只剩几行高，
/// 用户试两下就会放弃编辑、继续用默认——那这个功能等于没做。
struct PromptTemplateEditor: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// 编辑中的**副本**。
    ///
    /// 先改副本、点保存才写回设置。直接绑到 `settingsStore` 的话，每敲一个字
    /// 都会触发一次防抖落盘，而且「取消」会变得毫无意义——用户改到一半反悔，
    /// 配置已经被改掉了。
    @State private var editing: PromptTemplate?
    /// 当前这份是不是新建出来的。新建保存后要顺手切过去用它。
    @State private var isNew = false

    private var templates: [PromptTemplate] { state.settingsStore.ai.templates }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Palette.separator)
            form
            Divider().overlay(DS.Palette.separator)
            footer
        }
        .frame(width: 580, height: 480)
        .background(DS.Palette.surfaceSunken)
        .onAppear(perform: loadInitial)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text("提示词模板")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Palette.textPrimary)

            Spacer(minLength: 0)

            Menu {
                ForEach(templates) { template in
                    Button(template.name) { load(template) }
                }
                Divider()
                Button("新建模板") { startNew() }
            } label: {
                Text(editing?.name ?? "选择模板")
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
                        TextField("模板名称", text: binding.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("系统提示（留空则沿用默认）") {
                        editor(text: binding.systemPrompt, minHeight: 118)
                    }

                    field("额外要求（每次提问时追加在最后）") {
                        editor(text: binding.instruction, minHeight: 96)
                    }

                    explanation
                }
                .padding(DS.Space.l)
            }
        } else {
            Text("没有可编辑的模板")
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

    private var explanation: some View {
        Text("""
        系统提示决定模型的立场与总原则，会整段替换默认的那一份；\
        额外要求只在你每次提问时追加在末尾，适合写「这一次额外要多做什么」。

        两者都留空即等同默认行为。内置模板可以改，但删不掉——\
        想还原就把两个框清空，或删掉自己新建的那几条。
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
        // 只有名字是硬要求：系统提示与额外要求都可以为空（那就是「不覆盖」）。
        return !editing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 动作

    /// 打开时选中当前生效的模板；没有生效的就选第一个内置模板。
    ///
    /// 不落到「新建」上：用户打开编辑器多半是想先看看某个模板写了什么，
    /// 一上来就给一张空表，会让他以为自己的模板丢了。
    private func loadInitial() {
        guard editing == nil else { return }
        if let id = state.settingsStore.ai.activeTemplateID,
           let current = templates.first(where: { $0.id == id }) {
            editing = current
        } else {
            editing = templates.first
        }
        isNew = false
    }

    private func load(_ template: PromptTemplate) {
        editing = template
        isNew = false
    }

    private func startNew() {
        editing = PromptTemplate(name: "新模板")
        isNew = true
    }

    private func save() {
        guard let editing else { return }
        var toSave = editing
        toSave.name = toSave.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if toSave.name.isEmpty { toSave.name = "未命名模板" }

        var all = state.settingsStore.ai.templates
        if let index = all.firstIndex(where: { $0.id == toSave.id }) {
            all[index] = toSave
        } else {
            all.append(toSave)
        }
        state.settingsStore.settings.ai.templates = all

        // 刚写完一份提示词，下一步一定是想试它，所以新建的直接切过去。
        if isNew {
            state.settingsStore.settings.ai.activeTemplateID = toSave.id
        }
        dismiss()
    }

    private func delete(_ template: PromptTemplate) {
        var all = state.settingsStore.ai.templates
        all.removeAll { $0.id == template.id }
        state.settingsStore.settings.ai.templates = all

        // 删掉的正好是当前生效的那个，必须把选择一并退回默认。
        // 否则 `activeTemplateID` 会指向一个不存在的模板：AI 面板显示「默认」，
        // 内部状态却自相矛盾，下次再选中别的模板才会暴露。
        if state.settingsStore.ai.activeTemplateID == template.id {
            state.settingsStore.settings.ai.activeTemplateID = nil
        }
        editing = all.first
    }
}

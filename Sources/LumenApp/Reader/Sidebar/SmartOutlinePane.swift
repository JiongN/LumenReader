import SwiftUI
import LumenKit

/// 侧栏的「智能目录」页。
///
/// 两步走的界面：先生成骨架（一次请求），摘要按需生成（点哪条算哪条）。
/// 界面上刻意把这两种动作**做成两个不同的控件**——「摘要」按钮是明摆着要花钱的，
/// 折叠箭头是免费的本地展开。把付费动作藏在「展开」里，用户点着点着账单就上去了。
struct SmartOutlinePane: View {

    @EnvironmentObject private var bridge: ReaderBridge
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var model: SmartOutlineModel

    /// 已展开摘要的条目 id。放视图里而不是模型里：
    /// 「展开」是一次性的界面状态，退出再进来收起来是合理的，不值得持久化。
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(DS.Palette.separator)
            content
        }
        .onChange(of: model.outline) { _, newValue in
            guard let newValue else {
                expanded = []
                return
            }
            // 重新生成后旧的高亮态没有意义了，避免出现「展开着一条已经不在的条目」
            expanded = expanded.filter { id in
                newValue.entries.contains(where: { $0.id == id })
            }
        }
        .onChange(of: model.pendingReveal) { _, _ in
            let ready = model.consumePendingReveal()
            guard !ready.isEmpty else { return }
            // 用户已经明确想看这一节了（他点了摘要按钮，或命令面板替他点了），
            // 让他再点一次折叠箭头是无谓的第二下。
            withAnimation(DS.Motion.content) {
                expanded.formUnion(ready)
            }
        }
        .onChange(of: model.phase) { _, newValue in
            // 请求失败后不能再挂着「等它出结果」——那条 id 会永远等下去，
            // 而且下一次成功时会被误判成「刚返回的」，莫名其妙地展开一条旧条目。
            if case .failed = newValue { _ = model.consumePendingReveal() }
        }
    }

    // MARK: - 顶部操作条

    private var toolbar: some View {
        HStack(spacing: DS.Space.xs) {
            Button {
                state.generateSmartOutline()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(DS.Typo.ui(size: 11, weight: .medium))
                    Text(model.outline == nil ? "生成目录" : "重新生成")
                        .font(DS.Typo.ui(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(model.phase.isWorking ? DS.Palette.surfaceSunken : DS.Palette.accentSoft)
                )
                .foregroundStyle(model.phase.isWorking ? DS.Palette.textTertiary : DS.Palette.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.phase.isWorking)
            .help("让 AI 读一遍文档，推断出章节结构")

            Spacer(minLength: 0)

            if model.phase.isWorking {
                Button("取消") { model.cancel() }
                    .buttonStyle(.plain)
                    .font(DS.Typo.ui(size: 11.5))
                    .foregroundStyle(DS.Palette.textSecondary)
            } else if model.outline != nil {
                Button {
                    withAnimation(DS.Motion.content) {
                        expanded = []
                        model.discard()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(DS.Typo.ui(size: 11))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("清除这份目录")
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 6)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if model.phase.isWorking {
            workingState
        } else if let message = failureMessage, model.outline == nil {
            failureState(message)
        } else if let outline = model.outline {
            entryList(outline)
        } else {
            emptyState
        }
    }

    private var failureMessage: String? {
        if case .failed(let text) = model.phase { return text }
        return nil
    }

    private var workingState: some View {
        VStack(spacing: DS.Space.s) {
            ProgressView().controlSize(.small)
            Text(workingLabel)
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("首次生成通常要十几秒。")
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workingLabel: String {
        if case .working(let text) = model.phase { return text }
        return "正在处理…"
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.triangle")
                .font(DS.Typo.ui(size: 20))
                .foregroundStyle(DS.Palette.warning)
            Text("没能生成目录")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
            Text(message)
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("知道了") { model.clearFailure() }
                .buttonStyle(.plain)
                .font(DS.Typo.ui(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Palette.accent)
                .padding(.top, DS.Space.xxs)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(DS.Typo.ui(size: 22))
                .foregroundStyle(DS.Palette.textTertiary)
            Text("AI 智能目录")
                .font(DS.Typo.callout)
                .foregroundStyle(DS.Palette.textSecondary)
            Text(hintText)
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 已经内嵌了书签的文档，先说清楚「这不是没有目录，是机器又读了一遍」——
    /// 否则用户会以为功能没生效。
    private var hintText: String {
        bridge.outline.isEmpty
            ? "让 AI 读一遍每\(state.unitName)开头的内容，自动推断出章节结构。生成后可点击跳转，也可逐节生成摘要。"
            : "这份文档已内嵌目录。智能目录会由 AI 重新归纳一份，两者可以对照着看。"
    }

    // MARK: - 条目列表

    private func entryList(_ outline: SmartOutline) -> some View {
        VStack(spacing: 0) {
            if let message = failureMessage {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(DS.Typo.ui(size: 10))
                    Text(message)
                        .font(DS.Typo.ui(size: 11))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        model.clearFailure()
                    } label: {
                        Image(systemName: "xmark")
                            .font(DS.Typo.ui(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(DS.Palette.warning)
                .padding(DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(DS.Palette.warning.opacity(0.10))
                )
                .padding(.horizontal, DS.Space.s)
                .padding(.top, DS.Space.s)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(outline.entries) { entry in
                        SmartOutlineRow(
                            entry: entry,
                            isExpanded: expanded.contains(entry.id),
                            isSummarizing: model.summarizing.contains(entry.id),
                            isActive: entry.id == activeEntryID(outline),
                            onJump: { state.jump(toUnit: entry.unitIndex) },
                            onRequestSummary: { requestSummary(for: entry) },
                            onCancelSummary: {
                                model.cancelSummary(id: entry.id)
                            },
                            onToggleSummary: {
                                withAnimation(DS.Motion.content) {
                                    if expanded.contains(entry.id) {
                                        expanded.remove(entry.id)
                                    } else {
                                        expanded.insert(entry.id)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, DS.Space.s)
                .padding(.horizontal, DS.Space.xs)
            }

            Divider().overlay(DS.Palette.separator)
            footer(outline)
        }
    }

    private func footer(_ outline: SmartOutline) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text("\(outline.entries.count) 项")
            Spacer(minLength: 0)
            Text(outline.modelName)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·")
            Text(outline.generatedAt, format: .dateTime.month().day().hour().minute())
                .monospacedDigit()
        }
        .font(DS.Typo.ui(size: 10))
        .foregroundStyle(DS.Palette.textTertiary)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 5)
    }

    /// 当前阅读位置落在哪一条上：取「起点不晚于当前位置」的最后一条。
    /// 不用 `==` 匹配是因为目录条目的粒度（章）常常大于当前单元（页）。
    private func activeEntryID(_ outline: SmartOutline) -> String? {
        outline.entries
            .last { $0.unitIndex <= bridge.currentUnitIndex }?
            .id
    }

    // MARK: - 摘要

    private func requestSummary(for entry: SmartOutlineEntry) {
        // 有意**不立刻展开**：请求要跑几秒，展开一个空框比原地转圈更让人困惑。
        // 模型会在拿到内容时把它记进 pendingReveal，界面收到后再展开。
        model.summarize(
            entry: entry,
            bridge: bridge,
            metadata: bridge.metadata,
            config: state.settingsStore.activeProvider
        )
    }
}

// MARK: - 条目行

private struct SmartOutlineRow: View {

    let entry: SmartOutlineEntry
    let isExpanded: Bool
    let isSummarizing: Bool
    let isActive: Bool
    let onJump: () -> Void
    let onRequestSummary: () -> Void
    let onCancelSummary: () -> Void
    let onToggleSummary: () -> Void

    @State private var isHovering = false

    private var hasSummary: Bool {
        !(entry.summary ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: DS.Space.xs) {
                Button(action: onJump) {
                    HStack(alignment: .top, spacing: DS.Space.xs) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isActive ? DS.Palette.accent : DS.Palette.separator)
                            .frame(width: 2, height: entry.depth == 0 ? 12 : 8)
                            .padding(.top, 3)

                        Text(entry.title)
                            .font(DS.Typo.ui(
                                size: entry.depth == 0 ? 12.5 : 12,
                                weight: entry.depth == 0 ? .medium : .regular
                            ))
                            .foregroundStyle(isActive
                                ? DS.Palette.accent
                                : (entry.depth == 0 ? DS.Palette.textPrimary : DS.Palette.textSecondary))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("跳到这一节")

                summaryControl
            }

            if isExpanded, let summary = entry.summary, !summary.isEmpty {
                MarkdownText(text: summary, textColor: DS.Palette.textSecondary)
                    .padding(DS.Space.s)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(DS.Palette.surfaceRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                    )
                    .padding(.leading, CGFloat(entry.depth) * 10 + 6)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(.leading, CGFloat(entry.depth) * 10 + DS.Space.xs)
        .padding(.trailing, DS.Space.s)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                .fill(isHovering ? DS.Palette.accentSoft.opacity(0.6) : .clear)
        )
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovering = hovering }
        }
    }

    /// 摘要按钮的三种形态：可中止的转圈／折叠箭头（已有，免费看）／「摘要」（要花钱）。
    @ViewBuilder
    private var summaryControl: some View {
        if isSummarizing {
            // 转圈本身做成按钮：这一条正在花钱，用户得有个地方能喊停。
            Button(action: onCancelSummary) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("正在生成摘要，点击中止")
        } else if hasSummary {
            Button(action: onToggleSummary) {
                Image(systemName: "chevron.right")
                    .font(DS.Typo.ui(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起摘要" : "展开摘要")
        } else {
            Button(action: onRequestSummary) {
                HStack(spacing: 2) {
                    Image(systemName: "sparkles")
                        .font(DS.Typo.ui(size: 8.5))
                    Text("摘要")
                        .font(DS.Typo.ui(size: 10))
                }
                .foregroundStyle(isHovering ? DS.Palette.accent : DS.Palette.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                        .fill(isHovering ? DS.Palette.surfaceRaised : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("让 AI 读这一节并生成摘要")
        }
    }
}

import SwiftUI
import AppKit
import LumenKit

/// 顶栏的「阅读外观与排版」入口：图标按钮 + 浮出面板。
///
/// 原来是 `Menu`，换成了 `Popover`——面板里要放字号 / 行距两个滑块，
/// 而 macOS 的 Menu 只要里面有可交互控件，点一下就自己收掉，滑块根本调不动。
///
/// 图标也从 `textformat.size` 换成 `textformat`：`textformat.size` 画的是
/// 一个大写 A 加一把尺，语义是「字号」，而这个面板管的是主题、字号、行距、
/// 单双栏、翻页方式——用「纯字号」的图标去开「排版」面板，属于答非所问。
struct AppearanceMenuButton: View {

    @EnvironmentObject private var state: AppState

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "textformat")
                .font(DS.Typo.ui(size: 13))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Palette.textSecondary)
        .help("阅读外观与排版")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AppearancePanel()
                // 面板是浮出的独立分支，环境对象不会自动带过去。
                .environmentObject(state)
                .environmentObject(state.bridge)
                .environmentObject(state.settingsStore)
        }
    }
}

// MARK: - 面板

private struct AppearancePanel: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var bridge: ReaderBridge

    @EnvironmentObject private var store: SettingsStore
    private var isEPUB: Bool { state.document?.kind == .epub }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            themeRow

            if isEPUB {
                Divider()
                sectionTitle("排版")
                fontScaleRow
                lineHeightRow
                Divider()
                columnRow
                flowRow
                Divider()
            } else if state.document != nil {
                Divider()
                Toggle("保持 PDF 原色", isOn: Binding(
                    get: { store.reader.pdfOriginalColors },
                    set: { store.reader.pdfOriginalColors = $0 }
                ))
                .font(DS.Typo.ui(size: 12))
                Text(ReaderSettings.fontScaleScopeNote)
                    .font(DS.Typo.ui(size: 10))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.m)
        .frame(width: 276)
    }

    // MARK: 主题

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            sectionTitle("主题")
            HStack(spacing: DS.Space.xs) {
                ForEach(ReadingTheme.all, id: \.id) { theme in
                    let isActive = store.reader.themeID == theme.id
                    Button(theme.id.displayName) {
                        store.reader.themeID = theme.id
                    }
                    .buttonStyle(.plain)
                    .font(DS.Typo.ui(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? DS.Palette.accent : DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(isActive ? DS.Palette.accentSoft : DS.Palette.surfaceSunken)
                    )
                }
            }
        }
    }

    // MARK: 字号 / 行距

    private var fontScaleRow: some View {
        sliderRow(
            title: "字号",
            value: Binding(
                get: { store.reader.fontScale },
                set: { store.reader.fontScale = $0 }
            ),
            range: ReaderSettings.fontScaleMin...ReaderSettings.fontScaleMax,
            step: 0.05,
            display: "\(Int((store.reader.fontScale * 100).rounded()))%"
        )
    }

    private var lineHeightRow: some View {
        sliderRow(
            title: "行距",
            value: Binding(
                get: { store.reader.lineHeight },
                set: { store.reader.lineHeight = $0 }
            ),
            range: 1.2...2.6,
            step: 0.05,
            display: String(format: "%.2f", store.reader.lineHeight)
        )
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(DS.Typo.ui(size: 12))
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer(minLength: 0)
                Text(display)
                    .font(DS.Typo.ui(size: 11, weight: .medium))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
        }
    }

    // MARK: 单 / 双栏

    /// 文案按**生效栏数**写，不按设置值写。
    ///
    /// 排版脚本在窗口窄于 760pt 时会把双栏压回单栏，此时设置仍是「双栏」——
    /// 若按设置值写，用户明明在看单栏，面板却提示「切换为单栏」，点了还没反应。
    private var columnRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text("栏数")
                    .font(DS.Typo.ui(size: 12))
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer(minLength: 0)
                Text(isEffectivelyDoubleColumn ? "双栏" : "单栏")
                    .font(DS.Typo.ui(size: 11, weight: .medium))
                    .foregroundStyle(DS.Palette.textPrimary)
            }

            Button(isEffectivelyDoubleColumn ? "切换为单栏" : "切换为双栏") {
                store.reader.epubDoubleColumn.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // 已经「要双栏」却因为窗口不够宽没生效：再点一次也不会变，
            // 与其让它点了没反应，不如置灰并把原因写在下面。
            .disabled(store.reader.epubDoubleColumn && !isEffectivelyDoubleColumn)

            if store.reader.epubDoubleColumn && !isEffectivelyDoubleColumn {
                Text("窗口不足 760pt，双栏暂不生效")
                    .font(DS.Typo.ui(size: 10))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    private var isEffectivelyDoubleColumn: Bool { bridge.epubEffectiveColumns >= 2 }

    // MARK: 翻页方式

    private var flowRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            sectionTitle("翻页")
            HStack(spacing: DS.Space.xs) {
                flowButton(title: "连续滚动", mode: .continuous)
                flowButton(title: "单页翻页", mode: .paged)
            }
        }
    }

    private func flowButton(title: String, mode: ReadingFlowMode) -> some View {
        let isActive = store.reader.flowMode == mode
        return Button(title) {
            store.reader.flowMode = mode
        }
        .buttonStyle(.plain)
        .font(DS.Typo.ui(size: 11, weight: isActive ? .semibold : .regular))
        .foregroundStyle(isActive ? DS.Palette.accent : DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(isActive ? DS.Palette.accentSoft : DS.Palette.surfaceSunken)
        )
    }


    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(DS.Typo.ui(size: 10, weight: .semibold))
            .foregroundStyle(DS.Palette.textTertiary)
    }
}

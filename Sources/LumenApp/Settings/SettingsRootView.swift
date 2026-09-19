import SwiftUI
import LumenKit

/// 设置页签。
///
/// 做成枚举而不是裸 `Int`：`--settings-tab interface` 这种自检参数需要按名字定位，
/// 而 `TabView` 的选中值一旦用整数，插一个页签就会把自检参数全部错位。
enum SettingsTab: String, CaseIterable {
    case reading
    case ai
    case interface
    case shortcuts
    case about

    init(launchArgument: String?) {
        self = SettingsTab(rawValue: launchArgument ?? "") ?? .reading
    }
}

struct SettingsRootView: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    @State private var selection = SettingsTab(launchArgument: LaunchOptions.settingsTab)

    var body: some View {
        TabView(selection: $selection) {
            ReadingSettingsPane()
                .tabItem { Label("阅读", systemImage: "book") }
                .tag(SettingsTab.reading)
                .environmentObject(state)
                .environmentObject(settings)

            AISettingsPane()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
                .environmentObject(state)
                .environmentObject(settings)

            InterfaceSettingsPane()
                .tabItem { Label("界面", systemImage: "switch.2") }
                .tag(SettingsTab.interface)
                .environmentObject(state)
                .environmentObject(settings)

            ShortcutsSettingsPane()
                .tabItem { Label("快捷键", systemImage: "command") }
                .tag(SettingsTab.shortcuts)
                .environmentObject(state)
                .environmentObject(settings)

            AboutPane()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(.top, DS.Space.s)
    }
}

// MARK: - 阅读设置

struct ReadingSettingsPane: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("主题") {
                ThemeSwatchPicker(selection: $settings.reader.themeID)
                    .padding(.vertical, DS.Space.xs)

                Text("主题同时作用于 PDF 背景与 EPUB 排版。切换 EPUB 主题不会重新加载页面，因此不会闪烁。")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("排版") {
                Picker("字体类别", selection: $settings.reader.fontFamily) {
                    ForEach(ReadingFontFamily.allCases) { family in
                        Text(family.displayName).tag(family)
                    }
                }

                FontFamilyPicker(
                    selection: $settings.reader.readingFontFamilyName,
                    fallbackLabel: "跟随「\(settings.reader.fontFamily.displayName)」",
                    initialGroup: settings.reader.fontFamily.catalogGroup
                )

                Picker("对齐", selection: $settings.reader.textAlign) {
                    ForEach(ReadingTextAlign.allCases) { align in
                        Text(align.displayName).tag(align)
                    }
                }
                .pickerStyle(.segmented)

                LabeledSlider(
                    title: "字号",
                    value: $settings.reader.fontScale,
                    range: 0.6...2.4,
                    step: 0.05,
                    valueText: { String(format: "%.0f%%", $0 * 100) }
                )

                LabeledSlider(
                    title: "行高",
                    value: $settings.reader.lineHeight,
                    range: 1.2...2.6,
                    step: 0.05,
                    valueText: { String(format: "%.2f", $0) }
                )

                LabeledSlider(
                    title: "字距",
                    value: $settings.reader.letterSpacing,
                    range: 0...0.12,
                    step: 0.005,
                    // 不带单位：滑块数值区宽度有限，带 " em" 会折成两行
                    valueText: { String(format: "%.3f", $0) }
                )

                Text("正文宽度随阅读区域自动调整；双栏在窄窗口下自动显示为单栏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledSlider(
                    title: "段间距",
                    value: $settings.reader.paragraphSpacing,
                    range: 0...1.6,
                    step: 0.1,
                    valueText: { String(format: "%.1f em", $0) }
                )

                Toggle("PDF 保持原色", isOn: $settings.reader.pdfOriginalColors)
                    .help("关闭后，PDF 纸张与缩略图跟随阅读主题；彩图也会随之着色。原文件不受影响。")
                LabeledSlider(
                    title: "PDF 画布亮度",
                    value: $settings.reader.pdfCanvasBrightness,
                    range: 0.5...1.0,
                    step: 0.02,
                    valueText: { String(format: "%.0f%%", $0 * 100) }
                )

                Text("""
                字体、字号、行高、字距、对齐**只对 EPUB 正文生效**。\
                PDF 是固定版式，正文字体无法替换（那需要重写页面内容流），\
                PDF 可选择整页阅读色调或保持原色；下方画布亮度仅影响页面外围。
                """)
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("翻页") {
                Toggle("EPUB 双栏阅读", isOn: $settings.reader.epubDoubleColumn)
                    .help("双栏以左右两页排版；窄于 760 点时自动回到单栏。")
                Picker("模式", selection: $settings.reader.flowMode) {
                    ForEach(ReadingFlowMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("EPUB 滚动到章末自动进入下一章", isOn: $settings.reader.autoAdvanceOnScrollEnd)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - 主题色块选择器

struct ThemeSwatchPicker: View {

    @Binding var selection: ReadingThemeID

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ForEach(ReadingTheme.all, id: \.id) { theme in
                Button {
                    withAnimation(DS.Motion.quick) { selection = theme.id }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                                .fill(theme.background)
                                .overlay(
                                    // 一个小的排版示意，让色块不只是纯色
                                    VStack(alignment: .leading, spacing: 2.5) {
                                        Capsule().fill(theme.text.opacity(0.85)).frame(width: 26, height: 3)
                                        Capsule().fill(theme.text.opacity(0.45)).frame(width: 34, height: 2)
                                        Capsule().fill(theme.text.opacity(0.45)).frame(width: 30, height: 2)
                                        Capsule().fill(theme.text.opacity(0.45)).frame(width: 33, height: 2)
                                    }
                                    .padding(.horizontal, 6),
                                    alignment: .topLeading
                                )
                                .frame(width: 56, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                                        .strokeBorder(
                                            selection == theme.id ? DS.Palette.accent : DS.Palette.separator,
                                            lineWidth: selection == theme.id ? 2 : 0.5
                                        )
                                )

                            if selection == theme.id {
                                VStack {
                                    Spacer()
                                    HStack {
                                        Spacer()
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(DS.Typo.ui(size: 12))
                                            .foregroundStyle(DS.Palette.accent)
                                            .background(Circle().fill(theme.background).padding(1))
                                            .padding(3)
                                    }
                                }
                                .frame(width: 56, height: 40)
                            }
                        }

                        Text(theme.id.displayName)
                            .font(DS.Typo.ui(size: 10, weight: selection == theme.id ? .semibold : .regular))
                            .foregroundStyle(selection == theme.id ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(theme.id.displayName)
            }
        }
    }
}

// MARK: - 带数值的滑杆

struct LabeledSlider: View {

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var valueText: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Text(title)
                .frame(width: 84, alignment: .leading)
            if step > 0 {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(valueText(value))
                .font(DS.Typo.mono)
                .foregroundStyle(DS.Palette.textSecondary)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - 关于

struct AboutPane: View {

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x4F7BFF), Color(hex: 0x2F5BEA)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "book.closed.fill")
                    .font(DS.Typo.ui(size: 28))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: DS.Space.xs) {
                Text("流明 Lumen")
                    .font(DS.Typo.title)
                Text("版本 1.0.0")
                    .font(DS.Typo.callout)
                    .foregroundStyle(DS.Palette.textTertiary)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                InfoRow(label: "文档格式", value: "PDF · EPUB")
                InfoRow(label: "渲染引擎", value: "PDFKit · WebKit")
                InfoRow(label: "AI 接入", value: "BYOK · OpenAI 兼容协议")
                InfoRow(label: "数据目录", value: AppPaths.supportRoot.path)
            }
            .padding(DS.Space.l)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(DS.Palette.surfaceSunken)
            )

            Text("不建书库、不收集数据、不上传文档。\nAI 请求只发送你当前需要处理的那段文本。")
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity)
    }

    private struct InfoRow: View {
        let label: String
        let value: String
        var body: some View {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Text(label)
                    .font(DS.Typo.ui(size: 11.5))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: 72, alignment: .leading)
                Text(value)
                    .font(DS.Typo.ui(size: 11.5, design: .monospaced))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

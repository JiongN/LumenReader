import SwiftUI
import LumenKit

/// 「界面」设置页：面板宽度 + 动效。
///
/// 单独开一页而不是塞进「阅读」：这两类都是全局外壳行为，跟主题、字号这些
/// "读这本书时怎么显示"不是一回事。混在一起会让「阅读」页越堆越长。
struct InterfaceSettingsPane: View {

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            panelWidthSection

            Section("界面字体") {
                FontFamilyPicker(
                    selection: $settings.ui.uiFontFamilyName,
                    fallbackLabel: "系统默认",
                    initialGroup: .sansSerif
                )

                Text("""
                只影响侧栏、AI 面板、设置页与菜单。阅读正文的字体在「阅读」页单独设置——\
                界面字体重在信息密度，正文字体重在长时间阅读不累，这两件事的偏好通常不一样。

                页码与代码块始终使用等宽字体，不受此项影响。
                """)
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("动效") {
                Toggle("界面动效", isOn: $settings.ui.animationsEnabled)

                Picker("速度", selection: $settings.ui.motionSpeed) {
                    ForEach(MotionSpeed.allCases) { speed in
                        Text(speed.displayName).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.ui.animationsEnabled)

                Toggle("尊重系统「减弱动态效果」", isOn: $settings.ui.respectsSystemReduceMotion)
                    .disabled(!settings.ui.animationsEnabled)

                statusLine
            }

            Section {
                // 如实写出能力边界。写着"关闭动效"却还有一堆东西在动，比不提供开关更让人恼火。
                Text("""
                关闭后，面板开合、侧栏切换、命令面板、主题过渡都会瞬时完成。

                以下动画不受此开关控制，这是系统行为而非遗漏：列表展开收起、\
                菜单展开、以及按钮自带的按压反馈。
                """)
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 面板宽度

    /// 面板宽度的显式入口。
    ///
    /// 为什么要在「设置」里再做一遍已经能在窗口里拖的事：**可发现性**。
    /// 那两条分隔线视觉上只有 1pt，和原来的静态分割线长得一模一样，
    /// 用户不会去悬停它，也就不会知道它能拖——功能做完了却等于不存在。
    /// 这里给一个看得见、带数值、可复位的入口，代价只是多一个 Section。
    ///
    /// `range` / `defaultWidth` 从 `UISettings.PanelWidth` 取，不另写常量：
    /// 两处各写一份，迟早会变成「滑杆能拉到 500，但拖分隔线只能到 420」。
    private var panelWidthSection: some View {
        Section("面板宽度") {
            panelWidthRow(
                title: "侧栏",
                value: $settings.ui.sidebarWidth,
                range: UISettings.PanelWidth.sidebarRange,
                defaultWidth: UISettings.PanelWidth.sidebarDefault
            )
            panelWidthRow(
                title: "AI 面板",
                value: $settings.ui.aiPanelWidth,
                range: UISettings.PanelWidth.aiRange,
                defaultWidth: UISettings.PanelWidth.aiDefault
            )

            Text("""
            也可以直接在窗口里拖动面板之间的分隔线调整，双击分隔线恢复默认。\
            拖到边界会自动停住，越界值不会被写进配置。
            """)
            .font(DS.Typo.ui(size: 11))
            .foregroundStyle(DS.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一行宽度调节：滑杆 + 当前值 + 复位。
    private func panelWidthRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultWidth: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Text(title)
                Spacer(minLength: DS.Space.s)
                Text("\(Int(value.wrappedValue.rounded())) pt")
                    .font(DS.Typo.ui(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Palette.textSecondary)
                Button("复位") {
                    withAnimation(DS.Motion.panel) { value.wrappedValue = defaultWidth }
                }
                .buttonStyle(.link)
                .font(DS.Typo.ui(size: 11))
                // 已经在默认值时没有什么可复位的，按钮就该是灰的
                .disabled(abs(value.wrappedValue - defaultWidth) < 0.5)
            }
            Slider(value: value, in: range)
        }
    }

    /// 当前实际状态。系统偏好压过应用开关时，用户很容易以为设置没生效——
    /// 与其让他猜，不如直接把原因写出来。
    @ViewBuilder
    private var statusLine: some View {
        if MotionGate.isMuted {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.warning)
                Text(mutedReason)
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        } else {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.Palette.success)
                Text("动效已开启（\(settings.ui.motionSpeed.displayName)）")
                    .font(DS.Typo.ui(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private var mutedReason: String {
        if !settings.ui.animationsEnabled {
            return "动效已关闭"
        }
        return "系统已开启「减弱动态效果」，当前按您的设置尊重该偏好，因此动效处于静音状态"
    }
}

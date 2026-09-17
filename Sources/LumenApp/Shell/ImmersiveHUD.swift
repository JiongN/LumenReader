import SwiftUI
import LumenKit

/// 沉浸模式下那条「鼠标压到屏幕下沿才浮出来」的控制条。
///
/// 为什么不常驻：沉浸模式的全部意义就是「屏幕上只剩正文」。一条常驻的浮条再淡，
/// 也是一块持续存在的视觉噪声——那正是用户进来想摆脱的东西。所以它平时完全不在场。
///
/// 感应区刻意只取**底部 90pt 的窄带**，而不是整屏监听鼠标：
/// 整屏监听有两条路，都不好走——用一个覆盖全屏的透明层会挡住阅读区的划词与点击；
/// 用 `onContinuousHover` 挂在根视图上则拿不到「离窗口底部多远」这个判断依据。
/// 一条底部窄带既够用，又不干扰正文交互。
struct ImmersiveHUD: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var bridge: ReaderBridge

    @State private var isRevealed = false

    /// 感应带高度。够低才不碍事，够高才不至于让用户「摸不到」。
    private let sensorHeight: CGFloat = 90

    private var isEPUB: Bool { state.document?.kind == .epub }
    private var unitName: String { isEPUB ? "章" : "页" }

    var body: some View {
        if state.isImmersive {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(height: sensorHeight)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(DS.Motion.reveal) { isRevealed = inside }
                    }

                if isRevealed {
                    bar
                        .padding(.bottom, DS.Space.l)
                        .transition(.opacity.combined(with: .offset(y: 14)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var bar: some View {
        HStack(spacing: DS.Space.m) {
            Button {
                bridge.goToPreviousUnit?()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(bridge.currentUnitIndex <= 0)
            .help("上一\(unitName)")

            // 沉浸时阅读区那条状态条是收起的，跳页入口得在这儿补上，
            // 否则进了沉浸就没法跳页了（只能一页页翻）。
            Button {
                withAnimation(DS.Motion.palette) { state.isPageJumpVisible = true }
            } label: {
                Text(bridge.positionLabel.isEmpty ? "—" : bridge.positionLabel)
                    .monospacedDigit()
                    .font(DS.Typo.ui(size: 12, weight: .medium))
                    .contentTransition(.numericText())
                    .animation(DS.Motion.quick, value: bridge.positionLabel)
            }
            .buttonStyle(.plain)
            .help("点击跳转到指定\(unitName)（⌘G）")

            Button {
                bridge.goToNextUnit?()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(bridge.currentUnitIndex >= bridge.unitCount - 1)
            .help("下一\(unitName)")

            Divider().frame(height: 14)

            Button {
                state.setImmersive(false)
            } label: {
                Label("退出沉浸", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(DS.Typo.ui(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("退出沉浸模式（⌃⌘F）")
        }
        .foregroundStyle(DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
    }
}

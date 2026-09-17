import SwiftUI
import LumenKit

/// 轻提示条。居中悬浮在窗口上方，自动消失，不拦截点击。
///
/// 位置放在离顶 76pt 而不是最顶上：阅读区在扫描件时会有一条「这是扫描版」的提示条
/// 贴在顶部，两者叠在一起会把那条提示上的按钮挡住。让开这一带，两个提示可以共存。
struct ToastLayer: View {

    @EnvironmentObject private var state: AppState

    var body: some View {
        if let toast = state.toast {
            HStack(spacing: DS.Space.s) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(DS.Typo.ui(size: 12, weight: .semibold))
                    .foregroundStyle(toast.isError ? DS.Palette.danger : DS.Palette.success)

                Text(toast.message)
                    .font(DS.Typo.ui(size: 12))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    state.dismissToast()
                } label: {
                    Image(systemName: "xmark")
                        .font(DS.Typo.ui(size: 9, weight: .bold))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("关掉提示")
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .frame(maxWidth: 460, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(.thickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
            .allowsHitTesting(true)
            .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }
}

/// 长任务进度卡片（提取全文 / 逐页识别）。
///
/// 做成遮罩式的居中卡片而不是角落里的小转圈：这类任务要跑几分钟，
/// 期间用户会以为「应用卡住了」，需要看到它在做什么、做到哪一步、以及能取消。
struct BusyOverlay: View {

    @EnvironmentObject private var state: AppState

    var body: some View {
        if let busy = state.busy {
            ZStack {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()

                card(busy)
            }
            .transition(.opacity)
        }
    }

    private func card(_ busy: BusyState) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text(busy.title)
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
            }

            if !busy.detail.isEmpty {
                Text(busy.detail)
                    .font(DS.Typo.ui(size: 12))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = busy.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Palette.accent)
                Text("\(Int(progress * 100))%")
                    .font(DS.Typo.mono)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack {
                Spacer()
                Button("取消") { state.busyCancel?() }
                    .controlSize(.small)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(DS.Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 26, y: 10)
    }
}

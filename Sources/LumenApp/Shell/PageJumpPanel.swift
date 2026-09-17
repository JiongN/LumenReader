import SwiftUI
import LumenKit

/// 「跳转到指定页 / 章」输入条。
///
/// 为什么不直接用系统弹窗：SwiftUI 在 macOS 上的 `.alert` **只能放按钮，放不了输入框**
/// （`.alert(_:isPresented:actions:)` 的 actions 里加 TextField 会被直接忽略），
/// 而跳页必须输入。所以自己做一个小卡片 + 轻遮罩，交互手感与命令面板保持一致。
struct PageJumpPanel: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var bridge: ReaderBridge

    @State private var input = ""
    @FocusState private var isFocused: Bool

    private var isEPUB: Bool { state.document?.kind == .epub }
    private var unitName: String { isEPUB ? "章" : "页" }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
                .transition(.opacity)

            card
                // 锚点居中的轻微放大，和命令面板同一套语言
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "number")
                    .font(DS.Typo.ui(size: 13, weight: .medium))
                    .foregroundStyle(DS.Palette.textTertiary)

                TextField(isEPUB ? "章节序号" : "页码", text: $input)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.ui(size: 15))
                    .frame(width: 88)
                    .focused($isFocused)
                    .onSubmit(commit)

                Text("/ \(bridge.unitCount) \(unitName)")
                    .font(DS.Typo.ui(size: 12))
                    .foregroundStyle(DS.Palette.textTertiary)

                Button("跳转", action: commit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(parsedIndex == nil)
            }

            Text(hint)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(DS.Space.l)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(DS.Palette.surfaceRaised)
                .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(DS.Palette.separator, lineWidth: 0.5)
        )
        .frame(width: 320)
        // Esc 关闭。挂在卡片上而不是 ZStack 上：焦点在输入框里，
        // 按键要能被这条链上的处理器接到。
        .onExitCommand { dismiss() }
        .task {
            // 聚焦不能放在 onAppear 里同步做：那一帧输入框还没进响应链，
            // 设了 focus 也会被丢掉。让出一帧再聚焦才稳定。
            try? await Task.sleep(nanoseconds: 30_000_000)
            isFocused = true
        }
    }

    // MARK: - 输入解析

    /// 把输入解析成 **0-based** 的单元索引。
    ///
    /// 越界**不报错，直接钳到最近的一页**——用户输 9999 的意图显然是「跳到末尾」，
    /// 这时候弹一句「超范围」再让他重输，只是把一件事拆成两件。
    private var parsedIndex: Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let number = Int(trimmed) else { return nil }
        let total = bridge.unitCount
        guard total > 0 else { return nil }
        return min(max(number - 1, 0), total - 1)
    }

    /// 输入过程中的提示语。空输入时不占地方。
    private var hint: String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "输入序号后回车即可跳转" }
        guard let number = Int(trimmed) else { return "「\(trimmed)」不是数字" }
        guard let index = parsedIndex else { return "当前文档还没有可跳转的\(unitName)" }
        if number - 1 != index {
            return "超出范围，将跳到第 \(index + 1) \(unitName)"
        }
        return "跳到第 \(number) \(unitName)"
    }

    private func commit() {
        guard let index = parsedIndex else { return }
        // 跳转逻辑在 AppState 上，不在这里自己拼 locator：
        // 那样自检通道就得复制一份同样的代码，两份早晚会走岔。
        state.jump(toUnit: index)
        dismiss()
    }

    private func dismiss() {
        withAnimation(DS.Motion.palette) { state.isPageJumpVisible = false }
    }
}

import SwiftUI
import LumenKit

/// Zoom 模式只保留右上角退出入口。
struct ImmersiveHUD: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var keyBindings: KeyBindingStore

    var body: some View {
        if state.isImmersive {
            exitCircle
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// 右上角的圆形「退出 zoom」按钮。
    private var exitCircle: some View {
        Button {
            state.setImmersive(false)
        } label: {
            // 进入沉浸用的是「向四角张开」（arrow.up.left.and.arrow.down.right），
            // 退出就必须是它的镜像反转（arrow.down.right.and.arrow.up.left，
            // 与底部控制条上的「退出沉浸」同一符号），方向读反了用户会以为还能再放大。
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(DS.Typo.ui(size: 12, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(DS.Palette.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help(hint("退出 zoom（沉浸）模式", for: .toggleImmersive))
    }

    /// 把动作的当前绑定拼进提示。拿不到绑定（用户把它清空了）时只回标签本身。
    private func hint(_ label: String, for action: LumenAction) -> String {
        guard let combo = keyBindings.combo(for: action) else { return label }
        return "\(label)（\(combo.display)）"
    }
}

import SwiftUI

/// Lumen AI 标识 v3：一枚细线圆环 + 缺口处一枚实心点——「轨道上的焦点」。
///
/// 迭代记录：
/// v2 是双四芒星（sparkle）。废弃原因：四芒星已经是全行业的 AI 万能符号
/// （Cursor / Notion / Copilot 都在用），加上渐变后更没有自己的说法；
/// 且星形细节在工具栏 14pt 下糊成一团。
///
/// v3 的语义：环 = 阅读的回路（读 → 想 → 回到文中），点 = 那一下「照亮」。
/// 刻意做成单色 `currentColor`：工具栏里和其他图标一样是安静的墨色，
/// 只有选中态才染强调色——AI 是功能，不是霓虹灯。
struct OrbitRing: Shape {

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // 缺口开在右上 45°：从 280° 逆时针绕到 350°，留下 70° 的呼吸口
        p.addArc(
            center: c,
            radius: r,
            startAngle: .degrees(280),
            endAngle: .degrees(350),
            clockwise: false
        )
        return p
    }
}

struct AIIcon: View {

    var size: CGFloat = 14
    /// 默认跟随当前前景色（.primary）——与其他工具栏图标同权，
    /// 需要强调时由调用方显式传入 accent。
    var color: Color = .primary

    public var body: some View {
        ZStack {
            OrbitRing()
                .stroke(
                    style: StrokeStyle(lineWidth: size * 0.053, lineCap: .round)
                )
                .frame(width: size * 0.566, height: size * 0.566)

            Circle()
                .frame(width: size * 0.205, height: size * 0.205)
                .offset(x: size * 0.20, y: -size * 0.20)
        }
        .frame(width: size, height: size)
        .foregroundStyle(color)
    }
}

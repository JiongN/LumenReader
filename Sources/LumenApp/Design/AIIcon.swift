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
        // 环体是「缺口以外的那 290°」，不是「缺口那 70°」。
        //
        // 一度写成 `startAngle: 280, endAngle: 350, clockwise: false`——
        // 逆时针从 280° 走到 350° 只扫过 70°，画出来的正是**缺口本身**，
        // 于是整个字形塌成右下角一小截弧加一个点：实测墨迹只有 4pt 见方，
        // 而同栏的 SF Symbol 是 14pt。用户看到的是「一枚浮在空白里的小碎片」。
        //
        // 缺口开在右上 45°（280°…350°，居中在 315°）时，环要走另一边：
        // 从 280° 顺时钟递减到 350°，正好 290°。
        p.addArc(
            center: c,
            radius: r,
            startAngle: .degrees(280),
            endAngle: .degrees(350),
            clockwise: true
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
                    // 下限 1pt 是为了 1x（非高分屏）：size*0.07 在 14pt 下只有 0.98pt，
                    // 2x 屏上是 2 个物理像素、看着还好，1x 屏上就落在半像素上被
                    // 抗锯齿摊成一条灰雾。宁可细，也别在普通屏上糊掉。
                    style: StrokeStyle(lineWidth: max(1, size * 0.07), lineCap: .round)
                )
                // 0.78 而不是 0.566：14.5pt 的 SF Symbol 墨迹外框约 14pt、环类字形
                // 直径约 11pt；环体 0.78·size 才与同栏邻居等重。此前 0.566 的方案
                // 即使环画对了也只有 8.5pt，看起来像比别人小一号。
                .frame(width: size * 0.78, height: size * 0.78)

            Circle()
                .frame(width: size * 0.26, height: size * 0.26)
                // 点落在缺口里：距圆心 = 环半径（0.39·size），方向右上 45°
                // （0.276 = 0.39 / √2，保证点正落在环线上而不是飘在环外）
                .offset(x: size * 0.276, y: -size * 0.276)
        }
        .frame(width: size, height: size)
        .foregroundStyle(color)
    }
}

import AppKit
import PDFKit

/// 渲染保真自检：`--pdf-render-report 1`。
///
/// ## 它解决什么问题
///
/// 「关掉页面投影 / 页间留白会不会让观感变差」这件事，靠读代码答不了——必须**看图**。
/// 而要比图，就得保证两次运行截的是**同一页、同一倍率、同一视口**，否则像素差异里
/// 分不清「旋钮造成的」和「位置/缩放造成的」。
///
/// 所以本通道只做一件事：**把渲染状态钉死**，然后交给既有的 `--capture` 去截图。
/// 它自己**不截图**——一条命令就能同时拿到图与「这次用的是哪套旋钮」的日志。
///
/// ## 用法（两次运行只有旋钮不同）
///
/// ```bash
/// BIN=dist/Lumen.app/Contents/MacOS/Lumen
/// # 基线（默认，= 改造前）
/// $BIN --open /tmp/lumen-test/large.pdf --window-size 1400x900 --sidebar 0 --ai 0 \
///      --pdf-render-report 1 --capture /tmp/render-baseline.png --capture-delay 8
/// # 瘦身件（关投影 + 关页间留白）
/// $BIN --open /tmp/lumen-test/large.pdf --window-size 1400x900 --sidebar 0 --ai 0 \
///      --pdf-render-slim 1 --pdf-render-report 1 --capture /tmp/render-slim.png --capture-delay 8
/// ```
///
/// 两张图再交给 `tools/image_diff.swift` 出「多少比例像素不同、最大通道差多少」的客观读数，
/// 人眼再核对「差在哪、算不算退化」。
///
/// ⚠️ **先做噪声地板**：同配置跑两次互比，必须是 **0.000%**（本机实测如此），
/// 否则说明截图本身有抖动，任何差异都不能归因给旋钮。另外「关页间留白」会让重排更慢，
/// `--capture-delay` 给足（8s 时抓到过尚未落定的中间态，14s 才稳），否则会截到残缺画面。
///
/// 实测结论见 `docs/VERIFY.md` 第七节：关投影 **0.000%**（无作用），关页间留白 **17.5%**（页面上移、分隔消失）。
@MainActor
enum PDFRenderAudit {

    /// 对比用的锚点页（0-based）。固定第 1 页：有正文、页首有标题，任何视觉差异都容易看出来。
    static let anchorPage = 0

    static func run(controller: PDFController) async {
        guard controller.pageCount > 0 else {
            NSLog("[Lumen][pdf] 渲染自检：没有文档，跳过")
            return
        }

        controller.go(to: anchorPage)
        // 适宽倍率：由 view 宽度算出，所以两次对比必须同窗口尺寸、同面板可见性。
        // 显式写死而不是依赖 autoScales 的懒重算，是为了「现在就定下来」。
        controller.view.scaleFactor = controller.view.scaleFactorForSizeToFit

        // 等重排与重光栅化落定——否则截到的可能是上一页的残影，像素差异里会混进无关变化。
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let tuning = PDFRenderTuning.current
        let view = controller.view
        NSLog("[Lumen][pdf] 渲染自检锚点：第 \(anchorPage + 1) 页，倍率 "
            + String(format: "%.4f", view.scaleFactor)
            + "，视口 " + String(format: "%.0fx%.0f", view.bounds.width, view.bounds.height)
            + "，旋钮 " + tuning.summary
            + "（接下来由 --capture 截图，两张图应可直接逐像素比）")
    }
}

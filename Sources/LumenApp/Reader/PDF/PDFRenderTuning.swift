import Foundation
import PDFKit

/// PDF 渲染管线的三个旋钮 —— 「滚动卡顿」定位里被**逐个证伪**的那三个。
///
/// ## 背景：用户实机数据把矛头指向 PDFKit 渲染
///
/// 用户实机 `--jank-watch`（2 秒一窗）的活跃段读数：进程 CPU 在 2 秒里烧掉 **5.9–6.8 秒**（≈3 个核），
/// 而同一窗口里我们这层所有 SwiftUI 计数器（`body/ai/side/thumbBody/update/layout/draw/thumbR`）
/// **全是 0 或个位数**。两件事合起来只说明一件事：**重活在 PDFKit 的渲染 / 合成里，不在视图树里**。
/// 于是盯住 PDFKit 三个「默认就开着（或我们写死）」的旋钮：
///
/// | 旋钮 | 原值 | 连续滚动时可能有的代价 |
/// | --- | --- | --- |
/// | `pageShadowsEnabled` | PDFKit 默认 **YES** | 每页边框的投影在滚动中持续参与合成 |
/// | `displaysPageBreaks` | PDFKit 默认 **YES** | 页间留白随每页绘制 |
/// | `interpolationQuality` | 我们写死 **`.high`** | 每次重绘整页都走高成本重采样 |
///
/// ## 结论：三个旋钮都省不下来 —— 瓶颈是 PDFKit 内部整页光栅化
///
/// 单变量实测（交错重跑 3 轮取中位数；`--jank-report`，驱动 1900px/步、120 步、`large.pdf`；
/// 读数表见 `docs/VERIFY.md` 第七节）：
///
/// | 配置 | CPU ms/步（中位） | 相对基线 |
/// | --- | --- | --- |
/// | 基线（投影开 / 留白开 / high） | **17.7** | — |
/// | 关投影 | 19.1 | 无收益（高出来的量在噪声内、且**观感逐像素完全一致**，见下） |
/// | 关页间留白 | 18.9 | **更费 ~1ms** |
/// | 插值 none | 17.2 | 略低 ~0.4ms（在噪声内） |
/// | 关投影 + 关留白 | 19.9 | **更费 ~2ms** |
///
/// **不但没有收益，关掉页间留白反而更费**：页挨页贴在一起后，同样 1900px 的一步会跨过更多页，
/// 每步要光栅化的页内容更多。保真对比（`--pdf-render-report` + `tools/image_diff.swift`；
/// 同配置两次运行的**噪声地板 = 0.000%**，即该工具精确到像素）进一步说明：
///
/// - 关投影：`legacy` vs `legacy+关投影` **0.000% 差异 —— 逐像素完全一致**。
///   这个开关在本配置（`singlePageContinuous` + 适宽倍率）下**根本不起作用**，是纯死重。
/// - 关页间留白：**17.5% 像素不同**，表现为页面整体上移约 22px、页间分隔消失（观感变了）。
///   而且该组合的重排更慢更不稳（`--capture-delay 8` 时抓到过尚未落定的中间态）。
///
/// 因此**默认维持原样**（`baseline`，即 PDFKit 默认 + `.high`，与改造前逐像素一致）。
/// 这套旋钮 + 开关保留下来，是为了：①留存「已证伪」的证据；②日后换文档 / 换机器能一键复跑对照。
/// 它**不是**一个待生效的优化。
struct PDFRenderTuning: Equatable {

    /// 页边框投影。PDFKit 默认 YES。
    var pageShadows: Bool
    /// 页间留白 / 分隔。PDFKit 默认 YES。
    var pageBreaks: Bool
    /// 重绘插值质量。PDFKit 只有 `none` / `low` / `high`（**没有 `.medium`**，见 SDK `PDFView.h:43`）。
    var interpolation: PDFInterpolationQuality

    /// **优化前的原样 = 也是当前默认**：PDFKit 默认值 + 我们原来写死的 `.high`。
    ///
    /// 默认就用它，等于「本次证伪之后什么都没改」——这正是实测支持的结论（三旋钮省不下 CPU）。
    static let baseline = PDFRenderTuning(pageShadows: true, pageBreaks: true, interpolation: .high)

    /// 本次尝试过的「瘦身件」：关页面投影 + 关页间留白。
    ///
    /// **不作默认**。实测 CPU/步没有下降（甚至更费），且会把页间分隔抹掉、页面整体上移。
    /// 保留它只为复跑对照（`--pdf-render-slim 1` 一键切过去）。
    static let slim = PDFRenderTuning(pageShadows: false, pageBreaks: false, interpolation: .high)

    /// 本次进程实际采用的旋钮。
    ///
    /// 优先级：`baseline` 默认 → `--pdf-render-slim 1` 整体切到瘦身件 → 单项开关逐个覆盖。
    /// 单变量对照就是靠这个顺序：默认拉回基线，再单独打开一个开关。
    static var current: PDFRenderTuning {
        var tuning = Self.baseline
        if LaunchOptions.pdfRenderSlim { tuning = .slim }
        if let shadows = LaunchOptions.pdfPageShadows { tuning.pageShadows = shadows }
        if let breaks = LaunchOptions.pdfPageBreaks { tuning.pageBreaks = breaks }
        if let quality = Self.interpolationFromLaunch() { tuning.interpolation = quality }
        return tuning
    }

    var interpolationLabel: String {
        switch interpolation {
        case .high: return "high"
        case .low:  return "low"
        default:    return "none"
        }
    }

    /// 是否等于「原样」。用于日志里一句话说清「这次到底改没改渲染」。
    var isBaseline: Bool { self == PDFRenderTuning.baseline }

    /// 一行摘要，写进日志便于「这次跑的是哪一套」可核对。
    var summary: String {
        "投影=\(pageShadows ? "开" : "关") 页间留白=\(pageBreaks ? "开" : "关") 插值=\(interpolationLabel)"
    }

    // MARK: - 解析

    /// `--pdf-interpolation high|low|none`。取值非法时告警并忽略（不猜）。
    private static func interpolationFromLaunch() -> PDFInterpolationQuality? {
        guard let raw = LaunchOptions.value(for: "--pdf-interpolation")?.lowercased() else { return nil }
        switch raw {
        case "high", "h", "2":  return .high
        case "low", "l", "1":   return .low
        case "none", "off", "0": return PDFInterpolationQuality.none
        default:
            NSLog("[Lumen][pdf] 未知的 --pdf-interpolation 取值「\(raw)」（可选 high / low / none），已忽略")
            return nil
        }
    }

    // MARK: - 动态插值方案（只评估，不实现）

    /// 「滚动中降到 `.low`、停下后切回 `.high`」这个动态方案的评估结论。
    ///
    /// **建议：不做。** 三条理由：
    /// 1. **收益微乎其微**。单变量实测里插值三档在 CPU/步 上的差值（`none` 比 `high` 低约 0.4ms）
    ///    落在运行间噪声内，为这点收益引入一个状态机不划算。
    /// 2. **触发时机本身不可靠**。`PDFView` 不发「滚动开始 / 结束」通知（没有对应 API），
    ///    只能靠 `NSScrollView` 的 `boundsDidChange` + 定时器静默判定「停下来了」。
    ///    停顿判定一旦不准，用户就会看到「字在滚动途中突然变糊 / 停下后迟迟不恢复清晰」——
    ///    这是**比慢一点更刺眼**的缺陷。
    /// 3. **会破坏「所见即所存」**。用户停下后立刻截屏 / 复制为图片时，若那一刻还停在低档，
    ///    拿到的就是低质量渲染。
    ///
    /// 若将来真要压最后一截，优先级应该是「限制连续模式下的预渲染范围」，
    /// 而不是动态抖动插值质量档次。
    static let dynamicInterpolationNote = "不建议做（见源码注释 PDFRenderTuning.dynamicInterpolationNote）"
}

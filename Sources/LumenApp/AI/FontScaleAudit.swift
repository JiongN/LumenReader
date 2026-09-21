import Foundation
import AppKit
import LumenKit

/// 字号快捷键与边界自检：`--font-scale-report 1`。
///
/// 存在理由：用户报「⌘- 没反应」。根因有两层——
///
/// 1. **格式假可用**：`isEnabled` 只查「有没有文档」，不查格式，PDF 下字号动作
///    被整包吞掉却什么都不做。现已拆成 `kind == .epub`，并在 PDF 下由
///    `GlobalShortcutRouter` 弹一句 `disabledHint`。
/// 2. **浮点脏值陷阱**：用户 settings.json 里真实存着 `0.6000000000000001`
///    （0.6 的浮点误差累积）。旧 `min(max(c - 0.1, 0.6), 2.4)` 算出 `0.6`，
///    但 `0.6 != 0.6000000000000001`（差 1e-16），若用「新值==旧值 才判到边界」
///    这种写法会判成「成功应用」——bug 原样保留，代码却看着像修好了。
///    本通道用容差 + 吸附重写，并断言这条 case 真的落到 `atLimit`。
///
/// 因为开关以 `-report` 结尾，`LaunchOptions.isAuditRun` 自动成立 →
/// `SettingsStore.suppressSave` 自动开、数据目录切临时（若设了 `LUMEN_TEST_DATA`），
/// 所以自检不会污染用户的 settings.json（见末尾的自证断言）。
extension LaunchOptions {
    static var fontScaleReport: Bool { flag("--font-scale-report") }
}

@MainActor
enum FontScaleAudit {

    static func run(services: AppServices) {
        guard LaunchOptions.fontScaleReport else { return }

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][fontscale] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        // 基准摘要在**动任何状态之前**取一次，末尾再取一次比对。
        //
        // 这里原先写的是「连着取两次再比」——两次之间什么都没发生，永远相等，
        // 是一条**恒真断言**（README 硬约束第 8 条），等于没验。现在基准取在自检开始处，
        // 自检期间任何人往 settings 里写东西都会被这条抓住。
        //
        // 取两份：`AppPaths.settingsFile` 是本次运行实际用的（自检模式下已被重定向到临时目录），
        // `AppPaths.realSupportRoot` 下面那份才是**用户真实配置**——最要紧的是它不能被动到。
        let auditSettingsStart = digest(AppPaths.settingsFile)
        let realSettingsStart = digest(AppPaths.realSupportRoot.appendingPathComponent("settings.json"))

        // ── 1) 表驱动 FontScale.next：含用户那个脏值 case ──
        let cases: [(current: Double, delta: Double, expect: FontScaleStep)] = [
            // 用户报的现场：干净的 0.6 按 ⌘- → 到下限
            (0.6, -0.1, .atLimit(scale: 0.6, isMin: true)),
            // 浮点脏值那一版：必须同样判到下限，且吸附成干净 0.6（专治「修了但没修好」）
            (0.6000000000000001, -0.1, .atLimit(scale: 0.6, isMin: true)),
            // 上限那一版
            (2.4, 0.1, .atLimit(scale: 2.4, isMin: false)),
            // 正常生效
            (1.0, 0.1, .applied(scale: 1.1)),
            // 夹到下限但确实变了 0.65 → 0.6，不能误报 atLimit
            (0.65, -0.1, .applied(scale: 0.6)),
            // 容差方向：< 1e-9 视为无变化（吸附到原值）
            (1.0, 1e-10, .atLimit(scale: 1.0, isMin: false)),
            // 容差方向：≥ 1e-9 视为真变化（applied）
            (1.0, 1e-8, .applied(scale: 1.00000001)),
        ]
        for c in cases {
            let got = FontScale.next(current: c.current, delta: c.delta)
            check("FontScale.next(\(format(c.current)), \(format(c.delta))) → \(describe(c.expect))",
                  got == c.expect,
                  "得到 \(describe(got))")
        }

        // ── 2) isEnabled 格式分发：EPUB 可用 / PDF 禁用，反向对照 showThumbnails ──
        let epubWS = AppState(services: services)
        epubWS.add(ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/lumen-fontscale-audit.epub"), kind: .epub)))
        let pdfWS = AppState(services: services)
        pdfWS.add(ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/lumen-fontscale-audit.pdf"), kind: .pdf)))

        // 注意每个动作都写全 `LumenAction.` 前缀：`check(_:_:_:)` 的第二个参数是
        // `Bool`，前导点写法（`.fontIncrease…`）在这里没有可推导的上下文类型，编译不过。
        check("EPUB 下 fontIncrease 可用", LumenAction.fontIncrease.isEnabled(in: epubWS))
        check("EPUB 下 fontDecrease 可用", LumenAction.fontDecrease.isEnabled(in: epubWS))
        check("PDF 下 fontIncrease 禁用", !LumenAction.fontIncrease.isEnabled(in: pdfWS))
        check("PDF 下 fontDecrease 禁用", !LumenAction.fontDecrease.isEnabled(in: pdfWS))
        // 反向对照：showThumbnails 应当 PDF 可用、EPUB 禁用，证明确实在区分格式而非恒真。
        check("PDF 下 showThumbnails 可用（反向对照）", LumenAction.showThumbnails.isEnabled(in: pdfWS))
        check("EPUB 下 showThumbnails 禁用（反向对照）", !LumenAction.showThumbnails.isEnabled(in: epubWS))

        // ── 3) disabledHint 一致性：禁用且有 hint 的动作，hint 不得为空串 ──
        var emptyHintHits = 0
        for action in LumenAction.allCases {
            let enabled = action.isEnabled(in: pdfWS)
            if let hint = action.disabledHint, enabled == false, hint.isEmpty {
                emptyHintHits += 1
            }
        }
        check("禁用且有 hint 的动作，hint 均非空串", emptyHintHits == 0,
              "空串命中 \(emptyHintHits) 个")
        check("fontDecrease 在 PDF 下声明了 hint", LumenAction.fontDecrease.disabledHint != nil)

        // ── 4) 行为回读：到下限再按一次，值必须逐位不变 ──
        // 直接用用户真实的脏值（audit 载入的是真实 settings.json，suppressSave 已开），
        // 复现「按了 ⌘- 没反应」的现场，并断言吸附后停在干净的 0.6、且再按一次仍不变。
        let probe = AppState(services: services)
        probe.add(ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/lumen-fontscale-audit.epub"), kind: .epub)))

        var step = probe.stepFontScale(by: -0.1)
        while case .applied = step { step = probe.stepFontScale(by: -0.1) }
        let atLimitValue = probe.settingsStore.reader.fontScale
        check("连续按 ⌘- 直到 atLimit", step == .atLimit(scale: atLimitValue, isMin: true),
              "末态 \(describe(step))，落点 \(format(atLimitValue))")
        // 再按一次：必须仍是 atLimit，且值逐位相等（Double 直接 ==，因为吸附已清成干净边界）。
        let reStep = probe.stepFontScale(by: -0.1)
        let reAtLimit = reStep == .atLimit(scale: atLimitValue, isMin: true)
        let bitIdentical = reStep.scale == atLimitValue
        check("到下限再按一次仍 atLimit 且值逐位不变", reAtLimit && bitIdentical,
              "reStep=\(describe(reStep)) 值=\(format(reStep.scale)) 期望=\(format(atLimitValue))")

        // ── 5) 自证：自检过程不得改写 settings.json ──
        // `suppressSave` 已因 isAuditRun 由 WindowManager 打开，所以这里应当完全一致。
        let auditSettingsEnd = digest(AppPaths.settingsFile)
        check("自检期间 settings.json 未被改写（开始/结束摘要一致）",
              auditSettingsStart != nil && auditSettingsStart == auditSettingsEnd,
              "start=\(auditSettingsStart ?? "读不到") end=\(auditSettingsEnd ?? "读不到")")

        // 用户真实配置：读不到就**如实跳过**，不报通过（否则这条会退化成恒真）。
        let realSettingsEnd = digest(AppPaths.realSupportRoot.appendingPathComponent("settings.json"))
        if let s = realSettingsStart, let e = realSettingsEnd {
            check("用户真实 settings.json 未被触碰（开始/结束摘要一致）", s == e,
                  "start=\(s) end=\(e)")
        } else {
            NSLog("%@", "[Lumen][fontscale] ⚠️ 读不到用户真实 settings.json（\(AppPaths.realSupportRoot.path)），"
                  + "「未触碰真实配置」这一项**跳过，不报通过**")
        }

        NSLog("%@", "[Lumen][fontscale] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    // MARK: - 辅助

    private static func describe(_ step: FontScaleStep) -> String {
        switch step {
        case .applied(let s): return ".applied(\(format(s)))"
        case .atLimit(let s, let isMin): return ".atLimit(\(format(s)), isMin: \(isMin))"
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.17g", value)
    }

    /// 文件内容的 64 位 FNV-1a 摘要（十六进制）。
    ///
    /// 为什么不用 MD5：这不是安全用途（只判「两次读到的字节是不是同一份」），
    /// 而 `CommonCrypto` 的 `CC_MD5` 自 macOS 10.15 起已弃用、编译期就报 warning。
    /// 算法与 `AppPaths.stableHash` 同一套，零依赖。
    private static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

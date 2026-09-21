import Foundation

/// OCR 右键菜单自检：`--ocr-menu-report 1`。
///
/// 为什么要单开一条：右键菜单**没法自动化验证**——这台机器没有辅助功能权限，
/// 合成不出真实的右键事件，截图也拍不到原生菜单。所以把「该出现哪些项、该叫什么文案、
/// 该不该禁用」这段**判定**抽成纯函数 `PDFContextMenuPlanner.items`，
/// 在这里做**表驱动**断言：每一行输入 → 期望输出，逐项核对。
///
/// 这是可证伪的：把 planner 里「无条件加 OCR 项」或「已识别 → 重新识别」任一处改错，
/// 对应的行立刻红，而不是靠读代码相信菜单是对的。
@MainActor
enum OCRMenuAudit {

    static func run() {
        guard LaunchOptions.ocrMenuReport else { return }

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("%@", "[Lumen][ocr-menu] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        // 表驱动：每行是（命中批注、批注有正文、OCR 状态）→ 期望的追加项数组。
        struct Row {
            let name: String
            let annotationHit: Bool
            let hasContents: Bool
            let ocr: OCRMenuDescriptor
            let expected: [PDFContextMenuItem]
        }

        let rows: [Row] = [
            // ① 空白处右键：没有批注动作，只剩 OCR 入口。
            Row(name: "空白处 + 未识别 → 只有「识别本页文字（OCR）」",
                annotationHit: false, hasContents: false, ocr: .idle,
                expected: [.ocr(.idle)]),
            // ② 命中批注且有正文：删除 + 拷贝 + OCR。
            Row(name: "命中批注(有正文) + 未识别 → 删除/拷贝/OCR",
                annotationHit: true, hasContents: true, ocr: .idle,
                expected: [.deleteAnnotation, .copyAnnotation, .ocr(.idle)]),
            // ③ 命中批注但没有正文：不给「拷贝批注内容」（拷出来是空的没意义）。
            Row(name: "命中批注(无正文) → 删除/OCR（不含拷贝）",
                annotationHit: true, hasContents: false, ocr: .idle,
                expected: [.deleteAnnotation, .ocr(.idle)]),
            // ④ 正在识别：OCR 项仍在，但状态为 running（文案「识别中…」、禁用）。
            Row(name: "识别中 → OCR 项变为 running（禁用）",
                annotationHit: false, hasContents: false, ocr: .running,
                expected: [.ocr(.running)]),
            // ⑤ 已识别过：文案应为「重新识别本页文字」，且仍可点。
            Row(name: "已识别过 → 文案为重新识别",
                annotationHit: false, hasContents: false, ocr: .alreadyDone,
                expected: [.ocr(.alreadyDone)]),
        ]

        for row in rows {
            let got = PDFContextMenuPlanner.items(
                annotationHit: row.annotationHit,
                annotationHasContents: row.hasContents,
                ocr: row.ocr
            )
            check(row.name, got == row.expected, "得到 \(got)，期望 \(row.expected)")
        }

        // 文案与启用状态的独立断言：不能只核对枚举相等——枚举对了但 `title` / `isEnabled`
        // 写错，用户看到的仍然是错的。
        check("running 文案是「识别中…」", OCRMenuDescriptor.running.title == "识别中…",
              "实际「\(OCRMenuDescriptor.running.title)」")
        check("running 禁用", !OCRMenuDescriptor.running.isEnabled)
        check("idle 文案是「识别本页文字（OCR）」", OCRMenuDescriptor.idle.title == "识别本页文字（OCR）",
              "实际「\(OCRMenuDescriptor.idle.title)」")
        check("idle 可点", OCRMenuDescriptor.idle.isEnabled)
        check("alreadyDone 文案是「重新识别本页文字」",
              OCRMenuDescriptor.alreadyDone.title == "重新识别本页文字",
              "实际「\(OCRMenuDescriptor.alreadyDone.title)」")
        check("alreadyDone 可点（重新识别是一次新的付费动作，不能禁用）",
              OCRMenuDescriptor.alreadyDone.isEnabled)

        // OCR 项永远在末尾：任何输入下，追加项数组的最后一项都必须是 ocr。
        for row in rows {
            let items = PDFContextMenuPlanner.items(
                annotationHit: row.annotationHit,
                annotationHasContents: row.hasContents,
                ocr: row.ocr
            )
            let ocrIsLast: Bool
            if case .ocr = items.last { ocrIsLast = true } else { ocrIsLast = false }
            check("OCR 项恒在末尾（\(row.name)）", ocrIsLast, "实际 \(items)")
        }

        NSLog("%@", "[Lumen][ocr-menu] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }
}

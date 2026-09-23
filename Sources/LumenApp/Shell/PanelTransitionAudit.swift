import Foundation
import AppKit
import LumenKit

extension LaunchOptions {
    static var panelTransitionReport: Bool { flag("--panel-transition-report") }
}

/// Checks visibility, scale restoration and reading position. Layout counters
/// alone cannot prove that a PDF is visible or that an interaction is smooth.
@MainActor
enum PanelTransitionAudit {
    static func run(state: AppState) async {
        try? await Task.sleep(nanoseconds: 2_600_000_000)
        let bridge = state.bridge
        guard let probe = bridge.panelTransitionProbe,
              let reset = bridge.resetPanelTransitionTrace else {
            NSLog("%@", "[Lumen][panel] FAIL: PDF probe unavailable")
            return
        }
        var failures = 0
        var passed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failures += 1 }
            NSLog("%@", "[Lumen][panel] \(condition ? "PASS" : "FAIL"): \(name)")
        }
        let originalSidebar = state.isSidebarVisible
        let originalAI = state.isAIPanelVisible
        typealias Leg = (String, (Bool) -> Void, () -> Bool)
        let legs: [Leg] = [
            ("sidebar", { state.setSidebarVisible($0) }, { state.isSidebarVisible }),
            ("AI", { state.setAIPanelVisible($0) }, { state.isAIPanelVisible })
        ]
        for (name, set, get) in legs {
            for _ in 0..<2 {
                reset()
                let before = probe()
                let target = !get()
                set(target)
                check("\(name) visibility changed", get() == target)
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard let after = probe(), let before else {
                    check("\(name) probe retained", false)
                    continue
                }
                check("\(name) one begin/end", after.trace.enters == 1 && after.trace.exits == 1)
                check("\(name) restores scale mode", after.autoScalesNow == before.autoScalesNow)
                if let a = after.trace.anchorAtEnter.first, let b = after.trace.anchorAtExit.first {
                    check("\(name) reading anchor preserved", a.page == b.page && abs(a.progress - b.progress) <= 0.05)
                } else {
                    check("\(name) anchor measured", false)
                }
            }
        }
        state.setSidebarVisible(originalSidebar, animated: false)
        state.setAIPanelVisible(originalAI, animated: false)
        NSLog("%@", "[Lumen][panel] Result: \(passed) passed, \(failures) failed. Visual blanking and latency require separate checks.")
    }
}

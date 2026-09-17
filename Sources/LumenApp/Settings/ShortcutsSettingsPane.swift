import SwiftUI
import AppKit
import LumenKit

/// 「快捷键」设置页。
///
/// 列表由 `LumenAction` 生成，不手写：菜单栏、命令面板、这一页三处显示的组合键
/// 都取自同一个 `KeyBindingStore`，不可能出现「设置里写 ⌘⇧R、菜单里显示 ⌘R」。
struct ShortcutsSettingsPane: View {

    @EnvironmentObject private var keyBindings: KeyBindingStore

    @State private var rejection: String?

    var body: some View {
        Form {
            if let rejection {
                Section {
                    Label(rejection, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Typo.ui(size: 11.5))
                        .foregroundStyle(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Text("""
                点右边的组合键开始录制，按 Esc 取消，按 Delete 清空。\
                清空后菜单项依然在，只是没有快捷键——不是每一项都值得占用一个组合键。
                """)
                .font(DS.Typo.ui(size: 11))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(LumenActionGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.actions) { action in
                        row(for: action)
                    }
                }
            }

            Section {
                HStack {
                    Text("已改 \(customizedCount) 项，共 \(LumenAction.allCases.count) 项")
                        .font(DS.Typo.ui(size: 11))
                        .foregroundStyle(DS.Palette.textSecondary)

                    Spacer()

                    Button("全部恢复默认") {
                        keyBindings.resetAll()
                        rejection = nil
                    }
                    .font(DS.Typo.ui(size: 11.5))
                    .disabled(!keyBindings.hasAnyCustomization)
                }
            } footer: {
                Text("⌘Q、⌘H、⌘, 这类系统组合不会被接受——它们一旦被占用，你就找不回退出与隐藏窗口了。")
                    .font(DS.Typo.ui(size: 10.5))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 单行

    private func row(for action: LumenAction) -> some View {
        HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(DS.Typo.ui(size: 12.5))
                    .foregroundStyle(DS.Palette.textPrimary)

                if keyBindings.isCleared(action) {
                    Text("已清空")
                        .font(DS.Typo.ui(size: 10))
                        .foregroundStyle(DS.Palette.warning)
                } else if keyBindings.isCustomized(action) {
                    Text("默认是 \(action.defaultCombo.display)")
                        .font(DS.Typo.ui(size: 10))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }

            Spacer(minLength: DS.Space.s)

            if keyBindings.isCustomized(action) {
                Button {
                    keyBindings.reset(action)
                    rejection = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(DS.Typo.ui(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("恢复默认（\(action.defaultCombo.display)）")
            }

            ShortcutRecorder(combo: keyBindings.combo(for: action)) { combo in
                commit(combo, for: action)
            }
            .frame(width: 138, height: 24)
        }
        .padding(.vertical, 1)
    }

    private func commit(_ combo: KeyCombo?, for action: LumenAction) {
        guard let combo else {
            keyBindings.clear(action)
            rejection = nil
            return
        }

        if let reason = keyBindings.set(combo, for: action) {
            rejection = "「\(action.title)」：\(reason.message)"
            NSSound.beep()
        } else {
            rejection = nil
        }
    }

    private var customizedCount: Int {
        LumenAction.allCases.filter { keyBindings.isCustomized($0) || keyBindings.isCleared($0) }.count
    }
}

// MARK: - 录制控件

/// 录制一个组合键。
///
/// 为什么是 `NSView` 而不是 SwiftUI 的 `onKeyPress`：
/// 1. `onKeyPress` 拿到的 `KeyEquivalent` 不带修饰键信息，⌥ 组合还会被系统折成重音字符，
///    录不出「⌥⌘→」这种绑定；
/// 2. 更要紧的是菜单系统会先于视图消费按键——用户在录制框里按 ⌘W，窗口会直接被关掉，
///    根本轮不到我们记录。所以这里装一个**本地事件监听**并在录制期间吃掉事件，
///    只有这样才能录到 ⌘W 这类本来被菜单占用的组合。
struct ShortcutRecorder: NSViewRepresentable {

    /// 当前生效的组合键。nil = 未绑定。
    let combo: KeyCombo?
    /// 录制结果。传 nil 表示「清空这一项」。
    let onChange: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.combo = combo
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.combo = combo
        nsView.onChange = onChange
    }

    @MainActor
    final class RecorderView: NSView {

        var combo: KeyCombo? {
            didSet { if !isRecording { needsDisplay = true } }
        }
        var onChange: ((KeyCombo?) -> Void)?

        private var isRecording = false {
            didSet { needsDisplay = true }
        }
        private var isHovering = false {
            didSet { needsDisplay = true }
        }

        private var keyMonitor: Any?
        private var clickMonitor: Any?

        // MARK: 绘制

        override var intrinsicContentSize: NSSize { NSSize(width: 138, height: 24) }

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

            if isRecording {
                NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                path.fill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5
            } else {
                NSColor.controlBackgroundColor.setFill()
                path.fill()
                (isHovering ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.separatorColor).setStroke()
                path.lineWidth = 1
            }
            path.stroke()

            let text: String
            let color: NSColor
            if isRecording {
                text = "按下组合键…"
                color = .controlAccentColor
            } else if let combo {
                text = combo.display
                color = .labelColor
            } else {
                text = "未绑定"
                color = .tertiaryLabelColor
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: color
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            )
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }

        // MARK: 交互

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true }
        override func mouseExited(with event: NSEvent) { isHovering = false }

        override func mouseDown(with event: NSEvent) {
            isRecording ? stopRecording() : startRecording()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            // 视图被摘掉（切页签、关窗口）时务必撤掉监听，
            // 否则全局按键会一直被一个已经不存在的录制器吃掉。
            if newWindow == nil { stopRecording() }
        }

        private func startRecording() {
            guard !isRecording else { return }
            isRecording = true
            window?.makeFirstResponder(self)

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, self.isRecording else { return event }
                self.handle(event)
                // 吃掉事件，菜单与系统快捷键都别想抢
                return nil
            }

            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self, self.isRecording else { return event }
                // 点到录制框外面 = 放弃录制。事件本身放行，用户点哪儿就是哪儿。
                if let window = self.window, window === event.window {
                    let local = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(local) { return event }
                }
                self.stopRecording()
                return event
            }
        }

        private func stopRecording() {
            isRecording = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            keyMonitor = nil
            clickMonitor = nil
        }

        private func handle(_ event: NSEvent) {
            // Esc 取消
            if event.keyCode == 53 {
                stopRecording()
                return
            }
            // Delete / Forward Delete 清空绑定
            if event.keyCode == 51 || event.keyCode == 117 {
                stopRecording()
                onChange?(nil)
                return
            }

            guard let name = Self.keyName(for: event) else { return }   // 只按了修饰键，继续等

            var modifiers: Set<KeyModifier> = []
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift)   { modifiers.insert(.shift) }
            if flags.contains(.option)  { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }

            let recorded = KeyCombo(key: name, modifiers: modifiers)
            stopRecording()
            guard recorded.isUsable else {
                NSSound.beep()   // 没带修饰键：拒绝，但让用户听得到
                return
            }
            onChange?(recorded)
        }

        /// 事件 → 键名。返回 nil 表示「这只是修饰键，还不能算一个组合」。
        private static func keyName(for event: NSEvent) -> String? {
            switch event.keyCode {
            case 123: return KeyCombo.SpecialKey.leftArrow
            case 124: return KeyCombo.SpecialKey.rightArrow
            case 125: return KeyCombo.SpecialKey.downArrow
            case 126: return KeyCombo.SpecialKey.upArrow
            case 53:  return KeyCombo.SpecialKey.escape
            case 48:  return KeyCombo.SpecialKey.tab
            case 49:  return KeyCombo.SpecialKey.space
            case 36, 76:  return KeyCombo.SpecialKey.return
            case 51, 117: return KeyCombo.SpecialKey.delete
            case 116: return KeyCombo.SpecialKey.pageUp
            case 121: return KeyCombo.SpecialKey.pageDown
            case 115: return KeyCombo.SpecialKey.home
            case 119: return KeyCombo.SpecialKey.end
            default: break
            }

            // 纯修饰键按下时 characters 为空串，此时返回 nil 让录制继续等下一个键
            guard let characters = event.charactersIgnoringModifiers?.lowercased(),
                  !characters.isEmpty else { return nil }
            // 过滤控制字符（含 ⌫ 产生的 \u{7F}）
            guard let scalar = characters.unicodeScalars.first,
                  scalar.value >= 32, scalar.value != 127 else { return nil }

            return String(characters.prefix(1))
        }
    }
}

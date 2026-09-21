import SwiftUI
import AppKit
import LumenKit

// MARK: - 组合键 → SwiftUI

extension KeyCombo {

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift)   { result.insert(.shift) }
        if modifiers.contains(.option)  { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case KeyCombo.SpecialKey.leftArrow:  return .leftArrow
        case KeyCombo.SpecialKey.rightArrow: return .rightArrow
        case KeyCombo.SpecialKey.upArrow:    return .upArrow
        case KeyCombo.SpecialKey.downArrow:  return .downArrow
        case KeyCombo.SpecialKey.escape:     return .escape
        case KeyCombo.SpecialKey.tab:        return .tab
        case KeyCombo.SpecialKey.space:      return .space
        case KeyCombo.SpecialKey.return:     return .return
        case KeyCombo.SpecialKey.delete:     return .delete
        default:
            // 只认单字符键。PageUp / Home 这些 `KeyEquivalent` 没有对应值，
            // 与其悄悄退化成「回车」引发意外，不如判为不支持。
            guard key.count == 1, let character = key.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    /// 转成 SwiftUI 快捷键。返回 nil 表示这一项没有（或无法表达）快捷键，
    /// 调用方应当去掉 `.keyboardShortcut` 修饰符而不是塞一个错的进去。
    var keyboardShortcut: KeyboardShortcut? {
        guard isUsable, let keyEquivalent else { return nil }
        return KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }
}

// MARK: - 动作的执行与可用性

// 动作的「能不能用」与「怎么执行」都要碰 `AppState` 和 `DS.Motion`，
// 这两者在 Swift 6 严格并发下都是 `@MainActor`，所以整个扩展必须待在主线程上。
@MainActor
extension LumenAction {

    /// 当前状态下这个动作能不能用。
    ///
    /// 菜单项与命令面板共用这一个判断，避免出现「菜单里是灰的、命令面板里点了没反应」
    /// 这种自相矛盾的状态。
    func isEnabled(in state: AppState) -> Bool {
        let hasDocument = state.document != nil

        switch self {
        case .openDocument, .commandPalette:
            return true
        case .openMostRecent:
            // 明确保持可用：没有最近记录时给一句提示，比一个点不动又不说原因的菜单项好。
            return true
        case .closeDocument, .copyFile, .nextUnit, .previousUnit, .goToPage:
            return hasDocument
        // 字号两个动作只对 EPUB 生效（PDF 走另一条渲染链，本轮不动）。
        // 曾经过度放宽成「只要有文档就可用」，导致 PDF 下快捷键被吞却什么也不发生，
        // 看起来像「假可用」。现在拆出来按格式判断，禁用时由 `disabledHint` 给解释。
        case .fontIncrease, .fontDecrease:
            return state.document?.kind == .epub
        case .copyFullText:
            return hasDocument && state.bridge.extractFullText != nil
        case .toggleSidebar, .toggleAIPanel, .toggleImmersive, .showOutline,
             .showSmartOutline, .showSearch, .showAnnotations:
            return hasDocument
        case .showThumbnails:
            return state.document?.kind == .pdf
        case .exportSummary:
            return !state.chat.lastSubstantialAnswer.isEmpty
        case .exportTranscript:
            return !state.chat.bubbles.isEmpty
        }
    }

    func run(_ state: AppState) {
        switch self {
        case .openDocument:   state.showOpenPanel()
        case .openMostRecent: state.openMostRecent()
        case .closeDocument:  state.closeDocument()
        case .copyFullText:   state.copyFullText()
        case .copyFile:       state.copyDocumentFileToPasteboard()

        case .toggleSidebar:
            state.toggleSidebar()
        case .toggleAIPanel:
            state.toggleAIPanel()
        case .toggleImmersive:
            // 面板可见性与全屏都由 setImmersive 内部统一处理，这里不重复包动画：
            // 它自己带了 withAnimation，外面再来一层会让两块面板的时序和外框对不齐。
            state.setImmersive(!state.isImmersive)
        case .commandPalette:
            withAnimation(DS.Motion.palette) { state.isCommandPaletteVisible.toggle() }

        case .nextUnit:     state.bridge.goToNextUnit?()
        case .previousUnit: state.bridge.goToPreviousUnit?()
        case .goToPage:
            withAnimation(DS.Motion.palette) { state.isPageJumpVisible.toggle() }

        case .showOutline:    state.revealSidebar(tab: .outline)
        case .showSmartOutline: state.revealSidebar(tab: .smartOutline)
        case .showSearch:     state.revealSidebar(tab: .search)
        case .showAnnotations: state.revealSidebar(tab: .annotations)
        case .showThumbnails: state.revealSidebar(tab: .thumbnails)

        case .fontIncrease:
            // 只有快捷键路径（这里）会在撞边界时弹提示；滑块路径不弹，避免拖动噪声。
            if case .atLimit(_, isMin: false) = state.stepFontScale(by: 0.1) {
                state.showToast("字号已到最大")
            }
        case .fontDecrease:
            if case .atLimit(_, isMin: true) = state.stepFontScale(by: -0.1) {
                state.showToast("字号已到最小")
            }

        case .exportSummary: state.exportSummaryToFile()
        case .exportTranscript: state.exportTranscriptToFile()
        }
    }
}

// MARK: - 动作需要的 AppState 能力

extension AppState {

    /// 打开最近读过的那一本。欢迎页的「继续阅读」和菜单里的是同一件事。
    func openMostRecent() {
        guard let latest = recent.entries.first(where: { $0.fileExists }) else {
            showToast("还没有最近打开的文档", isError: true)
            return
        }
        reopen(latest)
    }

    /// 切到某条侧栏页签；侧栏收着就先展开。
    ///
    /// 展开走 `setSidebarVisible(true)`（内部会通知阅读视图进入「面板正在调整」状态，
    /// 钉住 autoScales 以免大文件屏闪）；页签切换本身仍用 quick 动效。
    func revealSidebar(tab: SidebarTab) {
        setSidebarVisible(true)
        withAnimation(DS.Motion.quick) { bridge.sidebarTab = tab }
    }

    // 反馈的硬边界：提示只能挂在这一条「快捷键路径」上。
    // 绝对不要写进 `SettingsStore` 的 `fontScale` setter —— 否则用户拖滑块拖到边界会
    // 持续弹提示，那是噪声。滑块（AppearanceMenuButton / SettingsRootView）直接写
    // `settingsStore.reader.fontScale`，不经过本方法，因此不弹。
    @discardableResult
    func stepFontScale(by delta: Double) -> FontScaleStep {
        let step = FontScale.next(current: settingsStore.reader.fontScale, delta: delta)
        switch step {
        case .applied(let s):
            settingsStore.reader.fontScale = s
        case .atLimit(let s, _):
            // 撞边界也把值吸附写回：顺手把 `0.6000000000000001` 这类浮点脏值清成干净边界。
            settingsStore.reader.fontScale = s
        }
        return step
    }

    /// 导出最近一条实质回答。菜单、命令面板、AI 面板的 ⋯ 都走这一条。
    func exportSummaryToFile() {
        let summary = chat.lastSubstantialAnswer
        guard !summary.isEmpty else {
            showToast("还没有可导出的 AI 摘要", isError: true)
            return
        }
        ExportService.exportSummary(
            documentTitle: currentDocumentTitle,
            metadata: documentMetadata,
            summary: summary,
            transcript: chat.bubbles
        )
    }

    func exportTranscriptToFile() {
        guard !chat.bubbles.isEmpty else {
            showToast("当前文档还没有对话记录", isError: true)
            return
        }
        ExportService.exportTranscript(
            documentTitle: currentDocumentTitle,
            metadata: documentMetadata,
            transcript: chat.bubbles
        )
    }
}

// MARK: - 禁用原因

extension LumenAction {
    /// 这个动作在当前状态下为什么不可用。返回 `nil` 表示「没有额外要解释的，或者可用」。
    ///
    /// 只读 API：只有主动声明了原因的动作，在「快捷键被吞」时才会由 `GlobalShortcutRouter`
    /// 弹提示；其余禁用项维持原样，不引入噪声。所以这是「按需解释」而不是「谁禁用都喊」。
    ///
    /// 例如字号动作只对 EPUB 生效，在 PDF 下它会被 `isEnabled` 判成禁用——此时返回
    /// 范围说明，让用户知道「不是坏了，是 PDF 用文档自带字号」。
    var disabledHint: String? {
        switch self {
        case .fontIncrease, .fontDecrease:
            return ReaderSettings.fontScaleScopeNote
        default:
            return nil
        }
    }
}

import Foundation

// MARK: - 修饰键

public enum KeyModifier: String, Codable, CaseIterable, Sendable, Identifiable {
    case control
    case option
    case shift
    case command

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option:  return "⌥"
        case .shift:   return "⇧"
        case .command: return "⌘"
        }
    }

    public var displayName: String {
        switch self {
        case .control: return "Control"
        case .option:  return "Option"
        case .shift:   return "Shift"
        case .command: return "Command"
        }
    }

    /// 固定的展示顺序（与系统习惯一致：⌃⌥⇧⌘）。
    /// 用 `Set` 存修饰键，没有这个序号的话 `⌘⌥S` 有时会显示成 `⌥⌘S`。
    public var sortIndex: Int {
        switch self {
        case .control: return 0
        case .option:  return 1
        case .shift:   return 2
        case .command: return 3
        }
    }
}

// MARK: - 一个组合键

/// 一个组合键。
///
/// `key` 存字符串而不是 `Character` + 一堆特例字段：绝大多数键就是一个字符，
/// 方向键这类用固定名字（`leftArrow`）表示。存成字符串让 JSON 直观可读，
/// 用户手改 keybindings.json 时不必猜编码。
public struct KeyCombo: Codable, Sendable, Equatable, Hashable {

    public var key: String
    public var modifiers: Set<KeyModifier>

    public init(key: String, modifiers: Set<KeyModifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    // MARK: 特殊键名

    public enum SpecialKey {
        public static let leftArrow = "leftArrow"
        public static let rightArrow = "rightArrow"
        public static let upArrow = "upArrow"
        public static let downArrow = "downArrow"
        public static let escape = "escape"
        public static let tab = "tab"
        public static let space = "space"
        public static let `return` = "return"
        public static let delete = "delete"
        public static let pageUp = "pageUp"
        public static let pageDown = "pageDown"
        public static let home = "home"
        public static let end = "end"

        public static let all: [String] = [
            leftArrow, rightArrow, upArrow, downArrow,
            escape, tab, space, `return`, delete, pageUp, pageDown, home, end
        ]
    }

    // MARK: 校验

    /// 能不能用。
    ///
    /// 要求至少一个修饰键：把 ⌘K 这类全局动作绑到裸字母上，等于在任何输入框里
    /// 抢走那个字符，是不能接受的默认行为。
    public var isUsable: Bool { !key.isEmpty && !modifiers.isEmpty }

    /// 全角 → 半角 的**显式映射表**。
    ///
    /// 为什么必须显式：录制器拿到的是 `event.charactersIgnoringModifiers`，也就是
    /// **输入法产出的字符**而不是物理键。中文输入法下按 `]` 会得到全角 `】`（U+3011），
    /// 直接存进 keybindings.json 后**物理上按不出来**，绑定必然失效——
    /// 用户报的「AI 面板快捷键不生效」根因就是它（他的文件里躺着 `⌥】`）。
    ///
    /// 覆盖两类：FF01–FF5E 那一段可以用码位平移（`char − 0xFEE0`）批量处理，
    /// 但 CJK 符号区这些标点的码位不连续、平移不过来，只能一条条写死。
    public static let fullWidthMap: [Character: Character] = [
        "【": "[", "】": "]", "〔": "[", "〕": "]",
        "（": "(", "）": ")",
        "，": ",", "、": ",", "。": ".", "．": ".",
        "；": ";", "：": ":",
        "？": "?", "！": "!",
        "“": "\"", "”": "\"", "‘": "'", "’": "'",
        "～": "~", "﹣": "-",
    ]

    /// 把一个「录制到的字符」归一化成可键入的物理键名。
    ///
    /// 规则：显式表 → FF01–FF5E 码位平移 → 只接受 ASCII 可见字符（0x21…0x7E）→
    /// 字母统一折成小写（与 `defaultCombo` 的写法一致：⇧S 记作 `s` + shift）。
    ///
    /// - Parameter raw: 录制器拿到的原始字符串（可能含全角字符 / 大写字母 / emoji）。
    /// - Returns: 可键入的键名；无法归一化成可键入字符时返回 `nil`（调用方应拒绝写入）。
    public static func normalizedKey(_ raw: String) -> String? {
        // 特殊键名（方向键、Esc…）本身就是我们的内部表示，原样接受。
        if SpecialKey.all.contains(raw) { return raw }

        guard raw.count == 1, let character = raw.first else { return nil }

        let mapped: Character
        if let hit = fullWidthMap[character] {
            mapped = hit
        } else if character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first,
                  (0xFF01...0xFF5E).contains(scalar.value),
                  let half = UnicodeScalar(scalar.value - 0xFEE0) {
            // 全角 ASCII 区：码位整体平移 0xFEE0 即得半角。
            mapped = Character(half)
        } else {
            mapped = character
        }

        // 只接受 ASCII 可见字符：控制字符、空格、非 ASCII（é、emoji、汉字）一律拒。
        guard let ascii = mapped.asciiValue, (0x21...0x7E).contains(ascii) else { return nil }
        if mapped.isLetter { return String(mapped).lowercased() }
        return String(mapped)
    }

    /// `key` 是否落在「物理上按得出来」的集合内。
    ///
    /// 空串（显式清空）算合法；特殊键名算可键入；其余必须能被 `normalizedKey`
    /// 原样接受（`normalizedKey(key) == key` 排除了「大写字母」「全角字符」这类
    /// 需要归一化才能用的值）。
    public var isTypeableKey: Bool {
        if key.isEmpty { return true }
        if SpecialKey.all.contains(key) { return true }
        return Self.normalizedKey(key) == key
    }

    /// 把一条可能含「不可键入 key」的绑定迁移成合法形式。
    ///
    /// - Returns: 迁移后的组合（含全角→半角、大写→小写的归一化）；
    ///   `nil` 表示这条绑定**无法合法化**，应当丢弃并回落默认值。
    /// - Note: 「显式清空」（空 key + 空修饰键）原样保留——它是一个有意的用户状态，
    ///   不是坏数据。
    public var migrated: KeyCombo? {
        if key.isEmpty && modifiers.isEmpty { return self }
        guard let normalized = Self.normalizedKey(key) else { return nil }
        return KeyCombo(key: normalized, modifiers: modifiers)
    }

    /// 系统保留的组合，不允许用户占用。
    ///
    /// 这些键一旦被应用吃掉，用户就找不回退出、隐藏、切窗口这些基本操作，
    /// 而且不会意识到是自己改坏的。宁可拒绝，也不给一个能把自己锁死的开关。
    public var isReservedBySystem: Bool {
        let onlyCommand = modifiers == [.command]
        guard onlyCommand || modifiers == [.command, .option] else { return false }

        let reservedWithCommand: Set<String> = ["q", "h", "m", ",", "`", "space", "tab"]
        if onlyCommand && reservedWithCommand.contains(key.lowercased()) { return true }

        // ⌘⌥Esc 是系统的「强制退出」，⌘⌥⎋ 也一并保护
        if modifiers == [.command, .option] && key == SpecialKey.escape { return true }

        return false
    }

    // MARK: 展示

    public var display: String {
        let ordered = modifiers.sorted { $0.sortIndex < $1.sortIndex }
        return ordered.map(\.symbol).joined() + Self.label(for: key)
    }

    /// 给菜单用：空表示「未绑定」。
    public var displayOrDash: String { display.isEmpty ? "—" : display }

    private static func label(for key: String) -> String {
        switch key {
        case SpecialKey.leftArrow:  return "←"
        case SpecialKey.rightArrow: return "→"
        case SpecialKey.upArrow:    return "↑"
        case SpecialKey.downArrow:  return "↓"
        case SpecialKey.escape:     return "⎋"
        case SpecialKey.tab:        return "⇥"
        case SpecialKey.space:      return "空格"
        case SpecialKey.return:     return "↩"
        case SpecialKey.delete:     return "⌫"
        case SpecialKey.pageUp:     return "⇞"
        case SpecialKey.pageDown:   return "⇟"
        case SpecialKey.home:       return "↖"
        case SpecialKey.end:        return "↘"
        default:                    return key.uppercased()
        }
    }
}

// MARK: - 可改绑的动作

public enum LumenActionGroup: String, CaseIterable, Sendable, Identifiable {
    case document
    case panel
    case reading
    case typography
    case ai

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .document:   return "文档"
        case .panel:      return "面板与导航"
        case .reading:    return "翻页与侧栏"
        case .typography: return "排版"
        case .ai:         return "AI"
        }
    }

    public var actions: [LumenAction] {
        LumenAction.allCases.filter { $0.group == self }
    }
}

/// 可以被用户改绑的动作。
///
/// 刻意收得很短。「快捷键数量不宜过多」不只是审美问题：一个装满快捷键的应用
/// 会让用户不敢按任何组合键，真正常用的那几个反而记不住。这里只放
/// 「做一次就知道以后会一直用」的动作。
public enum LumenAction: String, CaseIterable, Codable, Sendable, Identifiable {

    // 文档
    case openDocument
    case openMostRecent
    case closeDocument
    case copyFullText
    case copyFile

    // 面板与导航
    case toggleSidebar
    case toggleAIPanel
    case toggleImmersive
    case commandPalette

    // 翻页与侧栏
    case nextUnit
    case previousUnit
    case goToPage
    case showOutline
    case showSmartOutline
    case showSearch
    case showAnnotations
    case showThumbnails

    // 排版
    case fontIncrease
    case fontDecrease

    // AI
    case exportSummary
    case exportTranscript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openDocument:   return "打开文档…"
        case .openMostRecent: return "打开最近阅读"
        case .closeDocument:  return "关闭标签页"
        case .copyFullText:   return "复制全文为纯文本"
        case .copyFile:       return "复制文件"
        case .toggleSidebar:  return "显示 / 隐藏侧栏"
        case .toggleAIPanel:  return "显示 / 隐藏 AI 面板"
        case .toggleImmersive: return "沉浸阅读模式"
        case .commandPalette: return "命令面板"
        case .nextUnit:       return "下一页 / 下一章"
        case .previousUnit:   return "上一页 / 上一章"
        case .goToPage:       return "跳转到页码…"
        case .showOutline:    return "侧栏：目录"
        case .showSmartOutline: return "侧栏：AI 智能目录"
        case .showSearch:     return "侧栏：搜索"
        case .showAnnotations: return "侧栏：批注"
        case .showThumbnails: return "侧栏：页面缩略图"
        case .fontIncrease:   return "放大字号"
        case .fontDecrease:   return "缩小字号"
        case .exportSummary:  return "导出 AI 摘要为 Markdown…"
        case .exportTranscript: return "导出对话记录为 Markdown…"
        }
    }

    public var group: LumenActionGroup {
        switch self {
        case .openDocument, .openMostRecent, .closeDocument, .copyFullText, .copyFile:
            return .document
        case .toggleSidebar, .toggleAIPanel, .toggleImmersive, .commandPalette:
            return .panel
        case .nextUnit, .previousUnit, .goToPage, .showOutline, .showSmartOutline, .showSearch,
             .showAnnotations, .showThumbnails:
            return .reading
        case .fontIncrease, .fontDecrease:
            return .typography
        case .exportSummary, .exportTranscript:
            return .ai
        }
    }

    public var defaultCombo: KeyCombo {
        switch self {
        case .openDocument:   return KeyCombo(key: "o", modifiers: [.command])
        case .openMostRecent: return KeyCombo(key: "r", modifiers: [.command, .shift])
        case .closeDocument:  return KeyCombo(key: "w", modifiers: [.command])
        case .copyFullText:   return KeyCombo(key: "c", modifiers: [.command, .shift])
        case .copyFile:       return KeyCombo(key: "c", modifiers: [.command, .option])

        case .toggleSidebar:  return KeyCombo(key: "s", modifiers: [.command, .option])
        case .toggleAIPanel:  return KeyCombo(key: "a", modifiers: [.command, .shift])
        // **刻意避开 ⌃⌘F**。那是 macOS 系统的「进入 / 退出全屏」标准组合，也是
        // SwiftUI `WindowGroup` 自动生成的「进入全屏」菜单项所用的组合。绑成同一个键，
        // 按一次会让「系统全屏」与「应用沉浸」两个 toggle 同时触发，两套状态机各自翻转，
        // 外观上正是「全屏后显示与动作效果异常」；而且系统那条路径退出全屏后
        // 不会回写沉浸状态，于是又变成「退不回来」。
        // 用 ⌥⌘F：F 的语义（Fullscreen / Focus）保留，且不与系统抢。
        case .toggleImmersive: return KeyCombo(key: "f", modifiers: [.option, .command])
        case .commandPalette: return KeyCombo(key: "k", modifiers: [.command])

        case .nextUnit:       return KeyCombo(key: KeyCombo.SpecialKey.rightArrow, modifiers: [.command, .option])
        case .previousUnit:   return KeyCombo(key: KeyCombo.SpecialKey.leftArrow, modifiers: [.command, .option])
        case .goToPage:       return KeyCombo(key: "g", modifiers: [.command])
        // 四个侧栏页签按**界面里的排列顺序**编号。之前是 目录⌘1 / 搜索⌘2 / 页面⌘3，
        // 插入智能目录后若沿用旧号，⌘2 指的会是排在第三位的搜索——顺序对不上，
        // 用户按错了只会觉得快捷键是坏的。这里跟着排列改成 1/2/3/4。
        case .showOutline:    return KeyCombo(key: "1", modifiers: [.command])
        case .showSmartOutline: return KeyCombo(key: "2", modifiers: [.command])
        case .showSearch:     return KeyCombo(key: "3", modifiers: [.command])
        // 侧栏页签按**界面里的排列顺序**编号，插入「批注」后页面顺延到 ⌘5。
        // 编号跟着顺序走而不是给新页签找个空位：⌘4 落在第 4 个页签上，
        // 用户按一次就能建立映射；乱序编号要求他先记住哪一号对应哪一个。
        case .showAnnotations: return KeyCombo(key: "4", modifiers: [.command])
        case .showThumbnails: return KeyCombo(key: "5", modifiers: [.command])

        case .fontIncrease:   return KeyCombo(key: "+", modifiers: [.command])
        case .fontDecrease:   return KeyCombo(key: "-", modifiers: [.command])

        case .exportSummary:  return KeyCombo(key: "e", modifiers: [.command, .shift])
        // 「导出对话记录」的默认组合。取 ⇧⌘T（T = Transcript / 对话记录）：
        // 与既有全部默认均不冲突（⇧⌘E 摘要、⇧⌘C 复制全文、⇧⌘A AI 面板、⇧⌘R 最近打开、
        // ⌥⌘C 复制文件、⌥⌘S 侧栏、⌥⌘F 沉浸、⌥⌘←/→、⌘1–5、⌘K/G/O/W、⌘±），
        // 也不是系统保留键。
        // **不用候选的 ⇧⌘J**：它与 `KeyBindingsAudit.verifyRules` 里当作「一个空闲组合」的
        // 夹具 ⇧⌘J 撞车，会让「合法改绑被接受」等 5 条规则断言变红——夹具假定它是空的。
        case .exportTranscript: return KeyCombo(key: "t", modifiers: [.command, .shift])
        }
    }

    /// 命令面板检索用的同义词。
    public var keywords: String {
        switch self {
        case .openDocument:   return "open file 打开 文档"
        case .openMostRecent: return "recent last 最近 继续阅读"
        case .closeDocument:  return "close tab 关闭 标签 标签页"
        case .copyFullText:   return "copy text all 复制 全文 纯文本"
        case .copyFile:       return "copy file 文件 复制"
        case .toggleSidebar:  return "sidebar 侧栏 边栏"
        case .toggleAIPanel:  return "ai panel 面板"
        case .toggleImmersive: return "immersive focus fullscreen zen 沉浸 专注 全屏 无干扰"
        case .commandPalette: return "palette 命令 面板"
        case .nextUnit:       return "next page chapter 下一页 下一章"
        case .previousUnit:   return "previous page chapter 上一页 上一章"
        case .goToPage:       return "goto go to page jump 跳转 页码 定位"
        case .showOutline:    return "outline toc 目录"
        case .showSmartOutline: return "smart outline ai 智能目录 结构 章节"
        case .showSearch:     return "search find 搜索 查找"
        case .showAnnotations: return "annotation highlight note 批注 高亮 笔记"
        case .showThumbnails: return "thumbnail page grid 缩略图 页面"
        case .fontIncrease:   return "font bigger 字号 放大"
        case .fontDecrease:   return "font smaller 字号 缩小"
        case .exportSummary:  return "export markdown 导出 摘要"
        case .exportTranscript: return "export transcript 导出 对话 记录"
        }
    }
}

// MARK: - 存储

/// 快捷键绑定。
///
/// 存「动作 → 组合键」的**差量**，没有记录的动作用 `defaultCombo`。
/// 这样以后新增动作时，老用户的 keybindings.json 不需要迁移就能拿到新动作的默认值。
@MainActor
public final class KeyBindingStore: ObservableObject {

    @Published public private(set) var overrides: [String: KeyCombo]

    private let fileURL: URL

    public init(fileURL: URL = AppPaths.keyBindingsFile) {
        self.fileURL = fileURL
        let (loaded, didChange) = Self.load(from: fileURL)
        self.overrides = loaded
        // 载入时发生了迁移 / 丢弃就写回一次，让迁移成为**一次性**的：
        // 否则每次启动都会重打一遍日志，用户也无从在文件里看出已被修正过。
        // 只在确实改动过时写，正常启动（文件已合法）不会碰用户文件。
        if didChange { save() }
    }

    // MARK: 查询

    /// 某个动作当前生效的组合键。返回 nil 表示用户把它清空了。
    public func combo(for action: LumenAction) -> KeyCombo? {
        if let override = overrides[action.rawValue] {
            return override.isUsable ? override : nil
        }
        return action.defaultCombo
    }

    public func isCustomized(_ action: LumenAction) -> Bool {
        guard let override = overrides[action.rawValue] else { return false }
        return override != action.defaultCombo
    }

    /// 面板里「这一项有没有被清空」——清空是显式的状态，与「没改过」不同。
    public func isCleared(_ action: LumenAction) -> Bool {
        guard let override = overrides[action.rawValue] else { return false }
        return !override.isUsable
    }

    /// 与别的动作撞车时返回那个动作，没撞返回 nil。
    public func conflictingAction(for combo: KeyCombo, excluding action: LumenAction) -> LumenAction? {
        LumenAction.allCases.first { other in
            other != action && self.combo(for: other) == combo
        }
    }

    // MARK: 修改

    public enum Rejection: Equatable {
        case needsModifier
        case keyNotTypeable(combo: KeyCombo)
        case reservedBySystem(combo: KeyCombo)
        case conflict(with: LumenAction, combo: KeyCombo)

        public var message: String {
            switch self {
            case .needsModifier:
                return "至少要带一个修饰键。裸字母会抢走输入框里的正常打字。"
            case .keyNotTypeable(let combo):
                return "「\(combo.key)」这个键不可键入（多半是输入法产出的全角字符或非 ASCII 字符），换了也不会生效。请重新录制。"
            case .reservedBySystem(let combo):
                return "\(combo.display) 是系统保留的组合（退出 / 隐藏 / 切换窗口一类），不能占用。"
            case .conflict(let action, let combo):
                return "\(combo.display) 已经给了「\(action.title)」。先把那一项改掉，或直接换一个组合。"
            }
        }
    }

    /// 改绑。被拒绝时返回原因，调用方负责提示。
    @discardableResult
    public func set(_ combo: KeyCombo, for action: LumenAction) -> Rejection? {
        guard combo.isUsable else { return .needsModifier }
        // 拒绝「物理上按不出来」的 key。录制器会先做一遍归一化（全角→半角），
        // 这里再兜一道：任何入口（含将来的脚本 / 手改 JSON）塞进不可键入的键，都拦得住。
        guard combo.isTypeableKey else { return .keyNotTypeable(combo: combo) }
        guard !combo.isReservedBySystem else { return .reservedBySystem(combo: combo) }
        if let other = conflictingAction(for: combo, excluding: action) {
            return .conflict(with: other, combo: combo)
        }

        overrides[action.rawValue] = combo
        save()
        return nil
    }

    /// 清空绑定（这个动作将没有快捷键）。菜单项仍然在。
    public func clear(_ action: LumenAction) {
        // 用一个"不可用"的组合表示清空：比从字典里删掉更好，
        // 删掉会被理解成"恢复默认"，而用户想要的是"不要快捷键"。
        overrides[action.rawValue] = KeyCombo(key: "", modifiers: [])
        save()
    }

    /// 单项恢复默认。
    public func reset(_ action: LumenAction) {
        overrides.removeValue(forKey: action.rawValue)
        save()
    }

    /// 全部恢复默认。
    public func resetAll() {
        overrides.removeAll()
        save()
    }

    public var hasAnyCustomization: Bool { !overrides.isEmpty }

    // MARK: 持久化

    /// 从磁盘载入绑定表。
    ///
    /// 逐条**迁移 + 校验**，而不是整份信任：
    /// - 全角字符（`】`）折回半角（`]`）——这是用户的真实文件里躺着的坏绑定，
    ///   不迁移的话他的「显示 / 隐藏 AI 面板」永远按不出来；
    /// - 归一化后仍不可键入的绑定**丢弃并回落默认值**，同时 `NSLog` 说明是哪一个
    ///   （不要静默：用户会以为是自己改错了却找不到原因）。
    ///
    /// - Returns: (有效的绑定表, 是否发生过改动)。改动过就要写回，见 `init`。
    private static func load(from url: URL) -> ([String: KeyCombo], Bool) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([:], false) }
        guard let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else {
            // 解不出来就当没改过，不要把整个文件删掉——用户可能是手改坏了，
            // 保留原文件他才好对照着修。
            return ([:], false)
        }
        // 过滤掉已经不存在的动作名（改版删过动作时留下的残迹）
        let known = Set(LumenAction.allCases.map(\.rawValue))
        var result: [String: KeyCombo] = [:]
        var didChange = decoded.count != known.intersection(decoded.keys).count

        for (actionName, combo) in decoded where known.contains(actionName) {
            let label = LumenAction(rawValue: actionName)?.title ?? actionName
            guard let migrated = combo.migrated else {
                NSLog("[Lumen][keys] 丢弃不可键入的绑定「\(label)」：key=「\(combo.key)」"
                      + "（无法归一化为可键入字符），已回落默认 "
                      + "\(LumenAction(rawValue: actionName)?.defaultCombo.display ?? "—")")
                didChange = true
                continue
            }
            if migrated.key != combo.key {
                NSLog("[Lumen][keys] 迁移绑定「\(label)」：key「\(combo.key)」→「\(migrated.key)」"
                      + "（全角/大写归一化，modifiers 不变）")
                didChange = true
            }
            result[actionName] = migrated
        }
        return (result, didChange)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(overrides) else { return }
        PersistFile.write(data, to: fileURL, label: "keybindings.json")
    }
}

import AppKit
import CoreText
import LumenKit

/// 系统字体族目录：给设置页挑字体用。
///
/// 关键难点不是"取到字体列表"——`CTFontManagerCopyAvailableFontFamilyNames` 一行就有——
/// 而是**要把不能当正文字体用的挑出去**。系统字体目录里混着图标字体、符号字体、
/// 表情字体，用户一旦选中，正文会变成一屏方块，而且他大概率不知道是自己选错了字体。
///
/// 筛选与分组的实现要点（都是踩过才知道的）：
///
/// 1. **只用 CoreText，不用 `NSFontManager`。** `NSFontManager` 的 `localizedName(forFamily:)`
///    与 `NSFont.coveredCharacterSet` 会触发字体文件加载，逐族跑一遍要 1.5 秒；
///    而 `CTFontManagerCopyAvailableFontFamilyNames` + `CTFontGetGlyphsForCharacters`
///    是纯读操作，几十毫秒就能跑完 200 多个族。
/// 2. **分组靠 `CTFontGetSymbolicTraits` 的 class 位**，不靠名字猜。要注意很多字体
///    压根没有 class 位（`Apple Chancery` 就是），只能落到「其他」。
/// 3. **符号字体必须靠 class 位排除**：`Apple Symbols` 这类字体是**能**画出 'A' 的，
///    用"能不能渲染 ASCII"当门槛拦不住它们。
/// 4. **额外记录"是否覆盖中文"**。对中文读者来说这才是真正决定能不能用的指标——
///    一款漂亮的西文衬线体排中文会整段掉字。
public enum FontCatalog {

    /// 字体分组。
    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case sansSerif   // 无衬线
        case serif       // 衬线
        case monospaced  // 等宽
        case rounded     // 圆体
        case other       // 其他（装饰体、脚本体等）

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .sansSerif:  return "无衬线"
            case .serif:      return "衬线"
            case .monospaced: return "等宽"
            case .rounded:    return "圆体"
            case .other:      return "其他"
            }
        }
    }

    public struct Family: Identifiable, Hashable, Sendable {
        /// 真正写进设置的族名
        public let name: String
        public let group: Group
        /// 是否覆盖常用中文字形。设置页会给出标记，排序也优先
        public let supportsChinese: Bool
        public var id: String { name }
    }

    // MARK: - 缓存与装载

    private static let lock = NSLock()
    private static var cached: [Family]?
    private static var loadTask: Task<[Family], Never>?

    /// 已装载的目录。没装载完时返回空数组——调用方应当先 `await load()`。
    public static func all() -> [Family] {
        lock.withLock { cached ?? [] }
    }

    public static var isLoaded: Bool {
        lock.withLock { cached != nil }
    }

    /// 装载目录。重复调用不会重复枚举，也不会提前返回未完成的结果。
    ///
    /// 这里必须让**所有**并发调用者等同一个任务。曾经的写法是
    /// `guard !isLoading else { return }`，看着像"只跑一次"，实际是"第二个调用者拿到空气"：
    /// 预热任务刚把标志置上，自检就进来了，于是自检读到 0 个字体，而预热还在慢慢枚举。
    ///
    /// 放在后台跑是因为完整枚举要上百毫秒，放在设置页 `body` 里会卡住弹层动画。
    /// 装载只用 CoreText 的读接口，不碰 `NSFontManager.shared`，因此可以安全离开主线程。
    public static func load() async {
        let task: Task<[Family], Never> = lock.withLock {
            if let existing = loadTask { return existing }
            let created = Task.detached(priority: .utility) { build() }
            loadTask = created
            return created
        }

        let built = await task.value

        lock.withLock {
            if cached == nil { cached = built }
            loadTask = nil
        }
    }

    /// 预热。应用启动后调一次，用户点开字体选择器时就不必等。
    public static func prewarm() {
        Task.detached(priority: .background) {
            await load()
        }
    }

    // MARK: - 查询

    public static func families(in group: Group) -> [Family] {
        all().filter { $0.group == group }
    }

    /// 分组内的展示顺序：常见正文优先，其次支持中文的优先，最后按名字排。
    ///
    /// 排序必须**稳定**——否则每次打开设置页字体顺序都在跳，用户会以为列表在随机刷新。
    public static func orderedFamilies(in group: Group) -> [Family] {
        let preferred: [String]
        switch group {
        case .serif:
            preferred = ["Songti SC", "STSong", "Source Han Serif SC", "Noto Serif CJK SC",
                         "Georgia", "Times New Roman", "Palatino"]
        case .sansSerif:
            preferred = ["PingFang SC", "Helvetica Neue", "Helvetica", "Arial",
                         "Source Han Sans SC", "Noto Sans CJK SC"]
        case .monospaced:
            preferred = ["SF Mono", "SFMono-Regular", "Menlo", "Monaco",
                         "JetBrains Mono", "Fira Code", "Courier New"]
        case .rounded:
            preferred = ["SF Pro Rounded", "Arial Rounded MT Bold", "PingFang SC"]
        case .other:
            preferred = []
        }

        let rank = Dictionary(uniqueKeysWithValues: preferred.enumerated().map { ($1, $0) })
        return families(in: group).sorted { lhs, rhs in
            let l = rank[lhs.name] ?? Int.max
            let r = rank[rhs.name] ?? Int.max
            if l != r { return l < r }
            if lhs.supportsChinese != rhs.supportsChinese { return lhs.supportsChinese }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 设置页预览用的中英混排样例。选中西文混排是有意的：
    /// 只给中文样例会漏掉"这款字体没有西文数字"，只给英文会漏掉"没有中文字形"。
    public static let previewText = """
    乡村学校的文化再生产

    Bourdieu 指出，文化资本（cultural capital）的传递并不经过市场，
    而是在家庭日常中完成。1970 年的研究至今仍有解释力。
    """

    // MARK: - 枚举（后台线程）

    private static func build() -> [Family] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        var byCanonicalName: [String: Family] = [:]

        for rawName in names {
            // `.` 开头是系统私有族，不给看
            guard !rawName.hasPrefix(".") else { continue }

            let font = CTFontCreateWithName(rawName as CFString, 14, nil)
            let traits = CTFontGetSymbolicTraits(font).rawValue

            // 符号/图标字体：能画 'A'，但拿它排正文就是一堆图形符号
            if traits & Trait.classMask == Trait.symbolicClass { continue }
            // 彩色字形 = 表情字体
            if traits & Trait.colorGlyphs != 0 { continue }
            if Self.symbolFamilyDenylist.contains(rawName) { continue }
            // 正文可用性底线：得能画出 ASCII 字母
            guard canRender(font, "A") else { continue }

            let canonical = CTFontCopyFamilyName(font) as String? ?? rawName
            let candidate = Family(
                name: rawName,
                group: group(traits: traits, name: rawName),
                supportsChinese: canRender(font, "中")
            )

            // 同一款字体常以多个名字出现，只留名字更短的那个（通常是正主）
            if let existing = byCanonicalName[canonical] {
                if rawName.count < existing.name.count {
                    byCanonicalName[canonical] = candidate
                }
            } else {
                byCanonicalName[canonical] = candidate
            }
        }

        return byCanonicalName.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 该字体能否画出给定字符。
    private static func canRender(_ font: CTFont, _ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        return ok && glyphs.allSatisfy { $0 != 0 }
    }

    /// `CTFontSymbolicTraits` / `CTFontStylisticClass` 的原始位。
    ///
    /// 刻意写原始值而不是用 Swift 导入的成员名：这些常量的成员名在
    /// `traitXxx` / `classXxx` / `traitClassXxxMask` 之间变过好几轮，
    /// 写错一个字母就是编译错误，而位值是 CoreText 的 ABI，不会变。
    private enum Trait {
        static let monoSpace: UInt32 = 1 << 10
        static let colorGlyphs: UInt32 = 1 << 13
        static let classMask: UInt32 = 0xF000_0000
        static let symbolicClass: UInt32 = 12 << 28
        static let sansSerifClass: UInt32 = 8 << 28
        static let serifClasses: [UInt32] = [
            1 << 28,   // old style
            2 << 28,   // transitional
            3 << 28,   // modern
            4 << 28,   // clarendon
            5 << 28,   // slab
            7 << 28    // freeform
        ]
    }

    /// 显式排除的符号字体。
    ///
    /// 为什么必须有这份名单：`Apple Symbols`、`Apple Braille` 这类字体**带完整的拉丁字母**，
    /// 也没有声明符号 class 位——上面两条 trait 规则都拦不住它们。它们的用途是给系统做
    /// 字符兜底，不是排正文，所以只能按名字排除。
    /// 名单保持极短：只放"整个族的存在意义就是画符号"的，不放任何能排正文的字体。
    private static let symbolFamilyDenylist: Set<String> = [
        "Apple Symbols",
        "Apple Braille",
        "Apple Braille Outline 6 Dot",
        "Apple Braille Outline 8 Dot",
        "Apple Braille Pinpoint 6 Dot",
        "Apple Braille Pinpoint 8 Dot",
        "LastResort",
        "Webdings",
        "Wingdings",
        "Wingdings 2",
        "Wingdings 3",
        "Zapf Dingbats"
    ]

    /// 分组。
    ///
    /// 两条经验：圆体没有任何 trait 位可以识别（它是 SF 的设计变体），只能按名字认；
    /// 而很多字体压根不带 class 位（`Apple Chancery`、`Academy Engraved LET` 都是），
    /// 只会落到「其他」——这是可接受的，总比把它们勉强塞进衬线/无衬线误导用户强。
    private static func group(traits: UInt32, name: String) -> Group {
        if traits & Trait.monoSpace != 0 {
            return .monospaced
        }
        if name.localizedCaseInsensitiveContains("rounded") {
            return .rounded
        }
        let styleClass = traits & Trait.classMask
        if styleClass == Trait.sansSerifClass {
            return .sansSerif
        }
        if Trait.serifClasses.contains(styleClass) {
            return .serif
        }
        return .other
    }

    // MARK: - 自检

    /// 把目录统计打进日志，供 `--font-report 1` 自检使用。
    ///
    /// 为什么要在应用里做而不是写个独立脚本：独立脚本只能复制一份筛选逻辑去测，
    /// 测的是副本不是本体。这里跑的就是设置页真正用的那份目录。
    public static func logReport() async {
        let started = Date()
        await load()
        let list = all()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        let counts = Group.allCases.map { group in
            "\(group.displayName)=\(list.filter { $0.group == group }.count)"
        }.joined(separator: " ")

        let chineseFriendly = list.filter(\.supportsChinese).count
        NSLog("%@", "[Lumen] 字体目录：共 \(list.count) 族，支持中文 \(chineseFriendly) 族（装载耗时 \(elapsed)ms）\(counts)")

        // 这些断言失败就说明筛选规则错了，不是"这台机器的字体环境特殊"。
        let checks: [(String, Bool)] = [
            ("能取到 PingFang SC 且归入无衬线", list.contains { $0.name == "PingFang SC" && $0.group == .sansSerif }),
            ("能取到 Songti SC 且归入衬线", list.contains { $0.name == "Songti SC" && $0.group == .serif }),
            ("中文字体被标记为支持中文", list.contains { $0.name == "PingFang SC" && $0.supportsChinese }),
            ("符号字体已排除", !list.contains { $0.name == "Apple Symbols" }),
            ("表情字体已排除", !list.contains { $0.name == "Apple Color Emoji" }),
            ("无族名以点开头", !list.contains { $0.name.hasPrefix(".") }),
            ("无重复族名", Set(list.map(\.name)).count == list.count)
        ]
        for (label, passed) in checks {
            NSLog("%@", "[Lumen] 字体目录自检 \(passed ? "✅" : "❌") \(label)")
        }

        for group in Group.allCases {
            let sample = orderedFamilies(in: group).prefix(6).map(\.name).joined(separator: ", ")
            NSLog("%@", "[Lumen] 字体目录 \(group.displayName)：\(sample.isEmpty ? "（无）" : sample)")
        }
    }
}

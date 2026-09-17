import Foundation

// MARK: - 任务类型

public enum SummarizeScope: Sendable, Equatable {
    /// 当前章 / 当前页附近
    case currentUnit
    /// 整本书（走章节摘要树，见 buildDocumentSummaryMessages）
    case wholeDocument
}

public enum AITask: Sendable, Equatable {
    case explain
    case translate
    case ask(question: String)
    case summarize(scope: SummarizeScope)
    case custom(prompt: String)

    public var title: String {
        switch self {
        case .explain:            return "解释"
        case .translate:          return "翻译"
        case .ask:                return "提问"
        case .summarize(.currentUnit):     return "总结本节"
        case .summarize(.wholeDocument):   return "总结全书"
        case .custom:             return "自定义"
        }
    }
}

/// 提示词构造。
///
/// 设计取向：把「模型容易犯的错」写进系统提示，而不是寄希望于模型自觉。
/// 阅读场景里最要命的三个问题是——幻觉补全原文没有的内容、输出一堆客套话、
/// 用过度概括的词替换原意。系统提示逐条堵住。
public enum PromptLibrary {

    /// 单一系统提示，保证不同任务下模型的行为基线一致。
    ///
    /// `template` 提供 `systemPrompt` 时**整段替换**，而不是拼接：
    /// 模板的意义就是换一种读法（「批判性审读」的立场与「严谨学术解读」并不相同），
    /// 把两段立场不同的指令拼在一起，模型只会两头都不满足。
    /// 读者背景仍然保留——那是「关于谁在读」，与「怎么读」不冲突。
    public static func systemPrompt(readerPersona: String = "", template: PromptTemplate? = nil) -> String {
        if let custom = template?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            var lines = [custom]
            if !readerPersona.isEmpty {
                lines.append("")
                lines.append("关于这位读者的持久背景（来自其本人在设置中填写的内容，可直接使用，不必再问）：")
                lines.append(readerPersona)
            }
            return lines.joined(separator: "\n")
        }

        var lines = [
            "你是一位严谨的阅读助手，正在帮助用户理解他手上正在读的文档。",
            "",
            "工作原则：",
            "1. 只依据用户提供的原文与上下文回答。原文没有的信息，直接说「原文没有提到」，不要凭常识补全。",
            "2. 直接给结论，再给依据。不要写「这是一个很好的问题」这类开场白。",
            "3. 不要复述原文。用户已经读过那一段了，他要的是解释、关联或判断。",
            "4. 术语第一次出现时给一次简短说明，之后直接用术语。",
            "5. 如果原文表述本身模糊或可能有歧义，指出歧义在哪，而不是替他选一个解释。",
            "6. 用中文回答。代码、公式、专有名词保留原文形式。",
            "7. 不要输出 Markdown 标题层级（#），正文里需要分点时用「- 」。",
            "8. 篇幅与问题难度匹配：一句话能答完的不要写三段。"
        ]
        if !readerPersona.isEmpty {
            lines.append("")
            lines.append("关于这位读者的持久背景（来自其本人在设置中填写的内容，可直接使用，不必再问）：")
            lines.append(readerPersona)
        }
        return lines.joined(separator: "\n")
    }

    /// 文档抬头，让模型知道它在读什么。
    public static func documentBlock(metadata: DocumentMetadata, locatorLabel: String) -> String {
        var lines: [String] = ["【文档信息】"]
        if !metadata.title.isEmpty { lines.append("标题：\(metadata.title)") }
        if !metadata.author.isEmpty { lines.append("作者：\(metadata.author)") }
        if !locatorLabel.isEmpty { lines.append("用户当前位于：\(locatorLabel)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 上下文裁剪

    /// 按字符数裁剪上下文。
    ///
    /// 用字符数而不是 token 数：不引 tokenizer 就得估，而中文里 1 字符 ≈ 1–1.5 token、
    /// 英文 ≈ 0.25 token，估算误差比字符数本身还大。宁可保守一点多留余量。
    public static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit * 2 / 3)
        let tail = text.suffix(limit / 3)
        return head + "\n……（此处省略 \(text.count - limit) 字）……\n" + tail
    }

    // MARK: - 任务构造

    public static func messages(
        task: AITask,
        selection: ReaderSelection?,
        metadata: DocumentMetadata,
        locatorLabel: String,
        context: String,
        memory: String,
        history: [AIMessage] = [],
        translateTarget: String = "简体中文",
        template: PromptTemplate? = nil
    ) -> [AIMessage] {

        var messages: [AIMessage] = [.system(systemPrompt(readerPersona: memory, template: template))]

        // 带上最近几轮，让「追问」能接上前文
        messages.append(contentsOf: history.suffix(6))

        var user = documentBlock(metadata: metadata, locatorLabel: locatorLabel)
        user += "\n\n"

        switch task {
        case .explain:
            if let selection {
                user += selection.contextBlock()
                user += "\n\n请解释【选中内容】：它说的是什么，以及它在这段论述里起什么作用。"
            } else {
                user += "【当前阅读位置的内容】\n" + truncate(context, limit: 6000)
                user += "\n\n请解释这段内容的核心意思。"
            }

        case .translate:
            if let selection {
                user += "【待翻译内容】\n" + selection.text
                user += "\n\n请把【待翻译内容】译成\(translateTarget)。只输出译文，不要加解释、不要加原译文对照。保持原文的分段与语气。"
            } else {
                user += "【待翻译内容】\n" + truncate(context, limit: 6000)
                user += "\n\n请把【待翻译内容】译成\(translateTarget)。只输出译文，保持原文的分段。"
            }

        case .ask(let question):
            if let selection {
                user += selection.contextBlock()
                user += "\n\n读者的问题：\(question)"
            } else {
                user += "【当前阅读位置的内容】\n" + truncate(context, limit: 6000)
                user += "\n\n读者的问题：\(question)"
            }

        case .summarize(.currentUnit):
            user += "【待总结内容】\n" + truncate(context, limit: 7000)
            user += "\n\n请总结上述内容。要求：先一句话概括主旨，再用 3–5 条列出要点，最后指出作者在此处的立场或论证方式。"

        case .summarize(.wholeDocument):
            user += "【待总结内容】\n" + truncate(context, limit: 12000)
            user += "\n\n以上是一份文档各章的摘要。请基于它们写出整份文档的概览：先用两三句话讲清它整体在讨论什么，再列出主要论点，最后指出它可能的局限或未展开之处。"

        case .custom(let prompt):
            if let selection {
                user += selection.contextBlock()
                user += "\n\n"
            }
            user += prompt
        }

        // 模板的额外要求追加在最后。位置是刻意的：任务自带的要求先出现，
        // 模型看到的是「先理解这次要做什么，再满足这个模板额外要什么」；
        // 反过来插在前面，会被任务要求盖过去。
        if let extra = template?.instruction.trimmingCharacters(in: .whitespacesAndNewlines),
           !extra.isEmpty {
            user += "\n\n" + extra
        }

        messages.append(.user(user))
        return messages
    }

    /// 章节级摘要（map 阶段），供整本书总结做 reduce。
    public static func chapterSummaryMessages(
        text: String,
        chapterLabel: String,
        metadata: DocumentMetadata
    ) -> [AIMessage] {
        let prompt = """
        \(documentBlock(metadata: metadata, locatorLabel: chapterLabel))

        【\(chapterLabel) 正文】
        \(truncate(text, limit: 9000))

        请用 3–6 句话概括这一章：它讲了什么、得出什么结论、与前后文的关系是什么。
        只输出概括本身，不要任何前言。
        """
        return [.system(systemPrompt()), .user(prompt)]
    }

    // MARK: - 智能目录

    /// 智能目录的**第一步**：只生成目录骨架（标题 + 位置），不带摘要。
    ///
    /// 为什么拆两步：一本 300 页的书，若要求「目录 + 每节摘要」一次输出，
    /// 输出长度会直接顶到 max_tokens，而且中途任何一处失败都得整本重来——
    /// 白花的钱是实打实的。骨架只有几十行，生成快、失败代价小；
    /// 摘要等用户真的点开某一节时再单独算（见 `entrySummaryMessages`）。
    public static func smartOutlineMessages(
        metadata: DocumentMetadata,
        digest: String,
        unitName: String
    ) -> [AIMessage] {
        let prompt = """
        \(documentBlock(metadata: metadata, locatorLabel: ""))

        【文档各\(unitName)的开头摘录】
        \(digest)

        请根据上面的摘录，推断这份文档的目录结构，并**只输出 JSON**。

        格式要求：
        1. 输出一个 JSON 数组。不要输出任何解释文字，不要用 markdown 代码块包裹。
        2. 数组里每个元素形如：{"title": "章节标题", "unit": 12, "depth": 0}
           - title：章节标题，使用原文的语言，20 字以内
           - unit：该章节起始的\(unitName)序号，从 1 开始，必须落在上面出现过的范围内
           - depth：层级，顶层为 0，子节为 1，更深的为 2

        内容要求：
        3. 只列出摘录中**确实出现**的结构性分节；标题要从原文里认，不要自己起名。
        4. 实在看不出分节时，按内容主题归纳 5–12 个部分，标题如实描述该部分在讲什么。
        5. 判断不出来源的条目就跳过，宁缺毋滥。
        6. 条目总数不要超过 40。
        """
        return [.system(systemPrompt()), .user(prompt)]
    }

    /// 智能目录的**第二步**：为某一节生成摘要（用户点开时才调用）。
    public static func entrySummaryMessages(
        metadata: DocumentMetadata,
        entryTitle: String,
        locatorLabel: String,
        text: String
    ) -> [AIMessage] {
        let prompt = """
        \(documentBlock(metadata: metadata, locatorLabel: locatorLabel))

        【「\(entryTitle)」一节的正文】
        \(truncate(text, limit: 9000))

        请用 2–4 句话说明这一节讲了什么。要求：
        - 直接说内容，不要用「本节介绍了…」这类套话开头。
        - 抓住作者的核心主张或这一节要解决的问题。
        - 只输出这段话本身。
        """
        return [.system(systemPrompt()), .user(prompt)]
    }
}

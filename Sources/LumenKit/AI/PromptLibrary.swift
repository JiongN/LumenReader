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
    public static func systemPrompt(readerPersona: String = "") -> String {
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
        translateTarget: String = "简体中文"
    ) -> [AIMessage] {

        var messages: [AIMessage] = [.system(systemPrompt(readerPersona: memory))]

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
}

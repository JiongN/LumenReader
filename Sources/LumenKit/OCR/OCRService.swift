import Foundation
import CoreGraphics
import Vision

/// 一行识别结果。
public struct OCRLine: Sendable, Equatable {
    public let text: String
    public let confidence: Float
    /// Vision 的归一化坐标（左下原点，0…1），将来要画高亮框直接用它
    public let box: CGRect

    public init(text: String, confidence: Float, box: CGRect) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

/// 一页的识别结果。
public struct OCRPageResult: Sendable, Equatable {
    public let text: String
    public let lines: [OCRLine]

    public init(text: String, lines: [OCRLine]) {
        self.text = text
        self.lines = lines
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var averageConfidence: Double {
        guard !lines.isEmpty else { return 0 }
        return Double(lines.reduce(Float(0)) { $0 + $1.confidence }) / Double(lines.count)
    }

    /// 「可能的识别错误」行数，用来提示用户核对
    public var lowConfidenceLineCount: Int {
        lines.filter { $0.confidence < 0.5 }.count
    }
}

/// 扫描件识别。
///
/// 只用系统自带的 Vision：不引第三方包，不联网，中英混排由 `zh-Hans` + `en-US`
/// 两个语种一起承担——中文书里夹英文术语是常态，只给中文会把这些词拆得七零八落。
public enum OCRService {

    public static let defaultLanguages = ["zh-Hans", "en-US"]

    /// 识别一张位图。
    ///
    /// - Parameters:
    ///   - image: 已经渲染好的页面位图。调用方负责把清晰度做到位——
    ///           这一层不碰 PDFKit，保持可测、可复用。
    ///   - languages: 语种提示，按优先级排列。
    public static func recognize(
        in image: CGImage,
        languages: [String] = defaultLanguages
    ) throws -> OCRPageResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 书本正文几乎不会出现人名或专有名词的拼写变体，语言校正净收益为正
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.visionFailure(error.localizedDescription)
        }

        guard let observations = request.results, !observations.isEmpty else {
            return OCRPageResult(text: "", lines: [])
        }

        let lines: [OCRLine] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, confidence: candidate.confidence, box: observation.boundingBox)
        }

        return OCRPageResult(text: assembleParagraphs(from: lines), lines: lines)
    }

    // MARK: - 版面还原

    /// 把散落的识别行拼回段落。
    ///
    /// 这一步不是锦上添花：Vision 返回的是「视觉行」，直接按行拼成一段的话，
    /// 每行的换行都会被当成句子边界，送进模型后它会以为满篇都是碎句。
    /// 判断依据取两条——行间距是否明显大于行高（段落间距），以及首行是否缩进。
    private static func assembleParagraphs(from lines: [OCRLine]) -> String {
        guard !lines.isEmpty else { return "" }

        let ordered = lines.sorted { a, b in
            // 纵向差超过行高的一半才算换了行，否则按横向排（同一行的左右两栏）
            let tolerance = max(a.box.height, b.box.height) * 0.5
            if abs(a.box.midY - b.box.midY) > tolerance {
                return a.box.midY > b.box.midY
            }
            return a.box.minX < b.box.minX
        }

        let heights = ordered.map { $0.box.height }.sorted()
        let medianHeight = heights[heights.count / 2]
        // 段落间距的阈值：行高的 0.75 倍。排得松的书也不会误判——
        // 段内行距通常只有行高的 0.3~0.5 倍。
        let paragraphGap = medianHeight * 0.75
        // 首行缩进阈值：页宽的 3%
        let indentThreshold: CGFloat = 0.03

        var paragraphs: [String] = []
        var current: [String] = []
        var previous: OCRLine?

        for line in ordered {
            var startsNewParagraph = false

            if let previous {
                let gap = previous.box.minY - line.box.maxY
                let isIndented = line.box.minX - previous.box.minX > indentThreshold
                startsNewParagraph = gap > paragraphGap || isIndented
            }

            if startsNewParagraph, !current.isEmpty {
                paragraphs.append(joinLines(current))
                current = []
            }

            current.append(line.text)
            previous = line
        }

        if !current.isEmpty {
            paragraphs.append(joinLines(current))
        }

        return paragraphs.joined(separator: "\n\n")
    }

    /// 同一段内的换行要还原成连续文本。中文之间不能插空格，
    /// 英文单词之间必须插——混排文档里这条规则决定了输出可不可读。
    private static func joinLines(_ lines: [String]) -> String {
        guard var result = lines.first else { return "" }
        for line in lines.dropFirst() {
            result += needsSpace(between: result.last, and: line.first) ? " " + line : line
        }
        return result
    }

    private static func needsSpace(between left: Character?, and right: Character?) -> Bool {
        guard let left, let right else { return false }
        return isLatinWordCharacter(left) && isLatinWordCharacter(right)
    }

    private static func isLatinWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

// MARK: - 错误

public enum OCRError: LocalizedError {
    case visionFailure(String)
    case renderFailure

    public var errorDescription: String? {
        switch self {
        case .visionFailure(let detail):
            return "文字识别失败：\(detail)"
        case .renderFailure:
            return "无法把这一页渲染成位图，可能是页面尺寸异常。"
        }
    }
}

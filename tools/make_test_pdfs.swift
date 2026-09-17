// 生成 OCR 验证用的测试 PDF。
//
// 产出两份内容完全相同的文件：
//   1. text.pdf    —— 带文本层，用 CoreText 直接排版
//   2. scanned.pdf —— 把上面那份逐页渲染成位图再重新装订，文本层因此消失，
//                     结构与真实扫描件一致（一页一张图）
//
// 用法：swift tools/make_test_pdfs.swift <输出目录>

import Foundation
import CoreGraphics
import CoreText
import PDFKit
import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: NSTemporaryDirectory())

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let pages: [String] = [
    """
    第一章  乡村学校的文化再生产

    在讨论教育公平的时候，我们习惯把注意力放在资源投入上：生均经费、师生比、 \
    校舍面积。这些指标当然重要，但它们解释不了一个反复出现的现象—— \
    同样的投入水平下，不同学校的学生在学业表现上的差距依然稳定存在。

    布迪厄的文化资本理论提供了一条不同的解释路径。他指出，学校并不是一个 \
    价值中立的筛选装置，它默认学生已经具备一套特定的语言习惯、审美趣味与 \
    行为方式，而这套东西在家庭中习得，而非在学校里教成。于是， \
    那些在家里已经熟悉这套密码的学生，会把学校的评价标准当成自然而然的事情； \
    而另一些学生则要同时完成两件事：学知识，以及猜测规则。

    本章的经验材料来自中部地区三所乡镇初中的田野工作。 \
    研究者在每所学校驻校八周，参与日常教学与课后活动， \
    并对 24 位教师、36 位学生及其家长进行了半结构式访谈。
    """,
    """
    第二章  教师的地方性知识

    教师并不是课程标准的中立执行者。在资源有限的乡镇学校， \
    他们发展出一套地方性知识来应对日常的不确定性： \
    怎样在一个班五十人的情况下兼顾两端， \
    怎样判断一个学生是"不会"还是"不想"， \
    怎样在家长外出务工的情况下完成必要的家校沟通。

    这些知识很少被写进任何文件，却构成了学校实际运转的基础。 \
    值得追问的是：当评价体系越来越依赖可比较的指标时， \
    这些无法被指标捕捉的工作会发生什么？

    访谈中，一位从教十九年的语文教师这样描述自己的日常： \
    "上课只是我工作的一半，另一半是让这些孩子相信，\
    他们读下去是有意义的。"

    这种信念工作，是本章想要概念化的对象。它既不是教学技术， \
    也不是情感劳动，而更接近一种持续的、指向未来的承诺。
    """
]

/// 用 CoreText 把纯文本排版进一个 PDF 上下文
func makeTextPDF(at url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)  // A4
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "make_test_pdfs", code: 1)
    }

    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 14, nil)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 8
    paragraphStyle.paragraphSpacing = 10

    for pageText in pages {
        context.beginPDFPage(nil)

        let attributed = NSAttributedString(
            string: pageText,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle
            ]
        )

        // CoreText 的绘制原点在左下，先平移出上下留白
        context.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = CGRect(x: 64, y: 64, width: mediaBox.width - 128, height: mediaBox.height - 128)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)

        context.endPDFPage()
    }

    context.closePDF()
}

/// 把一份 PDF 逐页栅格化后重新装订，产出没有文本层的"扫描件"
func rasterize(source: URL, destination: URL, scale: CGFloat = 2) throws {
    guard let document = PDFDocument(url: source) else {
        throw NSError(domain: "make_test_pdfs", code: 2)
    }

    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "make_test_pdfs", code: 3)
    }

    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        let bounds = page.bounds(for: .mediaBox)

        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { continue }

        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: bitmap)

        guard let image = bitmap.makeImage() else { continue }

        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
    }

    context.closePDF()
}

let textPDF = outputDirectory.appendingPathComponent("text.pdf")
let scannedPDF = outputDirectory.appendingPathComponent("scanned.pdf")

try makeTextPDF(at: textPDF)
try rasterize(source: textPDF, destination: scannedPDF)

// 校验：文本层必须在第二份里消失
let textDocument = PDFDocument(url: textPDF)
let scannedDocument = PDFDocument(url: scannedPDF)
let textLength = textDocument?.page(at: 0)?.string?.count ?? 0
let scannedLength = scannedDocument?.page(at: 0)?.string?.count ?? 0

print("文本版：\(textPDF.path)  第 1 页文本 \(textLength) 字")
print("扫描版：\(scannedPDF.path)  第 1 页文本 \(scannedLength) 字（应为 0）")
print(scannedLength == 0 && textLength > 100 ? "✅ 测试素材就绪" : "⚠️ 素材可能不符合预期")

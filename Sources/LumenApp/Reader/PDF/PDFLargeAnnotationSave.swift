import AppKit
import PDFKit

/// A large PDF is never serialized from the live PDFView document. Only Lumen's
/// annotations on changed pages are copied; foreign annotations stay in place.
enum PDFLargeAnnotationSave {
    struct Page: Sendable {
        let index: Int
        let annotations: [Data]
    }

    enum SaveError: LocalizedError {
        case unreadable, invalidPage, decode, write, verify, changedExternally, previousFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "无法重新打开 PDF 文件"
            case .invalidPage: "PDF 页数已变化，请重新打开文件"
            case .decode: "无法复制批注，原文件未更改"
            case .write: "无法写入临时 PDF，原文件未更改"
            case .verify: "写入后校验失败，原文件未更改"
            case .changedExternally: "PDF 文件已被其他程序更改，请重新打开后再保存"
            case .previousFailed: "前一次保存失败，后续写入已暂停"
            }
        }
    }

    struct Fingerprint: Sendable, Equatable {
        let size: UInt64
        let modificationTime: TimeInterval
        let fileNumber: UInt64
    }

    nonisolated static func fingerprint(of url: URL) throws -> Fingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber else { throw SaveError.unreadable }
        return Fingerprint(size: size.uint64Value, modificationTime: date.timeIntervalSince1970,
                           fileNumber: number.uint64Value)
    }

    @MainActor
    static func capture(document: PDFDocument, pages: Set<Int>) throws -> [Page] {
        try pages.sorted().map { index in
            guard let page = document.page(at: index) else { throw SaveError.invalidPage }
            let bytes = try page.annotations
                .filter { $0.userName == PDFController.annotationAuthor }
                .map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
            return Page(index: index, annotations: bytes)
        }
    }

    /// Called on a detached task. The PDFDocument and all annotations belong to
    /// this task alone; PDFKit objects are never sent across actor boundaries.
    nonisolated static func write(url: URL, expectedPages: Int, pages: [Page],
                                  expectedFingerprint: Fingerprint) throws -> Fingerprint {
        guard try fingerprint(of: url) == expectedFingerprint else { throw SaveError.changedExternally }
        guard let document = PDFDocument(url: url) else { throw SaveError.unreadable }
        guard document.pageCount == expectedPages else { throw SaveError.invalidPage }
        for snapshot in pages {
            guard let page = document.page(at: snapshot.index) else { throw SaveError.invalidPage }
            for old in page.annotations where old.userName == PDFController.annotationAuthor {
                page.removeAnnotation(old)
            }
            for bytes in snapshot.annotations {
                // PDFAnnotation is NSCoding, but not NSSecureCoding on macOS.
                let decoder = try NSKeyedUnarchiver(forReadingFrom: bytes)
                decoder.requiresSecureCoding = false
                let annotation = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? PDFAnnotation
                decoder.finishDecoding()
                guard let annotation else { throw SaveError.decode }
                page.addAnnotation(annotation)
            }
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lumen-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard document.write(to: temporary) else { throw SaveError.write }
        guard let check = PDFDocument(url: temporary), check.pageCount == expectedPages,
              pages.allSatisfy({ snapshot in
                  guard let page = check.page(at: snapshot.index) else { return false }
                  return page.annotations.filter { $0.userName == PDFController.annotationAuthor }.count
                      == snapshot.annotations.count
              }) else { throw SaveError.verify }
        guard try fingerprint(of: url) == expectedFingerprint else { throw SaveError.changedExternally }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return try fingerprint(of: url)
    }
}

@MainActor
enum PDFPendingSaves {
    private static var count = 0
    private static var onDrained: (() -> Void)?

    static func begin() { count += 1 }
    static func end() {
        count = max(0, count - 1)
        if count == 0 { onDrained?(); onDrained = nil }
    }
    static func whenDrained(_ callback: @escaping () -> Void) -> Bool {
        guard count > 0 else { return false }
        onDrained = callback
        return true
    }
}

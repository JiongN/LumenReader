import AppKit
import PDFKit
import LumenKit

/// A large PDF is never serialized from the live PDFView document. Only Lumen's
/// annotations on changed pages are copied; foreign annotations stay in place.
enum PDFLargeAnnotationSave {
    private static let writeQueue = DispatchQueue(label: "com.jn.lumen.pdf-annotation-save", qos: .utility)
    struct Page: Sendable {
        let index: Int
        let annotations: [Data]
        var replacesAll = false
    }

    enum SaveError: LocalizedError {
        case unreadable, invalidPage, decode, write, verify, changedExternally, previousFailed, helperLaunch(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "无法重新打开 PDF 文件"
            case .invalidPage: "PDF 页数已变化，请重新打开文件"
            case .decode: "无法复制批注，原文件未更改"
            case .write: "无法写入临时 PDF，原文件未更改"
            case .verify: "写入后校验失败，原文件未更改"
            case .changedExternally: "PDF 文件已被其他程序更改，请重新打开后再保存"
            case .previousFailed: "前一次保存失败，后续写入已暂停"
            case .helperLaunch(let message): "无法启动 PDF 保存辅助进程：\(message)"
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
    static func capture(document: PDFDocument, pages: Set<Int>, foreignPages: Set<Int> = []) throws -> [Page] {
        try pages.sorted().map { index in
            guard let page = document.page(at: index) else { throw SaveError.invalidPage }
            let bytes = try PDFAnnotationRelationships.logicalAnnotations(on: page)
                .filter { $0.userName != PDFController.searchHighlightMarker &&
                    (foreignPages.contains(index) || $0.userName == PDFController.annotationAuthor) }
                .map { annotation in
                    guard let color = annotation.color.usingColorSpace(.sRGB) else { throw SaveError.decode }
                    let compact = !foreignPages.contains(index)
                        && ["Highlight", "Underline", "StrikeOut", "Text"].contains(annotation.lumenTypeName)
                    let archive = compact ? nil : try NSKeyedArchiver.archivedData(withRootObject: annotation, requiringSecureCoding: false)
                    return try JSONEncoder().encode(PDFAnnotationRecord(type: annotation.lumenTypeName, bounds: annotation.bounds,
                            color: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent],
                            points: annotation.quadrilateralPoints?.map(\.pointValue) ?? [], contents: annotation.contents,
                            author: annotation.userName, modified: annotation.modificationDate,
                            identity: annotation.value(forAnnotationKey: PDFAnnotationGeometry.identityKey) as? String,
                            shouldDisplay: (annotation as? RoundedHighlightAnnotation)?.nativeShouldDisplay ?? annotation.shouldDisplay,
                            shouldPrint: annotation.shouldPrint, icon: annotation.iconType.rawValue, archive: archive,
                            popupBounds: compact ? nil : PDFAnnotationRelationships.popupBounds(for: annotation, on: page)))
                }
            return Page(index: index, annotations: bytes, replacesAll: foreignPages.contains(index))
        }
    }

    /// Blocking PDFKit I/O must not occupy Swift's cooperative executor.
    nonisolated static func writeInBackground(url: URL, expectedPages: Int, pages: [Page],
                                             expectedFingerprint: Fingerprint?) async -> Result<Fingerprint, Error> {
        await withCheckedContinuation { continuation in
            writeQueue.async {
                let outcome = Result {
                    try autoreleasepool {
                        guard let expectedFingerprint else { throw SaveError.previousFailed }
                        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                        if size >= 64 * 1_048_576 {
                            return try writeWithHelper(url: url, expectedPages: expectedPages, pages: pages, expected: expectedFingerprint)
                        }
                        return try write(url: url, expectedPages: expectedPages, pages: pages, expectedFingerprint: expectedFingerprint)
                    }
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    nonisolated static func writeWithHelper(url: URL, expectedPages: Int, pages: [Page], expected: Fingerprint) throws -> Fingerprint {
        guard try fingerprint(of: url) == expected else { throw SaveError.changedExternally }
        let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LumenPDFWorker")
        let commandDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var developmentCandidates: [URL] = []
        let packageBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/LumenPDFWorker")
        developmentCandidates.append(packageBuild)
        var ancestor = commandDirectory
        for _ in 0..<6 {
            developmentCandidates.append(ancestor.appendingPathComponent("LumenPDFWorker"))
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        let helper = ([executable].compactMap { $0 } + developmentCandidates)
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let helper else { throw SaveError.helperLaunch("找不到 LumenPDFWorker") }
        let work = url.deletingLastPathComponent().appendingPathComponent(".lumen-save-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let output = work.appendingPathComponent("result.pdf"), request = work.appendingPathComponent("job.json")
        let job = PDFSaveJob(inputPath: url.path, outputPath: output.path, expectedPages: expectedPages,
            pages: pages.map { .init(index: $0.index, annotations: $0.annotations, replacesAll: $0.replacesAll) }, author: PDFController.annotationAuthor)
        try JSONEncoder().encode(job).write(to: request, options: .atomic)
        let process = Process()
        process.executableURL = helper; process.arguments = [request.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw SaveError.helperLaunch(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw SaveError.write }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SaveError.verify }
        return try PDFFileReplacement.commit(temporary: output, to: url, expected: expected)
    }

    /// The private PDFDocument and annotations remain on the writer's thread.
    nonisolated static func write(url: URL, expectedPages: Int, pages: [Page],
                                  expectedFingerprint: Fingerprint) throws -> Fingerprint {
        guard try fingerprint(of: url) == expectedFingerprint else { throw SaveError.changedExternally }
        guard let document = PDFDocument(url: url) else { throw SaveError.unreadable }
        guard document.pageCount == expectedPages else { throw SaveError.invalidPage }
        for snapshot in pages {
            guard let page = document.page(at: snapshot.index) else { throw SaveError.invalidPage }
            let replaced = page.annotations.filter { snapshot.replacesAll || $0.userName == PDFController.annotationAuthor }
            PDFAnnotationRelationships.remove(replaced, from: page)
            for bytes in snapshot.annotations {
                if let record = try? JSONDecoder().decode(PDFAnnotationRecord.self, from: bytes) {
                    page.addAnnotation(try annotation(from: record)); continue
                }
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
                  return PDFAnnotationRelationships.logicalAnnotations(on: page)
                      .filter { snapshot.replacesAll || $0.userName == PDFController.annotationAuthor }.count
                      == snapshot.annotations.count
              }) else { throw SaveError.verify }
        return try PDFFileReplacement.commit(temporary: temporary, to: url, expected: expectedFingerprint)
    }

    nonisolated static func annotation(from record: PDFAnnotationRecord) throws -> PDFAnnotation {
        try record.makeAnnotation()
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

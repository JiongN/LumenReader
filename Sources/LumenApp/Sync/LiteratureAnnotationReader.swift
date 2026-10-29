import Foundation
import AppKit
import PDFKit
import LumenKit

enum LiteratureReadError: Error, LocalizedError {
    case unavailable
    case changed
    case invalidEPUBArchive

    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读取文献或批注文件。"
        case .changed: return "文献在读取期间发生变化，请稍后重试。"
        case .invalidEPUBArchive: return "EPUB 批注文件无法解码，原文件已保留。"
        }
    }
}

/// Uses a private PDFDocument on a utility queue, never the reader's PDFView.
enum LiteratureAnnotationReader {
    private static let queue = DispatchQueue(label: "com.jn.lumen.literature-snapshot", qos: .utility)

    private struct EPUBArchive: Decodable {
        struct Item: Decodable {
            var id: String
            var locatorKey: String
            var quote: String
            var note: String
            var hasHighlight: Bool
            var createdAt: Date
            var highlightHex: String?
        }
        var items: [Item]
    }

    static func sourceURL(for documentURL: URL) -> URL {
        documentURL.pathExtension.lowercased() == "epub"
            ? AppPaths.annotationsFile(forPath: documentURL.standardizedFileURL.path) : documentURL
    }

    static func read(documentURL: URL, documentID: String, forceHelper: Bool = false) async throws -> LiteratureAttachmentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result: Result<LiteratureAttachmentSnapshot, Error> = Result {
                    try autoreleasepool {
                        let source = sourceURL(for: documentURL)
                        let before = try version(of: source)
                        let annotations: [LiteratureAnnotation]
                        if documentURL.pathExtension.lowercased() == "epub" {
                            annotations = try readEPUB(source)
                        } else {
                            let size = (try documentURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                            annotations = try (forceHelper || size >= 64 * 1_048_576
                                ? readPDFInHelper(documentURL) : PDFAnnotationSnapshot.read(url: documentURL))
                                .map(LiteratureAnnotation.init)
                        }
                        guard try version(of: source) == before else { throw LiteratureReadError.changed }
                        return LiteratureAttachmentSnapshot(documentID: documentID,
                            title: documentURL.lastPathComponent, annotations: annotations)
                    }
                }
                continuation.resume(with: result)
            }
        }
    }

    /// Nil denotes a not-yet-created EPUB archive, not an inaccessible file.
    static func version(of url: URL) throws -> PDFLargeAnnotationSave.Fingerprint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PDFLargeAnnotationSave.fingerprint(of: url)
    }

    private static func readEPUB(_ url: URL) throws -> [LiteratureAnnotation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let archive = try? JSONDecoder().decode(EPUBArchive.self, from: data) else {
            throw LiteratureReadError.invalidEPUBArchive
        }
        return try archive.items.map { item in
            guard let locator = DocumentLocator.parse(storageKey: item.locatorKey) else { throw LiteratureReadError.invalidEPUBArchive }
            return LiteratureAnnotation(AnnotationItem(id: item.id, locator: locator, quote: item.quote,
                note: item.note, hasHighlight: item.hasHighlight, createdAt: .distantPast, highlightHex: item.highlightHex))
        }
    }

    private static func readPDFInHelper(_ url: URL) throws -> [AnnotationItem] {
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LumenPDFWorker")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/LumenPDFWorker")
        guard let executable = [sibling, development].compactMap({ $0 })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw LiteratureReadError.unavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("annotations.json")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--snapshot", url.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw LiteratureReadError.unavailable }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              ((try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 32 * 1_048_576 else {
            throw LiteratureReadError.unavailable
        }
        return try JSONDecoder().decode([AnnotationItem].self, from: Data(contentsOf: output))
    }
}

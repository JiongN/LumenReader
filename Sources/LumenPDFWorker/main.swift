import Foundation
import PDFKit
import AppKit
import LumenKit

// The helper writes only a temporary PDF. Original-file coordination and commit
// remain in the parent process alongside OCR and external-change protection.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--snapshot" {
    do {
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        guard input.path != output.path, !FileManager.default.fileExists(atPath: output.path) else { exit(65) }
        let items = try PDFAnnotationSnapshot.read(url: input)
        let bytes = try JSONEncoder().encode(items)
        guard bytes.count <= 32 * 1024 * 1024 else { exit(65) }
        try bytes.write(to: output, options: .withoutOverwriting)
        exit(0)
    } catch { exit(74) }
}
do {
    guard CommandLine.arguments.count == 2 else { exit(64) }
    let file = URL(fileURLWithPath: CommandLine.arguments[1])
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { exit(65) }
    let job = try JSONDecoder().decode(PDFSaveJob.self, from: Data(contentsOf: file))
    try autoreleasepool {
        guard job.inputPath != job.outputPath,
              !FileManager.default.fileExists(atPath: job.outputPath),
              let document = PDFDocument(url: URL(fileURLWithPath: job.inputPath)),
              document.pageCount == job.expectedPages else { throw CocoaError(.fileReadCorruptFile) }
        for update in job.pages {
            guard update.index >= 0, let page = document.page(at: update.index) else { throw CocoaError(.fileReadCorruptFile) }
            PDFAnnotationRelationships.remove(page.annotations.filter { update.replacesAll || $0.userName == job.author }, from: page)
            for data in update.annotations {
                if let record = try? JSONDecoder().decode(PDFAnnotationRecord.self, from: data) {
                    page.addAnnotation(try record.makeAnnotation()); continue
                }
                let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
                decoder.requiresSecureCoding = false
                guard let annotation = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? PDFAnnotation else { throw CocoaError(.coderReadCorrupt) }
                decoder.finishDecoding()
                page.addAnnotation(annotation)
            }
        }
        let output = URL(fileURLWithPath: job.outputPath)
        guard document.write(to: output), let check = PDFDocument(url: output), check.pageCount == job.expectedPages,
              job.pages.allSatisfy({ update in
                  guard let page = check.page(at: update.index) else { return false }
                  return PDFAnnotationRelationships.logicalAnnotations(on: page)
                      .filter { update.replacesAll || $0.userName == job.author }.count == update.annotations.count
              }) else { throw CocoaError(.fileWriteUnknown) }
    }
    exit(0)
} catch { exit(74) }

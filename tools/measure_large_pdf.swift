// Read a real PDF, add one note in memory, and write only to a temporary copy.
// Usage: swift tools/measure_large_pdf.swift /absolute/path/to/large.pdf [--stream]
import AppKit
import PDFKit
import Foundation
import Darwin

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("Usage: swift tools/measure_large_pdf.swift /path/to/large.pdf [--stream]\n", stderr)
    exit(2)
}
let stream = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--stream"

let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let destination = FileManager.default.temporaryDirectory
    .appendingPathComponent("lumen-large-save-\(UUID().uuidString).pdf")
defer { try? FileManager.default.removeItem(at: destination) }

func now() -> Double { ProcessInfo.processInfo.systemUptime }
func mib(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? mib(info.phys_footprint) : -1
}

let fileSize = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.uint64Value ?? 0
let start = now()
guard let document = PDFDocument(url: source), let first = document.page(at: 0) else {
    fputs("Cannot load PDF\n", stderr)
    exit(1)
}
let opened = now()
let beforeMemory = footprint()
let box = first.bounds(for: .mediaBox)
let note = PDFAnnotation(bounds: CGRect(x: box.minX + 30, y: box.maxY - 60, width: 24, height: 24),
                         forType: .text, withProperties: nil)
note.contents = "Lumen large-save verification"
note.userName = "Lumen benchmark"
first.addAnnotation(note)
let beforeSerialize = now()
var outputSize: UInt64 = 0
var afterSerialize = beforeSerialize
var afterWrite = beforeSerialize
if stream {
    guard document.write(to: destination) else {
        fputs("PDF streaming write failed\n", stderr)
        exit(1)
    }
    afterSerialize = now()
    afterWrite = afterSerialize
    outputSize = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.uint64Value ?? 0
} else {
    guard let bytes = document.dataRepresentation() else {
        fputs("PDF serialization failed\n", stderr)
        exit(1)
    }
    afterSerialize = now()
    try bytes.write(to: destination, options: .atomic)
    afterWrite = now()
    outputSize = UInt64(bytes.count)
}
let serializedMemory = footprint()
guard let reopened = PDFDocument(url: destination),
      let savedPage = reopened.page(at: 0),
      savedPage.annotations.contains(where: { $0.contents == note.contents }),
      reopened.pageCount == document.pageCount else {
    fputs("Saved PDF failed annotation/page-count round trip\n", stderr)
    exit(1)
}
let afterVerify = now()
print(String(format: "[Lumen][large-save] mode=%@ sourceMB=%.1f pages=%d openMs=%.1f serializeMs=%.1f writeMs=%.1f verifyMs=%.1f memoryBeforeMB=%.1f memoryAfterSerializeMB=%.1f outputMB=%.1f pass=true",
             stream ? "write(to:)" : "dataRepresentation",
             mib(fileSize), document.pageCount, (opened - start) * 1000,
             (afterSerialize - beforeSerialize) * 1000, (afterWrite - afterSerialize) * 1000,
             (afterVerify - afterWrite) * 1000, beforeMemory, serializedMemory, mib(outputSize)))

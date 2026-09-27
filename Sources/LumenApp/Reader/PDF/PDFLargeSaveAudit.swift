import Foundation
import PDFKit

/// Runs only with --large-save-report. The supplied book is read-only; every
/// mutation targets an APFS copy in a temporary directory.
@MainActor
enum PDFLargeSaveAudit {
    static func run(sourceURL: URL) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-large-save-audit-\(UUID().uuidString)", isDirectory: true)
        let copy = directory.appendingPathComponent("audit.pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: copy)
        } catch {
            NSLog("%@", "[Lumen][large-save] copy failed: \(error)")
            return
        }
        let controller = PDFController()
        guard controller.load(url: copy) != nil else {
            NSLog("%@", "[Lumen][large-save] cannot load copy")
            return
        }
        let pageCount = controller.pageCount
        var receipts: [String] = []
        controller.onFileSaved = { ok, message in receipts.append("\(ok):\(message)") }
        let start = ProcessInfo.processInfo.systemUptime
        let first = controller.addNote(pageIndex: 0, anchorText: "", body: "Lumen large audit A")
        let second = controller.addNote(pageIndex: 0, anchorText: "", body: "Lumen large audit B")
        let enqueueMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var late: [Double] = []
        var last = ProcessInfo.processInfo.systemUptime
        while controller.pendingSaveCount > 0,
              ProcessInfo.processInfo.systemUptime - start < 100 {
            try? await Task.sleep(for: .milliseconds(16))
            let now = ProcessInfo.processInfo.systemUptime
            late.append(max(0, (now - last) * 1000 - 16))
            last = now
        }
        guard let saved = PDFDocument(url: copy), let page = saved.page(at: 0) else {
            NSLog("%@", "[Lumen][large-save] reopen failed")
            return
        }
        let bodies = Set(page.annotations.compactMap(\.contents))
        let queuedPass = first && second && controller.pendingSaveCount == 0
            && receipts.count == 2 && receipts.allSatisfy { $0.hasPrefix("true:") }
            && bodies.contains("Lumen large audit A") && bodies.contains("Lumen large audit B")
            && saved.pageCount == pageCount

        let rows = await controller.annotationsList()
        let firstID = rows.first { $0.note == "Lumen large audit A" }?.id
        let edited = firstID.map { controller.updateNote(id: $0, body: "Lumen large audit A edited") } ?? false
        while controller.pendingSaveCount > 0,
              ProcessInfo.processInfo.systemUptime - start < 150 {
            try? await Task.sleep(for: .milliseconds(16))
        }
        let editedOnDisk = PDFDocument(url: copy)?.page(at: 0)?.annotations
            .contains { $0.contents == "Lumen large audit A edited" } ?? false
        let secondID = rows.first { $0.note == "Lumen large audit B" }?.id
        let deleted = secondID.map { controller.deleteAnnotation(id: $0) } ?? false
        while controller.pendingSaveCount > 0,
              ProcessInfo.processInfo.systemUptime - start < 200 {
            try? await Task.sleep(for: .milliseconds(16))
        }
        let afterDelete = PDFDocument(url: copy)
        let deletionSaved = afterDelete?.page(at: 0)?.annotations
            .allSatisfy { $0.contents != "Lumen large audit B" } ?? false
        let originalFingerprint = try? PDFLargeAnnotationSave.fingerprint(of: copy)
        var externalChangeBlocked = false
        if let originalFingerprint {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970:
                originalFingerprint.modificationTime + 10)], ofItemAtPath: copy.path)
            do {
                _ = try PDFLargeAnnotationSave.write(url: copy, expectedPages: pageCount,
                    pages: [], expectedFingerprint: originalFingerprint)
            } catch PDFLargeAnnotationSave.SaveError.changedExternally {
                externalChangeBlocked = true
            } catch {}
        }
        let p95 = late.sorted()[safe: Int(Double(max(0, late.count - 1)) * 0.95)] ?? 0
        let maxLate = late.max() ?? 0
        let pass = queuedPass && edited && editedOnDisk && deleted && deletionSaved
            && externalChangeBlocked && receipts.count == 4
            && receipts.allSatisfy { $0.hasPrefix("true:") }
        NSLog("%@", String(format:
            "[Lumen][large-save] sourceMB=%.1f pages=%d addQueued=%@ editSaved=%@ deleteSaved=%@ externalChangeBlocked=%@ enqueueMs=%.1f mainTimerLateP95Ms=%.1f mainTimerLateMaxMs=%.1f writes=%d pass=%@",
            Double((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1_048_576,
            pageCount, queuedPass.description, editedOnDisk.description, deletionSaved.description,
            externalChangeBlocked.description, enqueueMs,
            p95, maxLate, receipts.count, pass.description))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

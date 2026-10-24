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
        defer { controller.unload() }
        // The actual reader is already visible. Loading a second, unattached
        // PDFView measures its deferred layout, not just the save under test.
        let attached = LaunchOptions.flag("--large-save-attached")
        guard controller.load(url: copy, attachToView: attached) != nil else {
            NSLog("%@", "[Lumen][large-save] cannot load copy")
            return
        }
        let pageCount = controller.pageCount
        // Save latency and cold window/font/layout latency are separate metrics.
        // The latter stays observable with the attached control above.
        if !attached { try? await Task.sleep(for: .milliseconds(750)) }
        let mainTimer = MainQueueSaveTimer()
        mainTimer.start()
        defer { mainTimer.stop() }
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
            if now - last > 0.048 {
                NSLog("%@", String(format: "[Lumen][large-save-phase] add elapsedMs=%.1f lateMs=%.1f pending=%d",
                    (now - start) * 1000, (now - last) * 1000 - 16, controller.pendingSaveCount))
            }
            last = now
        }
        guard let saved = PDFDocument(url: copy), let page = saved.page(at: 0) else {
            NSLog("%@", "[Lumen][large-save] reopen failed")
            return
        }
        let bodies = Set(page.annotations.compactMap(\.contents))
        let queuedPass = first && second && controller.pendingSaveCount == 0
            && receipts.count == 1 && receipts.allSatisfy { $0.hasPrefix("true:") }
            && bodies.contains("Lumen large audit A") && bodies.contains("Lumen large audit B")
            && saved.pageCount == pageCount

        let listStart = ProcessInfo.processInfo.systemUptime
        let rows = await controller.annotationsList()
        let firstListMs = (ProcessInfo.processInfo.systemUptime - listStart) * 1000
        let cachedStart = ProcessInfo.processInfo.systemUptime
        let cachedRows = await controller.annotationsList()
        NSLog("%@", String(format: "[Lumen][annotation-list] coldMs=%.1f cachedMs=%.1f same=%@ cachePages=%d cacheBytes=%d",
            firstListMs, (ProcessInfo.processInfo.systemUptime - cachedStart) * 1000,
            (rows == cachedRows).description, controller.annotationListCacheStats.pages, controller.annotationListCacheStats.bytes))
        let firstID = rows.first { $0.note == "Lumen large audit A" }?.id
        let edited = firstID.map { controller.updateNote(id: $0, body: "Lumen large audit A edited") } ?? false
        last = ProcessInfo.processInfo.systemUptime
        while controller.pendingSaveCount > 0,
              ProcessInfo.processInfo.systemUptime - start < 150 {
            try? await Task.sleep(for: .milliseconds(16))
            let now = ProcessInfo.processInfo.systemUptime
            late.append(max(0, (now - last) * 1000 - 16))
            if now - last > 0.048 {
                NSLog("%@", String(format: "[Lumen][large-save-phase] edit elapsedMs=%.1f lateMs=%.1f pending=%d",
                    (now - start) * 1000, (now - last) * 1000 - 16, controller.pendingSaveCount))
            }
            last = now
        }
        let editedOnDisk = PDFDocument(url: copy)?.page(at: 0)?.annotations
            .contains { $0.contents == "Lumen large audit A edited" } ?? false
        let secondID = rows.first { $0.note == "Lumen large audit B" }?.id
        let deleted = secondID.map { controller.deleteAnnotation(id: $0) } ?? false
        last = ProcessInfo.processInfo.systemUptime
        while controller.pendingSaveCount > 0,
              ProcessInfo.processInfo.systemUptime - start < 200 {
            try? await Task.sleep(for: .milliseconds(16))
            let now = ProcessInfo.processInfo.systemUptime
            late.append(max(0, (now - last) * 1000 - 16))
            if now - last > 0.048 {
                NSLog("%@", String(format: "[Lumen][large-save-phase] delete elapsedMs=%.1f lateMs=%.1f pending=%d",
                    (now - start) * 1000, (now - last) * 1000 - 16, controller.pendingSaveCount))
            }
            last = now
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
        mainTimer.stop()
        let dispatchLate = mainTimer.samples.sorted()
        let dispatchP95 = dispatchLate[safe: Int(Double(max(0, dispatchLate.count - 1)) * 0.95)] ?? 0
        let pass = queuedPass && edited && editedOnDisk && deleted && deletionSaved
            && externalChangeBlocked && receipts.count == 3
            && receipts.allSatisfy { $0.hasPrefix("true:") }
        NSLog("%@", String(format:
            "[Lumen][large-save] sourceMB=%.1f pages=%d addQueued=%@ editSaved=%@ deleteSaved=%@ externalChangeBlocked=%@ enqueueMs=%.1f mainTimerLateP95Ms=%.1f mainTimerLateMaxMs=%.1f mainDispatchP95Ms=%.1f mainDispatchMaxMs=%.1f dispatchSamples=%d writes=%d pass=%@ attached=%@",
            Double((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1_048_576,
            pageCount, queuedPass.description, editedOnDisk.description, deletionSaved.description,
            externalChangeBlocked.description, enqueueMs,
            p95, maxLate, dispatchP95, dispatchLate.last ?? 0, dispatchLate.count,
            receipts.count, pass.description, attached.description))
    }
}

@MainActor
private final class MainQueueSaveTimer {
    private var timer: DispatchSourceTimer?
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var samples: [Double] = []

    func start() {
        last = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.samples.count < 20_000 { self.samples.append(max(0, (now - self.last) * 1000 - 16)) }
                self.last = now
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() { timer?.cancel(); timer = nil }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

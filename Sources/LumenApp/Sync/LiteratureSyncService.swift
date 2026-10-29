import Foundation
import AppKit
import Combine
import LumenKit

/// Opt-in synchronization: annotations flow to Markdown, while reading notes
/// and properties are edited in the shared page. Zotero is an optional source.
@MainActor
final class LiteratureSyncService: ObservableObject {
    static let shared = LiteratureSyncService()

    struct Record: Codable, Identifiable, Sendable {
        var id: String
        var documentPath: String
        var notePath: String
        var title: String
        var zotero: LiteratureZoteroIdentity?
        var baseline: LiteratureNoteBaseline?
        var backupPath: String?
        var paused = false
        var propertiesInitialized: Bool? = nil
        var pageStyleVersion: Int? = nil
    }
    private struct State: Codable {
        var version = 1
        var notesDirectory = ""
        var enabled = false
        var records: [Record] = []
        var metadataBaselines: [String: String]? = nil

        var isValid: Bool {
            version == 1 && (!enabled || notesDirectory.hasPrefix("/")) &&
                Set(records.map(\.id)).count == records.count &&
                Set(records.map(\.documentPath)).count == records.count &&
                records.allSatisfy { record in
                    !record.id.isEmpty && record.documentPath.hasPrefix("/") && record.notePath.hasPrefix("/") &&
                        (record.baseline == nil || record.baseline?.snapshot.documentID == record.id)
                }
        }
    }
    private struct Signature: Equatable, Sendable {
        var source: PDFLargeAnnotationSave.Fingerprint?
        var note: PDFLargeAnnotationSave.Fingerprint?
    }
    private struct AcceptedSource {
        var version: PDFLargeAnnotationSave.Fingerprint?
    }

    @Published private(set) var notesDirectory = ""
    @Published private(set) var enabled = false
    @Published private(set) var records: [Record] = []
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var error: String?
    private let associationRetryInterval: TimeInterval
    private let lookups = LiteratureLookupTasks()
    private let stateURL: URL
    let files: LiteratureNoteFiles
    private let resolve: @Sendable (URL) async throws -> LiteratureZoteroIdentity
    private let refresh: @Sendable (LiteratureZoteroIdentity, URL) async throws -> LiteratureZoteroIdentity
    private let readAnnotations: @Sendable (URL, String) async throws -> LiteratureAttachmentSnapshot
    private var healthy = true
    private var inFlight: Set<String> = []
    private var lastSignatures: [String: Signature] = [:]
    // A committed baseline is reusable only while its source fingerprint is unchanged.
    // Keep just the fingerprint: the snapshot itself already lives in the baseline.
    private var acceptedSources: [String: AcceptedSource] = [:]
    private var blockedByUserEdit: Set<String> = []
    private var metadataBaselines: [String: String] = [:]
    private var metadataChecked: [String: Date] = [:]
    private var offlineChecked: [String: Date] = [:]
    private var unmatched: Set<String> = []
    private var zoteroLaunchObserver: AnyCancellable?
    private var pendingChanges: [String: Task<Void, Never>] = [:]
    private var loop: Task<Void, Never>?

    init(stateURL: URL = AppPaths.supportRoot.appendingPathComponent("literature-sync.json"),
         backupDirectory: URL = AppPaths.supportRoot.appendingPathComponent("literature-sync-backups", isDirectory: true),
         associationRetryInterval: TimeInterval = 10,
         resolve: @escaping @Sendable (URL) async throws -> LiteratureZoteroIdentity = ZoteroLibraryLookup.resolve,
         refresh: @escaping @Sendable (LiteratureZoteroIdentity, URL) async throws -> LiteratureZoteroIdentity = ZoteroLibraryLookup.refresh,
         readAnnotations: @escaping @Sendable (URL, String) async throws -> LiteratureAttachmentSnapshot = {
             try await LiteratureAnnotationReader.read(documentURL: $0, documentID: $1)
         }) {
        self.associationRetryInterval = associationRetryInterval
        self.stateURL = stateURL
        self.files = LiteratureNoteFiles(backupDirectory: backupDirectory)
        self.resolve = resolve
        self.refresh = refresh
        self.readAnnotations = readAnnotations
        if FileManager.default.fileExists(atPath: stateURL.path) {
            if let data = try? Data(contentsOf: stateURL),
               let state = try? JSONDecoder().decode(State.self, from: data), state.isValid {
                notesDirectory = state.notesDirectory
                enabled = state.enabled
                records = state.records
                metadataBaselines = state.metadataBaselines ?? [:]
            } else {
                healthy = false
                error = "同步记录无法读取；原记录已保留，自动同步已停用。"
            }
        }
    }

    private func persist() throws {
        guard healthy else { throw LiteratureFileError.stateFailed }
        let state = State(notesDirectory: notesDirectory, enabled: enabled, records: records, metadataBaselines: metadataBaselines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard PersistFile.write(try encoder.encode(state), to: stateURL, label: "literature-sync.json") else {
            throw LiteratureFileError.stateFailed
        }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Obsidian 文献笔记目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if !notesDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath: notesDirectory) }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        configureDirectory(selected)
    }

    func configureDirectory(_ url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard records.isEmpty || notesDirectory == path else {
            error = "已有文献关联，不能直接切换目录。请先保留同步记录并迁移关联。"
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = LiteratureFileError.invalidFolder.localizedDescription
            return
        }
        let previous = notesDirectory
        notesDirectory = path
        do { try persist(); error = nil } catch { notesDirectory = previous; self.error = error.localizedDescription }
    }

    func setEnabled(_ value: Bool) {
        if value {
            guard !notesDirectory.isEmpty else { error = "请先选择 Obsidian 的文献笔记目录。"; return }
            guard ZoteroOneWriterGuard.isSafe(notesDirectory: URL(fileURLWithPath: notesDirectory)) else {
                error = "Zotero One 的该目录仍可能由自动模式更新。请先在 Zotero One 的笔记设置中关闭自动模式。"
                return
            }
        }
        let previous = enabled
        enabled = value
        do {
            try persist()
            error = nil
            if value { start() }
            else { lookups.cancel() }
        } catch { enabled = previous; self.error = error.localizedDescription }
    }

    func start() {
        guard healthy, loop == nil, !AppPaths.isTestInvocation(CommandLine.arguments),
              !AppPaths.isDiagnosticInvocation(CommandLine.arguments) || ProcessInfo.processInfo.environment["LUMEN_TEST_DATA"] != nil else { return }
        zoteroLaunchObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] notification in
                let identifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard identifier == "org.zotero.zotero" else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.offlineChecked.removeAll()
                    self.metadataChecked.removeAll()
                    self.unmatched.removeAll()
                    self.lookups.cancel()
                    await self.reconcile()
                }
            }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.enabled {
                    await self.reconcile()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Also used by startup and tests: no open reader or manual sync is needed.
    func reconcile() async {
        guard enabled else { return }
        for record in records where !record.paused {
            guard !Task.isCancelled else { return }
            guard pendingChanges[record.documentPath] == nil else { continue }
            if await needsSync(record) { await sync(recordID: record.id) }
        }
    }

    func record(for path: String) -> Record? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return records.first { $0.documentPath == normalized }
    }

    func record(id: String) -> Record? { records.first { $0.id == id } }

    func annotationSaved(documentURL: URL) {
        guard enabled else { return }
        let path = documentURL.standardizedFileURL.path
        // Each document now has an explicit opt-in switch. Saving an annotation
        // must not silently enroll an unlinked or paused document.
        guard let record = record(for: path), !record.paused else { return }
        pendingChanges[path]?.cancel()
        pendingChanges[path] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            self.pendingChanges.removeValue(forKey: path)
            await self.adoptAndSync(documentURL: documentURL, forceMetadata: false)
        }
    }

    nonisolated private static func signature(_ record: Record) -> Signature? {
        let source = LiteratureAnnotationReader.sourceURL(for: URL(fileURLWithPath: record.documentPath))
        do {
            return Signature(source: try LiteratureAnnotationReader.version(of: source),
                             note: try LiteratureAnnotationReader.version(of: URL(fileURLWithPath: record.notePath)))
        } catch { return nil }
    }

    private func needsSync(_ record: Record) async -> Bool {
        let signature = await Task.detached(priority: .utility) { Self.signature(record) }.value
        if let signature, lastSignatures[record.id] != signature { return true }
        if blockedByUserEdit.contains(record.id) { return false }
        if record.zotero == nil, associationDue(record.id) { return true }
        if let identity = record.zotero {
            let key = LiteratureMetadataCodec.key(identity)
            if Date().timeIntervalSince(metadataChecked[key] ?? .distantPast) >= 60 { return true }
        }
        return signature == nil
    }

    private func associationDue(_ id: String) -> Bool {
        let interval = unmatched.contains(id) ? max(60, associationRetryInterval) : associationRetryInterval
        return Date().timeIntervalSince(offlineChecked[id] ?? .distantPast) >= interval
    }

    func adoptAndSync(documentURL: URL, forceMetadata: Bool = true) async {
        let path = documentURL.standardizedFileURL.path
        guard enabled else { error = "请先在设置的「文献笔记」中启用同步。"; return }
        guard !inFlight.contains(path) else { return }
        if let existing = record(for: path) {
            if forceMetadata { await syncNow(recordID: existing.id) }
            else { await sync(recordID: existing.id) }
            return
        }
        guard ZoteroOneWriterGuard.isSafe(notesDirectory: URL(fileURLWithPath: notesDirectory)) else {
            error = "Zotero One 的自动模式尚未关闭，同步已暂停。"
            return
        }
        inFlight.insert(path)
        defer { inFlight.remove(path) }
        setStatus(path, "正在读取文献信息…")
        do {
            let identity: LiteratureZoteroIdentity?
            do { identity = try await lookups.lookup(documentURL, initial: true, resolve: resolve) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Library absence, unavailable API and ambiguous matches never
                // prevent first-time notes. Retry in the background later.
                identity = nil
            }
            guard enabled else { return }
            let directory = URL(fileURLWithPath: notesDirectory, isDirectory: true)
            let documentID = UUID().uuidString
            let title = identity?.title ?? documentURL.deletingPathExtension().lastPathComponent
            let noteURL: URL
            if let identity {
                let candidate = try await Task.detached { try LiteratureNoteIndex.matchingPage(in: directory, itemLink: identity.itemLink) }.value
                let newURL = LiteratureNoteIndex.newPageURL(in: directory, identity: identity, filename: documentURL.deletingPathExtension().lastPathComponent)
                if candidate == nil && FileManager.default.fileExists(atPath: newURL.path) {
                    throw LiteratureFileError.duplicatePages
                }
                noteURL = candidate ?? newURL
            } else {
                let fallback = LiteratureZoteroIdentity(library: "library", itemKey: documentID, attachmentKey: documentID,
                                                        title: title, authors: "", year: "")
                noteURL = LiteratureNoteIndex.newPageURL(in: directory, identity: fallback, filename: documentURL.deletingPathExtension().lastPathComponent)
            }
            guard !records.contains(where: { $0.documentPath == path }) else { return }
            let record = Record(id: documentID, documentPath: path, notePath: noteURL.path,
                                title: title, zotero: identity, baseline: nil, backupPath: nil)
            records.append(record)
            if identity == nil { offlineChecked[documentID] = Date() }
            else if let identity { metadataChecked[LiteratureMetadataCodec.key(identity)] = Date() }
            do { try persist() } catch { records.removeAll { $0.id == documentID }; throw error }
            inFlight.remove(path)
            await sync(recordID: documentID, discoverMetadata: false)
        } catch is CancellationError {
            setStatus(path, "同步已取消")
        } catch {
            setStatus(path, error.localizedDescription)
            self.error = error.localizedDescription
        }
    }

    func sync(recordID: String, discoverMetadata: Bool = true) async {
        guard enabled, let record = record(id: recordID), !record.paused,
              !inFlight.contains(record.documentPath) else { return }
        let path = record.documentPath
        guard ZoteroOneWriterGuard.isSafe(notesDirectory: URL(fileURLWithPath: notesDirectory)) else {
            setStatus(path, "Zotero One 自动模式开启或状态未知，已暂停同步")
            return
        }
        inFlight.insert(path)
        defer { inFlight.remove(path) }
        setStatus(path, "正在同步…")
        var attemptedSignature: Signature?
        do {
            let sourceURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { throw LiteratureReadError.unavailable }
            var identity = record.zotero
            var usingCachedMetadata = false
            var attachIdentity = false
            var associationConflict = false
            var associationAmbiguous = false
            if discoverMetadata, identity == nil, associationDue(record.id) {
                offlineChecked[record.id] = Date()
                do {
                    guard let candidate = try await lookups.lookup(sourceURL, initial: false, resolve: resolve) else {
                        throw ZoteroLookupError.noMatch
                    }
                    unmatched.remove(record.id)
                    let folder = URL(fileURLWithPath: notesDirectory, isDirectory: true)
                    let match = try await Task.detached { try LiteratureNoteIndex.matchingPage(in: folder, itemLink: candidate.itemLink) }.value
                    let otherRecord = records.contains { $0.id != record.id && $0.zotero.map(LiteratureMetadataCodec.key) == LiteratureMetadataCodec.key(candidate) && URL(fileURLWithPath: $0.notePath).resolvingSymlinksInPath().path != URL(fileURLWithPath: record.notePath).resolvingSymlinksInPath().path }
                    if (match == nil || match?.resolvingSymlinksInPath().path == URL(fileURLWithPath: record.notePath).resolvingSymlinksInPath().path) && !otherRecord {
                        identity = candidate; attachIdentity = true
                    } else { associationConflict = true }
                } catch ZoteroLookupError.noMatch { unmatched.insert(record.id) }
                catch ZoteroLookupError.ambiguous { associationAmbiguous = true; unmatched.insert(record.id) }
                catch is CancellationError { throw CancellationError() }
                catch { usingCachedMetadata = true }
                offlineChecked[record.id] = Date()
            }
            if let current = identity, !attachIdentity {
                let key = LiteratureMetadataCodec.key(current)
                if Date().timeIntervalSince(metadataChecked[key] ?? .distantPast) >= 60 {
                    metadataChecked[key] = Date()
                    do { identity = try await refresh(current, sourceURL) }
                    catch is CancellationError { throw CancellationError() }
                    catch { usingCachedMetadata = true }
                } else if let peer = records.compactMap(\.zotero).first(where: { LiteratureMetadataCodec.key($0) == key }) {
                    identity?.title = peer.title
                    identity?.authors = peer.authors
                    identity?.year = peer.year
                    identity?.journal = peer.journal
                }
            }
            let sourceFile = LiteratureAnnotationReader.sourceURL(for: sourceURL)
            let sourceVersion = try LiteratureAnnotationReader.version(of: sourceFile)
            let snapshot: LiteratureAttachmentSnapshot
            if let accepted = acceptedSources[recordID], accepted.version == sourceVersion,
               let previous = record.baseline?.snapshot {
                snapshot = previous
            } else {
                snapshot = try await readAnnotations(sourceURL, record.id)
            }
            var noteURL = URL(fileURLWithPath: record.notePath)
            let directory = URL(fileURLWithPath: notesDirectory, isDirectory: true)
            let matched = try await Task.detached {
                if let identity = record.zotero {
                    return try LiteratureNoteIndex.matchingPage(in: directory, itemLink: identity.itemLink)
                }
                return try LiteratureNoteIndex.matchingPage(in: directory, documentID: record.id)
            }.value
            if let matched {
                noteURL = matched
            } else if record.baseline != nil {
                throw LiteratureFileError.noteMissing
            } else if FileManager.default.fileExists(atPath: noteURL.path) {
                throw LiteratureFileError.noteChanged
            }
            let initial: String
            if let pageIdentity = identity {
                initial = LiteratureNoteIndex.newPage(for: pageIdentity)
            }
            else { initial = "# \(record.title.replacingOccurrences(of: "\n", with: " "))\n" }
            let metadataKey = identity.map(LiteratureMetadataCodec.key)
            let metadataBaseline = metadataKey.flatMap { metadataBaselines[$0] }
            let noteVersion = try LiteratureAnnotationReader.version(of: noteURL)
            attemptedSignature = Signature(source: sourceVersion, note: noteVersion)
            let prepared = try await files.prepare(url: noteURL, initial: initial, snapshot: snapshot, baseline: record.baseline,
                                                   metadata: identity, metadataBaseline: metadataBaseline,
                                                   initializeProperties: record.propertiesInitialized != true, filename: sourceURL.deletingPathExtension().lastPathComponent,
                                                   migratePageStyle: record.pageStyleVersion != 4, previousMetadata: record.zotero, attachIdentity: attachIdentity)
            guard enabled, let current = self.record(id: recordID), !current.paused,
                  current.notePath == record.notePath, current.baseline == record.baseline,
                  metadataKey.flatMap({ metadataBaselines[$0] }) == metadataBaseline,
                  ZoteroOneWriterGuard.isSafe(notesDirectory: URL(fileURLWithPath: notesDirectory)) else {
                throw LiteratureReadError.changed
            }
            guard try LiteratureAnnotationReader.version(of: sourceFile) == sourceVersion else { throw LiteratureReadError.changed }
            let backup = try await files.commit(prepared, firstTakeover: record.baseline == nil || record.pageStyleVersion != 4 || attachIdentity)
            guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
            let previousRecords = records
            let previousMetadata = metadataBaselines
            if attachIdentity { records[index].zotero = identity }
            records[index].baseline = prepared.merge.baseline
            for i in records.indices where records[i].notePath == record.notePath {
                records[i].propertiesInitialized = true
                records[i].pageStyleVersion = 4
            }
            records[index].notePath = noteURL.path
            if let backup { records[index].backupPath = backup.path }
            if let metadataKey, let rendered = prepared.metadataRendered, let identity {
                metadataBaselines[metadataKey] = rendered
                for i in records.indices where records[i].zotero.map(LiteratureMetadataCodec.key) == metadataKey {
                    records[i].zotero?.title = identity.title
                    records[i].zotero?.authors = identity.authors
                    records[i].zotero?.year = identity.year
                    records[i].zotero?.journal = identity.journal
                    records[i].title = URL(fileURLWithPath: records[i].documentPath).deletingPathExtension().lastPathComponent
                }
            }
            do { try persist() } catch { records = previousRecords; metadataBaselines = previousMetadata; throw error }
            acceptedSources[recordID] = AcceptedSource(version: sourceVersion)
            // A source edit during the note write must trigger another pass.
            lastSignatures[recordID] = Signature(source: sourceVersion,
                note: try LiteratureAnnotationReader.version(of: noteURL))
            blockedByUserEdit.remove(recordID)
            setStatus(path, associationAmbiguous ? "已同步笔记；Zotero 匹配不唯一，暂未关联" : (associationConflict ? "已同步笔记；发现已有 Zotero 文献页，待处理关联" : (identity == nil ? "已同步到 Obsidian，等待 Zotero 关联" : (usingCachedMetadata ? "已同步到 Obsidian（使用已知题录）" : "已同步到 Obsidian"))))
        } catch {
            if error is LiteratureNoteError, let attemptedSignature {
                blockedByUserEdit.insert(recordID)
                lastSignatures[recordID] = attemptedSignature
            }
            setStatus(path, error.localizedDescription)
        }
    }

    func syncNow(recordID: String) async {
        if let identity = record(id: recordID)?.zotero { metadataChecked.removeValue(forKey: LiteratureMetadataCodec.key(identity)) }
        else { offlineChecked.removeValue(forKey: recordID) }
        await sync(recordID: recordID)
    }

    func setPaused(_ paused: Bool, recordID: String) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let old = records[index].paused
        records[index].paused = paused
        do {
            try persist()
            lastSignatures.removeValue(forKey: recordID)
            if paused {
                let path = records[index].documentPath
                pendingChanges[path]?.cancel()
                pendingChanges.removeValue(forKey: path)
            }
            error = nil
        }
        catch { records[index].paused = old; self.error = error.localizedDescription }
    }

    func setDocumentSync(_ enabled: Bool, documentURL: URL) async {
        if let record = record(for: documentURL.path) {
            setPaused(!enabled, recordID: record.id)
            if enabled, self.enabled, self.record(id: record.id)?.paused == false {
                await syncNow(recordID: record.id)
            }
        } else if enabled {
            await adoptAndSync(documentURL: documentURL)
        }
    }

    func openNote(for path: String) {
        guard let record = record(for: path), FileManager.default.fileExists(atPath: record.notePath) else {
            error = "该文献尚未生成笔记。"
            return
        }
        let note = URL(fileURLWithPath: record.notePath).standardizedFileURL
        var directory = note.deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".obsidian").path),
               note.path.hasPrefix(directory.path + "/") {
                let relative = String(note.path.dropFirst(directory.path.count + 1))
                var components = URLComponents()
                components.scheme = "obsidian"
                components.host = "open"
                components.queryItems = [URLQueryItem(name: "vault", value: directory.lastPathComponent),
                                         URLQueryItem(name: "file", value: relative)]
                if let url = components.url, NSWorkspace.shared.open(url) { return }
                break
            }
            directory.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(note)
    }

    private func setStatus(_ path: String, _ value: String) {
        if statuses[path] != value { statuses[path] = value }
    }
}

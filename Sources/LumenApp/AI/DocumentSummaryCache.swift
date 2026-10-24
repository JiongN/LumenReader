import Foundation
import LumenKit

actor DocumentSummaryCache {
    static let shared = DocumentSummaryCache()
    private var memory: [String: String] = [:]
    private let maximumMemoryBytes = 2_000_000
    private var lastEmbeddingPrune = Date.distantPast

    private func directory(for key: String) -> URL {
        let root = key.hasPrefix("embedding-1:") ? AppPaths.cacheRoot : AppPaths.supportRoot
        return root.appendingPathComponent(key.hasPrefix("embedding-1:") ? "document-embeddings" : "document-analysis", isDirectory: true)
    }

    private func pruneEmbeddingsIfNeeded(in directory: URL) {
        guard Date().timeIntervalSince(lastEmbeddingPrune) >= 86_400 else { return }
        lastEmbeddingPrune = Date()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        RegenerableCachePolicy.prune(files: files.filter { $0.pathExtension == "json" },
            maximumBytes: 128_000_000, maximumAge: 180 * 86_400)
    }

    func value(for key: String) -> String? {
        let hash = AppPaths.stableHash(key)
        if let value = memory[hash] { return value }
        let targetDirectory = directory(for: key)
        if key.hasPrefix("embedding-1:") { pruneEmbeddingsIfNeeded(in: targetDirectory) }
        let file = targetDirectory.appendingPathComponent(hash + ".json")
        let legacy = AppPaths.cacheRoot.appendingPathComponent("ai-summaries").appendingPathComponent(hash + ".json")
        guard let data = try? Data(contentsOf: FileManager.default.fileExists(atPath: file.path) ? file : legacy) else { return nil }
        guard let value = try? JSONDecoder().decode(String.self, from: data) else {
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("corrupt-" + UUID().uuidString))
            return nil
        }
        return value
    }

    func store(_ value: String, key: String) {
        let hash = AppPaths.stableHash(key)
        if memory.count >= 32 || memory.values.reduce(0, { $0 + $1.utf8.count }) + value.utf8.count > maximumMemoryBytes {
            memory.removeAll(keepingCapacity: true)
        }
        if value.utf8.count <= maximumMemoryBytes { memory[hash] = value }
        let dir = directory(for: key)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if key.hasPrefix("embedding-1:") { pruneEmbeddingsIfNeeded(in: dir) }
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: dir.appendingPathComponent(hash + ".json"), options: .atomic)
        }
    }
}

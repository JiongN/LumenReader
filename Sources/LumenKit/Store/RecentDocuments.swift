import Foundation
import Combine
import UniformTypeIdentifiers

public enum DocumentKind: String, Codable, Sendable {
    case pdf
    case epub

    public var displayName: String {
        switch self {
        case .pdf:  return "PDF"
        case .epub: return "EPUB"
        }
    }

    /// 支持的文件扩展名（含 UPDF 常见的 .epub3 变体）
    public static let supportedExtensions: Set<String> = ["pdf", "epub", "epub3"]

    public static func from(url: URL) -> DocumentKind? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":              return .pdf
        case "epub", "epub3":    return .epub
        default:                 return nil
        }
    }

    /// 打开面板与拖放用的 UTI 白名单。EPUB 的 UTI 由系统按扩展名推导。
    public static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.pdf]
        if let epub = UTType(filenameExtension: "epub") {
            types.append(epub)
        }
        return types
    }
}

/// 最近打开记录 —— 注意这不是「书库」：只存路径和进度，不扫描、不索引、不管理文件。
public struct RecentEntry: Codable, Sendable, Identifiable, Equatable {
    public var path: String
    public var displayName: String
    public var kind: DocumentKind
    public var lastOpened: Date
    /// 0…1 的阅读进度快照（仅用于界面展示）
    public var progress: Double

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, displayName: String, kind: DocumentKind, lastOpened: Date = Date(), progress: Double = 0) {
        self.path = path
        self.displayName = displayName
        self.kind = kind
        self.lastOpened = lastOpened
        self.progress = progress
    }

    /// 文件是否还在原位置。
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

@MainActor
public final class RecentDocuments: ObservableObject {

    @Published public private(set) var entries: [RecentEntry] = []

    private let fileURL: URL
    private let limit = 24

    public init(fileURL: URL = AppPaths.recentFile) {
        self.fileURL = fileURL
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([RecentEntry].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func record(url: URL, kind: DocumentKind, progress: Double = 0) {
        let standardized = url.standardizedFileURL.path
        let name = url.deletingPathExtension().lastPathComponent
        var list = entries.filter { $0.path != standardized }
        list.insert(RecentEntry(path: standardized, displayName: name, kind: kind, progress: progress), at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        entries = list
        persist()
    }

    public func updateProgress(path: String, progress: Double) {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        entries[index].progress = progress
        persist()
    }

    public func remove(_ entry: RecentEntry) {
        entries.removeAll { $0.path == entry.path }
        persist()
    }

    public func clear() {
        entries = []
        persist()
    }
}

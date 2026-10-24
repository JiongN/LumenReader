import Foundation

/// Only callers' explicitly regenerable files may be passed here, never user records.
public enum RegenerableCachePolicy {
    @discardableResult
    public static func prune(files: [URL], maximumBytes: Int, maximumAge: TimeInterval,
                             keeping: Set<URL> = [], now: Date = Date()) -> Int {
        let fm = FileManager.default
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }, removed = 0
        for (file, size, date) in entries where !keeping.contains(file) {
            if now.timeIntervalSince(date) > maximumAge || total > maximumBytes {
                if (try? fm.removeItem(at: file)) != nil { total -= size; removed += size }
            }
        }
        return removed
    }
}

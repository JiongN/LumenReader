import Foundation

/// Extracts custom properties from the generated reading stylesheet without altering their names.
public enum CSSCustomProperties {
    public static func parse(_ css: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in css.split(separator: "\n") {
            let declaration = line.trimmingCharacters(in: .whitespaces)
            guard declaration.hasPrefix("--"), declaration.hasSuffix(";"),
                  let separator = declaration.firstIndex(of: ":") else { continue }
            let key = declaration[..<separator].trimmingCharacters(in: .whitespaces)
            let value = declaration[declaration.index(after: separator)..<declaration.index(before: declaration.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }
}

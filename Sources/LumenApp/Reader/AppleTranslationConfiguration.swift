import Foundation
import Translation

enum AppleTranslationConfiguration {
    static func next(_ current: TranslationSession.Configuration?, source: String, target: String) -> TranslationSession.Configuration {
        let source = Locale.Language(identifier: source)
        let language = Locale.Language(identifier: target)
        if var current, current.source == source, current.target == language {
            // Keep the previous version; recreating then invalidating always produces version 1.
            current.invalidate()
            return current
        }
        return TranslationSession.Configuration(source: source, target: language)
    }
}

import AppKit
import PDFKit

/// macOS 26 PDFKit starts Vision document recognition from visiblePagesChanged,
/// even for PDFs with a text layer. It competes with scrolling and can accumulate
/// work for pages the reader has already left. Lumen exposes its own explicit OCR.
///
/// PDFKit currently has no public opt-out. This narrowly scoped compatibility
/// workaround uses a runtime-checked selector, before assigning a document. It
/// must be revalidated on OS upgrades and replaced when a public API is available.
@MainActor
enum PDFBackgroundAnalysisPolicy {
    static func apply(to view: PDFView) {
        guard #available(macOS 26.0, *) else { return }
        let setter = NSSelectorFromString("setDocumentAnalysisEnabled:")
        guard view.responds(to: setter), let implementation = view.method(for: setter) else {
            NSLog("%@", "[Lumen][pdf] Background analysis opt-out unavailable on this OS")
            return
        }
        let enabled = LaunchOptions.flag("--pdf-document-analysis")
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Setter.self)(view, setter, enabled)
        NSLog("%@", "[Lumen][pdf] Automatic document analysis: \(enabled ? "enabled (diagnostic)" : "disabled; manual OCR remains available")")
    }
}

import AppKit
import CoreImage

/// Maps black/white to the selected ink/paper without modifying the PDF document.
/// Core Animation applies this to the public PDF documentView; controls remain unfiltered.
enum PDFReadingAppearance {
    static func filter(theme: ReadingTheme) -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        let ink = NSColor(hex: theme.textHex).usingColorSpace(.sRGB)!
        let paper = NSColor(hex: theme.backgroundHex).usingColorSpace(.sRGB)!
        filter.setValue(CIVector(x: paper.redComponent - ink.redComponent, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: paper.greenComponent - ink.greenComponent, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: paper.blueComponent - ink.blueComponent, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: ink.redComponent, y: ink.greenComponent, z: ink.blueComponent, w: 0), forKey: "inputBiasVector")
        return filter
    }
}

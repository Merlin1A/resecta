#if !canImport(UIKit)
import AppKit
import CoreGraphics
import Foundation

// macOS TOOLING SHIMS — compiled ONLY on the macOS tooling destination
// (this whole file is inert on iOS, where the real UIKit symbols are used).
// They exist so the fixture builders' UIKit drawing code compiles and behaves
// identically under plain `swift test` on a Mac host: top-left (flipped)
// drawing coordinates, AppKit-backed string drawing, and CGPDFContext-backed
// PDF rendering matching UIGraphicsPDFRenderer's page model.

typealias UIColor = NSColor
typealias UIFont = NSFont
typealias UIBezierPath = NSBezierPath

/// `os_proc_available_memory()` is iOS-only. The tests use it either as an
/// informational delta (stress logs) or as a "enough headroom to bother
/// asserting" gate — a stable large reading keeps the gates open and the
/// deltas at zero on the Mac host.
func os_proc_available_memory() -> Int {
    Int(ProcessInfo.processInfo.physicalMemory / 4)
}

// MARK: - UIImage

/// Minimal UIImage stand-in over a CGImage (1 pt == 1 px, scale 1).
final class UIImage {
    let cgImage: CGImage?

    init(cgImage: CGImage) {
        self.cgImage = cgImage
    }

    init?(data: Data) {
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else {
            return nil
        }
        self.cgImage = cg
    }

    var size: CGSize {
        guard let cgImage else { return .zero }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }

    func pngData() -> Data? {
        guard let cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// Draw into the current (flipped) context, matching UIKit's
    /// top-left-origin `draw(in:)` semantics.
    func draw(in rect: CGRect) {
        guard let cgImage, let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }
        ctx.saveGState()
        // Un-flip vertically about the rect's own center so the image lands
        // upright in the flipped coordinate space.
        ctx.translateBy(x: 0, y: rect.origin.y * 2 + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: rect)
        ctx.restoreGState()
    }
}

// MARK: - UIGraphicsPDFRenderer

final class UIGraphicsPDFRendererFormat {
    var documentInfo: [String: Any] = [:]
    init() {}
}

final class UIGraphicsPDFRendererContext {
    let cgContext: CGContext
    private let defaultBounds: CGRect
    private var pageOpen = false

    fileprivate init(cgContext: CGContext, bounds: CGRect) {
        self.cgContext = cgContext
        self.defaultBounds = bounds
    }

    func beginPage() {
        beginPage(withBounds: defaultBounds, pageInfo: [:])
    }

    func beginPage(withBounds bounds: CGRect, pageInfo: [String: Any]) {
        if pageOpen { cgContext.endPDFPage() }
        cgContext.beginPDFPage([
            kCGPDFContextMediaBox: NSValue(rect: bounds)
        ] as CFDictionary)
        pageOpen = true
        // Match UIKit's top-left-origin page coordinates.
        cgContext.translateBy(x: 0, y: bounds.height)
        cgContext.scaleBy(x: 1, y: -1)
        // Route AppKit string/path drawing (NSString.draw, NSColor.setFill,
        // NSBezierPath.fill) into this page's context.
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: cgContext, flipped: true
        )
    }

    func fill(_ rect: CGRect) {
        cgContext.fill(rect)
    }

    fileprivate func finishPageIfOpen() {
        if pageOpen { cgContext.endPDFPage() }
        pageOpen = false
    }
}

final class UIGraphicsPDFRenderer {
    private let bounds: CGRect

    init(bounds: CGRect) {
        self.bounds = bounds
    }

    convenience init(bounds: CGRect, format: UIGraphicsPDFRendererFormat) {
        self.init(bounds: bounds)
    }

    func writePDF(
        to url: URL, withActions actions: (UIGraphicsPDFRendererContext) -> Void
    ) throws {
        try pdfData(actions: actions).write(to: url)
    }

    func pdfData(actions: (UIGraphicsPDFRendererContext) -> Void) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            return Data()
        }
        var mediaBox = bounds
        guard let cg = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        let previous = NSGraphicsContext.current
        let context = UIGraphicsPDFRendererContext(cgContext: cg, bounds: bounds)
        actions(context)
        context.finishPageIfOpen()
        cg.closePDF()
        NSGraphicsContext.current = previous
        return data as Data
    }
}

// MARK: - UIGraphicsImageRenderer

final class UIGraphicsImageRendererContext {
    let cgContext: CGContext

    fileprivate init(cgContext: CGContext) {
        self.cgContext = cgContext
    }

    func fill(_ rect: CGRect) {
        cgContext.fill(rect)
    }
}

final class UIGraphicsImageRenderer {
    private let size: CGSize

    init(size: CGSize) {
        self.size = size
    }

    func image(actions: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let width = max(Int(size.width.rounded(.up)), 1)
        let height = max(Int(size.height.rounded(.up)), 1)
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let cg = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            preconditionFailure("bitmap context creation failed")
        }
        // Match UIKit's top-left-origin drawing coordinates.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        actions(UIGraphicsImageRendererContext(cgContext: cg))
        NSGraphicsContext.current = previous
        guard let made = cg.makeImage() else {
            preconditionFailure("makeImage failed")
        }
        return UIImage(cgImage: made)
    }
}
#endif

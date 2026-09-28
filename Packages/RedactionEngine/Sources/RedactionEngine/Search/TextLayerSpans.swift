import CoreGraphics
import Foundation
import PDFKit

// The word-span primitive: the words of a page's text layer whose boxes lie
// fully inside a region, in reading order, with their boxes in the frame
// every region and search result uses. The verification run captures the
// words under each manual region through it; a text selection that snaps
// to words on the canvas wraps it. Pure: it reads the page once and keeps
// nothing. Text-layer words only — no OCR.

/// One word of a page's text layer: its text and its box in the
/// page-normalized displayed frame (0–1, bottom-left origin; rotation
/// applied; the frame `RedactionRegion.normalizedRect` and
/// `DocumentSearcher.boundingRect(for:page:)` share).
public struct TextSpan: Sendable, Equatable {
    public let text: String
    public let normalizedRect: CGRect

    init(text: String, normalizedRect: CGRect) {
        self.text = text
        self.normalizedRect = normalizedRect
    }
}

public enum TextLayerSpans {

    /// The tolerance on the region's edges, in PDF points: a word whose box
    /// touches the region's edge from inside by less than this is inside.
    /// Deliberately narrower than the burn-in's safety margin — the margin
    /// widens what is removed; this decides what is claimed as removed.
    static let edgeTolerancePoints: CGFloat = 0.5

    /// The words fully inside `rect` (page-normalized, displayed frame) on
    /// `page`, in reading order. With `polygon` (normalized vertices of the
    /// region; `rect` is its bounding box) a word also needs its centre
    /// inside the polygon. A page without a text layer yields nothing.
    ///
    /// Word boxes come from PDFKit's selection API through
    /// `EmbeddedTextSource.make(from:)`, which lands them in the displayed
    /// frame the burn-in consumes; the tolerance converts to that frame by
    /// the page's displayed size. A whole-page region is the caller's rule
    /// to skip, not this primitive's.
    public static func words(
        fullyInside rect: CGRect, polygon: [CGPoint]? = nil, on page: PDFPage
    ) -> [TextSpan] {
        guard rect.width > 0, rect.height > 0,
              let source = EmbeddedTextSource.make(from: page),
              let pageText = page.string else { return [] }
        let size = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        guard size.width > 0, size.height > 0 else { return [] }
        let halo = rect.insetBy(dx: -edgeTolerancePoints / size.width,
                                dy: -edgeTolerancePoints / size.height)
        let text = pageText as NSString
        var spans: [TextSpan] = []
        for word in source.wordBounds {
            let box = word.normalizedRect
            guard halo.contains(box), NSMaxRange(word.range) <= text.length else { continue }
            if let polygon, polygon.count >= 3,
               !pointInPolygon(CGPoint(x: box.midX, y: box.midY), vertices: polygon) {
                continue
            }
            spans.append(TextSpan(text: text.substring(with: word.range), normalizedRect: box))
        }
        return spans
    }
}

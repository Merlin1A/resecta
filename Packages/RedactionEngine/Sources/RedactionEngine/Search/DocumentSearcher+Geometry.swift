import Foundation
import PDFKit

// The geometry every search path shares: the NSRange → normalized-rect conversion
// (SECURITY: a wrong normalization is a fill at the wrong pixel position), the OCR
// thumbnail size, the OCR line union with its padding and the page-level OCR
// confidence. Moved whole from DocumentSearcher.swift; no line inside a moved body changes.

extension DocumentSearcher {

    /// Run PII detection on a page via OCR when no text layer is available.
    /// Concatenates OCR lines into a single text block, runs PIIDetector,
    /// then maps match ranges back to OCR line bounding boxes.
    /// OCR render size for `page.thumbnail(of:for:.cropBox)`.
    ///
    /// Uses the page's DISPLAYED (effective, rotation-
    /// swapped) dimensions. `thumbnail(of:for:.cropBox)` renders the rotation-
    /// applied page and aspect-fits it into the requested size; an unrotated-dims
    /// request on a /Rotate 90/270 page has the transposed aspect, so PDFKit
    /// letterboxes the render and every Vision `normalizedRect` is shifted off
    /// displayed space — the derived redaction region then misses the text. The
    /// W↔H swap leaves the pixel budget (`maxOCRPixelDimension` /
    /// `maxOCRPixelCount`) unchanged, so each call site's memory guard is
    /// unaffected. Mirrors the effective-dims normalization in
    /// `boundingRect(for:page:)`.
    static func ocrThumbnailSize(pageBounds: CGRect, rotation: Int) -> CGSize {
        let scale: CGFloat = 300.0 / 72.0  // 72 DPI → 300 DPI
        let effective = effectiveBounds(pageBounds, rotation: rotation).size
        return CGSize(width: effective.width * scale, height: effective.height * scale)
    }

    // MARK: - The OCR line union

    /// The recognised lines a match overlaps, with their padded union rect.
    /// `range` is a UTF-16 range on the line-feed-joined normalized text
    /// (the Scan leg's offsets and the regex leg's are both UTF-16; each
    /// line is followed by one line feed), and a line overlaps when its span
    /// meets the range. One home for both legs: a match that runs across two
    /// recognised lines is boxed on every line it touches, never on the line
    /// where it began alone. nil when no line overlaps.
    nonisolated func ocrUnionRect(
        forUTF16Range range: NSRange,
        lineOffsets: [OCRPageCache.NormalizedLineEntry],
        page: PDFPage
    ) -> (rect: CGRect, lines: [OCRPageCache.NormalizedLineEntry])? {
        let matchStart = range.location
        let matchEnd = matchStart + range.length
        let overlapping = lineOffsets.filter { entry in
            let lineEnd = entry.start + entry.normalizedText.utf16.count + 1
            return entry.start < matchEnd && lineEnd > matchStart
        }
        guard let first = overlapping.first else { return nil }
        let union = overlapping.dropFirst().reduce(first.normalizedRect) { $0.union($1.normalizedRect) }
        return (Self.paddedNormalizedRect(union, in: page), overlapping)
    }

    /// A Vision line rect (normalized 0–1, bottom-left origin) padded by
    /// 2 pt in normalized coordinates for OCR imprecision and clamped to
    /// the unit square — the one padding arithmetic for every OCR result
    /// rect (the PII scan's union rect, the literal OCR search's line rect
    /// and the regex fallback's line rect).
    nonisolated static func paddedNormalizedRect(_ rect: CGRect, in page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .cropBox)
        let padX = 2.0 / pageBounds.width
        let padY = 2.0 / pageBounds.height
        return CGRect(
            x: max(0, rect.minX - padX),
            y: max(0, rect.minY - padY),
            width: min(1, rect.width + padX * 2),
            height: min(1, rect.height + padY * 2)
        )
    }

    /// Average OCR confidence across a set of lines. Returns 0 for an empty
    /// slice (caller should guard non-empty before using the result).
    func averageOCRConfidence(_ lines: [OCREngine.TextLine]) -> Float {
        lines.map(\.confidence).reduce(0, +) / Float(max(lines.count, 1))
    }

    // MARK: - Coordinate Conversion

    /// Convert an NSRange in page text to a normalized bounding rect.
    ///
    /// Coordinate path:
    /// PDFPage.selection(for:) → .bounds(for: page) → PDF points (bottom-left,
    /// UN-ROTATED space). Transform to post-rotation visual
    /// space before normalizing, so normalized coords align with the post-rotation
    /// bitmap produced by renderPage()/getDrawingTransform().
    ///
    /// SECURITY NOTE: Wrong normalization = fill at wrong pixel position = data leak.
    /// On a page whose text lies over a page-scale image the box is the ink
    /// under it alone (`inkFittedRect`, paint only), the box Apply paints; the
    /// hidden glyphs' own box rides on the result (`textLayerAndInkRects`).
    public nonisolated func boundingRect(for nsRange: NSRange, page: PDFPage) -> CGRect? {
        guard let selection = page.selection(for: nsRange) else { return nil }
        return normalizedRect(for: selection, page: page).map {
            Self.inkFittedRect($0, page: page, text: selection.string, range: nsRange, paintOnly: true)
        }
    }

    /// One normalized rect per line of the range's selection
    /// (`PDFSelection.selectionsByLine()`), each through the one rotation
    /// home below: a match that wraps onto a second line gets a box on each
    /// line, never one union across the gap. nil when no line has a rect
    /// (the same refusal as `boundingRect`).
    nonisolated func lineRects(for nsRange: NSRange, page: PDFPage) -> [CGRect]? {
        guard let selection = page.selection(for: nsRange) else { return nil }
        let lines = selection.selectionsByLine()
        let rects = lines.compactMap { line in
            normalizedRect(for: line, page: page).map {
                Self.inkFittedRect($0, page: page, text: line.string,
                                   range: lines.count == 1 ? nsRange : line.range(at: 0, on: page), paintOnly: true)
            }
        }
        return rects.isEmpty ? nil : rects
    }

    /// On a page whose glyphs are inkless over a page-scale image, each line of
    /// the match as two rects, index-aligned: `paint`, the word's ink (what the
    /// fill covers), and `strip`, the selection box of the line's hidden glyphs
    /// (what a Searchable export removes from the text layer); `degraded` when
    /// some line's fit fell back to the drift envelope (the caller reports the
    /// page as not fully analysed). Nil on any other page: the line rects are
    /// `lineRects`' as they are.
    nonisolated func textLayerAndInkRects(for nsRange: NSRange, page: PDFPage)
        -> (paint: [CGRect], strip: [CGRect], degraded: Bool)? {
        guard let cgPage = page.pageRef, Self.carriesHiddenTextOverImage(page, cgPage: cgPage),
              let selection = page.selection(for: nsRange) else { return nil }
        let lines = selection.selectionsByLine()
        var paint: [CGRect] = [], strip: [CGRect] = [], degraded = false
        for line in lines {
            guard let raw = normalizedRect(for: line, page: page) else { continue }
            let fit = Self.inkFit(raw, page: page, text: line.string,
                                  range: lines.count == 1 ? nsRange : line.range(at: 0, on: page), paintOnly: true)
            strip.append(raw)
            paint.append(fit.rect)
            degraded = degraded || fit.degraded
        }
        return paint.isEmpty ? nil : (paint, strip, degraded)
    }

    /// The one home for the selection → normalized-rect transform: the
    /// crop-box translate, the /Rotate mirror, the normalize and the clamp.
    /// A per-line selection's `bounds(for:)` is absolute like its parent's,
    /// so every rect takes this path (SECURITY: a rect built any other way
    /// is a fill at the wrong pixel position).
    nonisolated func normalizedRect(for selection: PDFSelection, page: PDFPage) -> CGRect? {
        let absoluteBounds = selection.bounds(for: page)
        guard !absoluteBounds.isEmpty else { return nil }

        let pageBounds = page.bounds(for: .cropBox)
        let rawW = pageBounds.width
        let rawH = pageBounds.height
        let rotation = page.rotation

        // PDFSelection.bounds(for:) is in ABSOLUTE, UNROTATED (MediaBox/user)
        // space and INCLUDES the cropBox origin (pinned by RotatedPageCoordinateTests
        // .nonZeroCropBoxSelectionFrameProbe). Translate to cropBox-LOCAL BEFORE the
        // rotation mirror — the rotation cases and the normalize below assume a
        // zero-origin local rect (they use rawW/rawH as extents only). This mirrors
        // TextLayerExtractor's `.offsetBy(dx:-cropBox.origin.x, dy:-cropBox.origin.y)`
        // so both region producers agree on offset-CropBox pages. SECURITY: omitting
        // this displaces the redaction fill by (origin / dimension).
        let bounds = absoluteBounds.offsetBy(
            dx: -pageBounds.origin.x, dy: -pageBounds.origin.y)

        // Transform selection bounds from un-rotated PDF space to post-rotation
        // visual space. PDF /Rotate is CW display rotation (ISO 32000 §8.3.2).
        let visualBounds: CGRect
        switch rotation {
        case 90:
            // CW 90°: (x,y) → (y, rawW - x - w)
            visualBounds = CGRect(
                x: bounds.minY, y: rawW - bounds.maxX,
                width: bounds.height, height: bounds.width)
        case 180:
            // 180°: (x,y) → (rawW - x - w, rawH - y - h)
            visualBounds = CGRect(
                x: rawW - bounds.maxX, y: rawH - bounds.maxY,
                width: bounds.width, height: bounds.height)
        case 270:
            // CCW 90°: (x,y) → (rawH - y - h, x)
            visualBounds = CGRect(
                x: rawH - bounds.maxY, y: bounds.minX,
                width: bounds.height, height: bounds.width)
        default:
            visualBounds = bounds
        }

        // Post-rotation effective dimensions
        let effectiveWidth: CGFloat = (rotation == 90 || rotation == 270) ? rawH : rawW
        let effectiveHeight: CGFloat = (rotation == 90 || rotation == 270) ? rawW : rawH

        guard effectiveWidth > 0, effectiveHeight > 0 else { return nil }

        let normalized = CGRect(
            x: visualBounds.minX / effectiveWidth,
            y: visualBounds.minY / effectiveHeight,
            width: visualBounds.width / effectiveWidth,
            height: visualBounds.height / effectiveHeight
        ).clampedToNormalized()

        return normalized
    }
}

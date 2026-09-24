import Foundation
import PDFKit

// The geometry every search path shares: the NSRange → normalized-rect conversion
// (SECURITY: a wrong normalization is a fill at the wrong pixel position), the OCR
// thumbnail size, the OCR line-rect lookup with its padding and the page-level OCR
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

    // MARK: - Regex OCR Fallback Helpers

    /// Map a character offset in a newline-joined OCR text to the bounding
    /// rect of the containing OCR line. Used by the regex fallback to
    /// associate a regex match position with a visual location.
    ///
    /// - Parameters:
    ///   - offset: Character offset into `text` (the "\n"-joined concatenation
    ///             of `lines[i].text` values, same join order as the caller).
    ///   - text: The concatenated OCR text that was searched.
    ///   - lines: The source OCR lines in the same order used when building `text`.
    ///   - page: The page, used to compute padding in normalized coordinates.
    /// - Returns: The normalized bounding rect of the containing line, padded
    ///   for OCR imprecision, or `nil` if no line contains the offset.
    func ocrLineRect(
        forCharOffset offset: Int,
        inText text: String,
        lines: [OCREngine.TextLine],
        page: PDFPage
    ) -> CGRect? {
        // Walk lines in the same order they were joined with "\n".
        // Each line occupies `line.text.count` characters followed by a
        // "\n" separator (1 character), so the running total advances by
        // `lineLength + 1` per line.
        var cursor = 0
        for line in lines {
            let lineLength = line.text.count
            let lineEnd = cursor + lineLength  // exclusive, before the "\n"
            if offset >= cursor && offset <= lineEnd {
                return Self.paddedNormalizedRect(line.normalizedRect, in: page)
            }
            cursor += lineLength + 1  // +1 for the "\n"
        }
        return nil
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
    public nonisolated func boundingRect(for nsRange: NSRange, page: PDFPage) -> CGRect? {
        guard let selection = page.selection(for: nsRange) else { return nil }
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

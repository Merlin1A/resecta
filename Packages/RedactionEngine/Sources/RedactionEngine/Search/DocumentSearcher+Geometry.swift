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
    /// bitmap produced by renderPageFromCGPage()/getDrawingTransform().
    ///
    /// SECURITY NOTE: Wrong normalization = fill at wrong pixel position = data leak.
    /// On a page whose text lies over a page-scale image the box is the ink
    /// under it alone (`inkFittedRect`, paint only), the box Apply paints; the
    /// hidden glyphs' own box rides on the result (`textLayerAndInkRects`).
    public nonisolated func boundingRect(for nsRange: NSRange, page: PDFPage) -> CGRect? {
        boundingBox(for: nsRange, page: page)?.rect
    }

    /// `boundingRect` with the box the match is told by (`identity`): its box
    /// before the growth to its own glyphs, where the growth moved it; nil
    /// where `rect` is that box. A box grown for cover never widens it.
    nonisolated func boundingBox(for nsRange: NSRange, page: PDFPage) -> (rect: CGRect, identity: CGRect?)? {
        guard let selection = page.selection(for: nsRange) else { return nil }
        let own = Self.ownGlyphs(for: nsRange, page: page)
        return normalizedRect(for: selection, page: page).map {
            let fitted = Self.inkFittedRect($0, page: page, text: selection.string, range: nsRange, paintOnly: true)
            let rect = grown(fitted, line: selection.bounds(for: page), by: own, page: page)
            return (rect, rect == fitted ? nil : fitted)
        }
    }

    /// One normalized rect per line of the range's selection
    /// (`PDFSelection.selectionsByLine()`), each through the one rotation
    /// home below: a match that wraps onto a second line gets a box on each
    /// line, never one union across the gap. nil when no line has a rect
    /// (the same refusal as `boundingRect`).
    nonisolated func lineRects(for nsRange: NSRange, page: PDFPage) -> [CGRect]? {
        lineBoxes(for: nsRange, page: page)?.map(\.rect)
    }

    /// `lineRects`, each line with the box it is told by (`identity`): its box
    /// before the growth to the match's own glyphs, where the growth moved it;
    /// nil where `rect` is that box. A box grown for cover never widens it.
    nonisolated func lineBoxes(for nsRange: NSRange, page: PDFPage) -> [(rect: CGRect, identity: CGRect?)]? {
        guard let selection = page.selection(for: nsRange) else { return nil }
        let lines = selection.selectionsByLine()
        let own = Self.ownGlyphs(for: nsRange, page: page)
        let boxes = lines.compactMap { line -> (rect: CGRect, identity: CGRect?)? in
            normalizedRect(for: line, page: page).map {
                let fitted = Self.inkFittedRect($0, page: page, text: line.string,
                                                range: lines.count == 1 ? nsRange : line.range(at: 0, on: page), paintOnly: true)
                let rect = grown(fitted, line: line.bounds(for: page), by: own, page: page)
                return (rect, rect == fitted ? nil : fitted)
            }
        }
        return boxes.isEmpty ? nil : boxes
    }

    /// On a page whose glyphs are inkless over a page-scale image, each line of
    /// the match as two rects, index-aligned: `paint`, the word's ink (what the
    /// fill covers), and `strip`, the selection box of the line's hidden glyphs
    /// (what a Searchable export removes from the text layer); `degraded` when
    /// some line's fit fell back to the drift envelope (the caller reports the
    /// page as not fully analysed); `identity`, index-aligned, the box a line's
    /// tallest band alone paints where its paint took more (`InkFitJob.identity`),
    /// else the paint before the growth to the match's own glyphs where that
    /// growth moved it, nil where the paint is its own. Nil on any other page: the line rects
    /// are `lineRects`' as they are.
    nonisolated func textLayerAndInkRects(for nsRange: NSRange, page: PDFPage)
        -> (paint: [CGRect], strip: [CGRect], degraded: Bool, identity: [CGRect?])? {
        guard let cgPage = page.pageRef, Self.carriesHiddenTextOverImage(page, cgPage: cgPage),
              let selection = page.selection(for: nsRange) else { return nil }
        let lines = selection.selectionsByLine()
        let own = Self.ownGlyphs(for: nsRange, page: page)
        var paint: [CGRect] = [], strip: [CGRect] = [], degraded = false, identity: [CGRect?] = []
        for line in lines {
            guard let raw = normalizedRect(for: line, page: page) else { continue }
            let fit = Self.inkFit(raw, page: page, text: line.string,
                                  range: lines.count == 1 ? nsRange : line.range(at: 0, on: page), paintOnly: true)
            strip.append(raw)
            let box = grown(fit.rect, line: line.bounds(for: page), by: own, page: page)
            paint.append(box)
            identity.append(fit.identity ?? (box == fit.rect ? nil : fit.rect))
            degraded = degraded || fit.degraded
        }
        return paint.isEmpty ? nil : (paint, strip, degraded, identity)
    }

    /// The one home for the selection → normalized-rect transform: the
    /// crop-box translate, the /Rotate mirror, the normalize and the clamp.
    /// A per-line selection's `bounds(for:)` is absolute like its parent's,
    /// so every rect takes this path (SECURITY: a rect built any other way
    /// is a fill at the wrong pixel position).
    nonisolated func normalizedRect(for selection: PDFSelection, page: PDFPage) -> CGRect? {
        normalizedRect(forPageRect: selection.bounds(for: page), page: page)
    }

    /// The selection path's transform for any rect in the page's absolute,
    /// unrotated space (a selection's `bounds(for:)`, or a glyph's box from
    /// the page's own drawing). A rect with no overlap with the visible page
    /// before the clamp is no box (the clamp would move it onto the page's
    /// edge, over other print, or leave it with no area); a rect partly on
    /// the page is clamped.
    nonisolated func normalizedRect(forPageRect absoluteBounds: CGRect, page: PDFPage) -> CGRect? {
        guard let visual = visualBounds(forPageRect: absoluteBounds, page: page) else { return nil }
        let visiblePage = CGRect(x: 0, y: 0, width: visual.width, height: visual.height)
        let overlap = visual.bounds.intersection(visiblePage)
        guard !overlap.isNull, !overlap.isEmpty else { return nil }
        return Self.normalized(visual)
    }

    /// A paint box (normalized) grown sideways to the match's own drawn
    /// glyphs on this line (`ownGlyphs`): each glyph's box is first cut to
    /// the line's height (`line`, page space), so a box grows along its line
    /// and never into the next; a glyph that does not reach the line's height,
    /// or whose cut box is empty once normalized, adds nothing. An edge moves
    /// only to a glyph that lies past it by more than `growthSlack`; a box no
    /// edge of which moves is `rect` exactly. Never smaller than `rect`;
    /// `rect` itself when `glyphs` is nil.
    nonisolated func grown(_ rect: CGRect, line: CGRect, by glyphs: [OwnGlyph]?, page: PDFPage) -> CGRect {
        guard let glyphs else { return rect }
        let crop = page.bounds(for: .cropBox)
        let turned = page.rotation == 90 || page.rotation == 270
        let width = turned ? crop.height : crop.width, height = turned ? crop.width : crop.height
        guard width > 0, height > 0 else { return rect }
        let slackX = Self.growthSlack / width, slackY = Self.growthSlack / height
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var moved = false
        for glyph in glyphs {
            let low = max(glyph.box.minY, line.minY), high = min(glyph.box.maxY, line.maxY)
            guard high > low else { continue }
            let cut = CGRect(x: glyph.box.minX, y: low, width: glyph.box.width, height: high - low)
            guard let n = normalizedRect(forPageRect: cut, page: page), n.width > 0, n.height > 0 else { continue }
            if n.minX < minX - slackX { minX = n.minX; moved = true }
            if n.maxX > maxX + slackX { maxX = n.maxX; moved = true }
            if n.minY < minY - slackY { minY = n.minY; moved = true }
            if n.maxY > maxY + slackY { maxY = n.maxY; moved = true }
        }
        return moved ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : rect
    }

    /// How far, in points, a glyph from the page's drawing must lie past a
    /// box's edge before the edge moves. The walk's advances for a standard
    /// font come from the system font, which differ from the widths PDFKit
    /// places them by by about a thousandth of the size: well under this,
    /// which is a tenth of a pixel at 150 dpi and inside the paint's halo.
    static let growthSlack: CGFloat = 0.05


    /// The same transform with no visible-page test: a rect wholly off the
    /// visible page is clamped onto its edge, as every rect was before an
    /// off-page match was given no box. The ink fit measures with it (a
    /// line's first letter, a letter's layer box, the reading direction):
    /// there an off-page letter is a position to measure from, not a box to
    /// paint, and the clamped edge keeps the drift bound as wide as it was.
    nonisolated func clampedNormalizedRect(for selection: PDFSelection, page: PDFPage) -> CGRect? {
        visualBounds(for: selection, page: page).map(Self.normalized)
    }

    private nonisolated static func normalized(_ visual: (bounds: CGRect, width: CGFloat, height: CGFloat)) -> CGRect {
        CGRect(
            x: visual.bounds.minX / visual.width,
            y: visual.bounds.minY / visual.height,
            width: visual.bounds.width / visual.width,
            height: visual.bounds.height / visual.height
        ).clampedToNormalized()
    }

    /// Whether every line of the range lies wholly outside the visible page:
    /// the reason its match has no box, when that is the reason.
    nonisolated func liesOffVisiblePage(_ nsRange: NSRange, page: PDFPage) -> Bool {
        guard let selection = page.selection(for: nsRange) else { return false }
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard let visual = visualBounds(for: line, page: page) else { return false }
            let overlap = visual.bounds.intersection(
                CGRect(x: 0, y: 0, width: visual.width, height: visual.height))
            return overlap.isNull || overlap.isEmpty
        }
    }

    /// A selection's bounds in the page's visual space (crop-box local, after
    /// the /Rotate mirror), with the visual page's width and height.
    nonisolated func visualBounds(for selection: PDFSelection, page: PDFPage)
        -> (bounds: CGRect, width: CGFloat, height: CGFloat)? {
        visualBounds(forPageRect: selection.bounds(for: page), page: page)
    }

    /// A rect in the page's absolute, unrotated space, in the page's visual
    /// space, with the visual page's width and height.
    nonisolated func visualBounds(forPageRect absoluteBounds: CGRect, page: PDFPage)
        -> (bounds: CGRect, width: CGFloat, height: CGFloat)? {
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
        return (visualBounds, effectiveWidth, effectiveHeight)
    }
}

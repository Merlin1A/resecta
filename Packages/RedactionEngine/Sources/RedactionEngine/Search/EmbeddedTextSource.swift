import CoreGraphics
import Foundation
import PDFKit

// MARK: - Embedded text source

/// Sendable carrier for a page's embedded text layer: its text, per-word
/// boxes and per-line records, read from the PDF without Vision OCR.
///
/// The search path builds an instance from `PDFPage` (which is not
/// Sendable) via the static `make(from:cropBox:)` factory. Coordinates are
/// **normalized, bottom-left origin (0–1)**, as Vision's OCR output is. The rects
/// are in the zero-origin, rotation-applied DISPLAYED output-page frame
/// (`effectiveSize` basis, W/H swapped for /Rotate 90/270) — the same frame
/// `TextLayerExtractor.extractCharacters` produces and the burn-in consumes
/// (the canonical coordinate contract).
public struct EmbeddedTextSource: Sendable {
    /// Full extracted text for the page (newline-separated lines).
    public let text: String
    /// Per-word `(NSRange, normalized CGRect)` entries, in document order.
    /// Read by `TextLayerSpans` to place word-level spans.
    public let wordBounds: [WordBound]
    /// Per-line records used by `AddressSpatialAssembler`.
    public let lines: [OCREngine.TextLine]
    /// Selectable-text coverage as a fraction of cropBox area in [0, 1].
    /// Surfaced for tests; no production path reads it.
    public let coverage: Double

    public init(
        text: String,
        wordBounds: [WordBound],
        lines: [OCREngine.TextLine],
        coverage: Double
    ) {
        self.text = text
        self.wordBounds = wordBounds
        self.lines = lines
        self.coverage = coverage
    }

    /// `(NSRange, CGRect)` is not directly Sendable in Swift 6.2 strict mode,
    /// so we wrap the pair in a Sendable value type.
    public struct WordBound: Sendable {
        public let range: NSRange
        public let normalizedRect: CGRect

        public init(range: NSRange, normalizedRect: CGRect) {
            self.range = range
            self.normalizedRect = normalizedRect
        }
    }

    /// Build an `EmbeddedTextSource` from a PDF page. Iterates words via
    /// `NSString.enumerateSubstrings(options: .byWords)` and pulls each
    /// word's PDF-space bounding box via `PDFSelection.bounds(for:)`.
    ///
    /// Coverage is computed as the sum of word-box areas divided by cropBox
    /// area. On a typical text page words do not overlap, and letter-spacing
    /// whitespace is not counted. Returns `nil` if the page has no
    /// extractable text or has a zero-size cropBox.
    /// `fitLines`: box each line on its ink on a hidden layer over a page image
    /// (`DocumentSearcher.inkFittedRect`), for the callers that read `lines`'
    /// rects (the address assembly); the word bounds are never fitted.
    public static func make(from page: PDFPage, fitLines: Bool = false) -> EmbeddedTextSource? {
        let cropBox = page.bounds(for: .cropBox)
        return make(from: page, cropBox: cropBox, fitLines: fitLines)
    }

    /// Variant that takes a pre-computed cropBox (avoids redundant PDFKit
    /// trips in callers that already have it).
    public static func make(
        from page: PDFPage, cropBox: CGRect, fitLines: Bool = false
    ) -> EmbeddedTextSource? {
        let pageArea = cropBox.width * cropBox.height
        guard pageArea > 0,
              let text = page.string,
              !text.isEmpty else {
            return nil
        }

        // Canonical coordinate contract: /Rotate is a DISPLAY attribute and
        // `sel.bounds(for:)` is invariant under it, so word/line rects must be
        // mapped into the displayed output-page frame the burn-in consumes —
        // the same displayed-frame migration applied to `extractCharacters`.
        // `effectiveSize` is the rotated output-page size (W/H swapped for
        // 90/270); identity for 0/180.
        let normalizedRotation = ((page.rotation % 360) + 360) % 360
        let effectiveSize = (normalizedRotation == 90 || normalizedRotation == 270)
            ? CGSize(width: cropBox.height, height: cropBox.width)
            : cropBox.size

        let nsText = text as NSString
        let totalCodeUnits = page.numberOfCharacters

        var wordBounds: [WordBound] = []
        var lineBuckets: [(yMid: CGFloat, words: [(rect: CGRect, text: String)])] = []
        var areaSum: CGFloat = 0

        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: .byWords
        ) { _, wordRange, _, _ in
            // Defensive: PDFKit ranges are UTF-16; clip to numberOfCharacters.
            let clippedLength = min(
                wordRange.length,
                max(0, totalCodeUnits - wordRange.location)
            )
            guard clippedLength > 0,
                  wordRange.location >= 0,
                  wordRange.location < totalCodeUnits else { return }
            let safeRange = NSRange(
                location: wordRange.location, length: clippedLength
            )
            guard let sel = page.selection(for: safeRange) else { return }
            let bounds = sel.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return }

            areaSum += bounds.width * bounds.height
            // Land the word rect in the zero-origin displayed frame the
            // burn-in consumes (identity for an unrotated zero-origin page).
            let normalized = Self.displayedNormalizedRect(
                bounds, cropBox: cropBox,
                effectiveSize: effectiveSize, rotation: normalizedRotation
            )
            wordBounds.append(WordBound(
                range: safeRange, normalizedRect: normalized
            ))

            let yMid = bounds.midY
            let wordText = nsText.substring(with: safeRange)
            let lineTolerance = max(bounds.height * 0.5, 2.0)
            if let idx = lineBuckets.firstIndex(where: {
                abs($0.yMid - yMid) <= lineTolerance
            }) {
                lineBuckets[idx].words.append((bounds, wordText))
            } else {
                lineBuckets.append((yMid, [(bounds, wordText)]))
            }
        }

        let coverage = Double(areaSum / pageArea)

        // Build OCREngine.TextLine entries from line buckets. Each line is
        // the union of its words' rects (in normalized coords) plus the
        // concatenated text. Used by AddressSpatialAssembler.
        let lines: [OCREngine.TextLine] = lineBuckets
            .sorted { $0.yMid > $1.yMid }  // top-to-bottom in PDF (bottom-left origin)
            .map { bucket in
                let sortedWords = bucket.words.sorted { $0.rect.minX < $1.rect.minX }
                let lineText = sortedWords.map(\.text).joined(separator: " ")
                let unionRect = sortedWords
                    .map(\.rect)
                    .reduce(CGRect.null) { $0.union($1) }
                // Same displayed-space transform as the word path; the
                // line union feeds AddressSpatialAssembler via the same consumer.
                let normalized = unionRect == .null ? .zero
                    : Self.displayedNormalizedRect(
                        unionRect, cropBox: cropBox,
                        effectiveSize: effectiveSize, rotation: normalizedRotation
                    )
                // On a hidden layer over a page image the line is boxed on
                // its ink and its own box (until the strip rect carries the
                // layer's box apart); the layer's box rides beside it.
                let fit = !fitLines || normalized == .zero ? (rect: normalized, degraded: false)
                    : DocumentSearcher.inkFit(normalized, page: page, text: lineText)
                return OCREngine.TextLine(
                    text: lineText,
                    normalizedRect: fit.rect,
                    confidence: 1.0,
                    textLayerRect: fit.rect == normalized ? nil : normalized,
                    inkFitDegraded: fit.degraded
                )
            }

        return EmbeddedTextSource(
            text: text,
            wordBounds: wordBounds,
            lines: lines,
            coverage: coverage
        )
    }

    /// Land a source-absolute `sel.bounds(for:)` rect in the zero-origin,
    /// rotation-applied DISPLAYED output-page frame and normalize to 0–1 by
    /// `effectiveSize` (the canonical coordinate contract). Mirrors the per-glyph transform in
    /// `TextLayerExtractor.extractCharacters`: localize (subtract the cropBox
    /// origin) → rotate into displayed space (`T_rot`, reusing
    /// the canonical four-case map) → normalize by the rotated output size. For
    /// an unrotated zero-origin page the result is identical to the prior
    /// origin-subtract-and-normalize. The `effectiveSize` dims are non-zero (the
    /// caller's `pageArea > 0` guard), so the denominators are non-zero.
    private static func displayedNormalizedRect(
        _ sourceRect: CGRect,
        cropBox: CGRect,
        effectiveSize: CGSize,
        rotation: Int
    ) -> CGRect {
        let local = sourceRect.offsetBy(dx: -cropBox.minX, dy: -cropBox.minY)
        let displayed = TextLayerExtractor.rotateRectIntoOutputSpace(
            local, sourceCropSize: cropBox.size, rotation: rotation
        )
        return CGRect(
            x: displayed.minX / effectiveSize.width,
            y: displayed.minY / effectiveSize.height,
            width: displayed.width / effectiveSize.width,
            height: displayed.height / effectiveSize.height
        )
    }
}

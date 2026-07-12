import PDFKit
import CoreGraphics

// ENGINE §5B.1 — PDFSelection-based character extraction.
// Uses composed-character-sequence iteration to handle surrogate pairs,
// emoji, and other multi-codeunit characters correctly.
// Avoids PDFPage.characterBounds(at:) due to iOS 18 regression (FB14843671, KI-2).

/// Stateless text extractor for the Searchable Redaction pipeline.
/// Extracts character positions from source PDF pages BEFORE rasterization
/// to preserve text layer data. See ENGINE §5B for the full specification.
public struct TextLayerExtractor: Sendable {

    public init() {}

    /// Extract all characters and their bounding boxes from a PDF page.
    ///
    /// Uses PDFSelection-based workaround for character bounds (KI-2).
    /// Iterates using composed-character-sequence ranges to correctly
    /// handle surrogate pairs, emoji, and composed characters (EXP-011).
    /// Synthesized separator offsets whose selection clamps to a
    /// neighboring glyph produce no entry, and neither does a whitespace
    /// offset whose selection box spans an inter-run gutter (see the
    /// in-loop notes); word-spacing whitespace keeps its entry.
    /// Each entry carries `lineIndex` — the count of line-separator
    /// offsets seen before it in `page.string` (PD-7); the line-aware
    /// character filter derives its per-line bands from this partition.
    ///
    /// - Parameter hasHiddenOCG: Doc-level OCG hidden-layer presence flag.
    ///   Computed once per document at import (ImportService.swift) so the
    ///   page-level check does not depend on `PDFDocument.documentURL`,
    ///   which is nil for `PDFDocument(data:)`. Defaults to `false` for
    ///   call sites that load fixtures via URL.
    /// - Throws: `PipelineError.redactionError(.reconstructionFailed)` if the
    ///   page references hidden OCG layers (AD-2-1 defense).
    /// - Returns: Array of CharacterInfo in document order.
    @concurrent
    public func extractCharacters(
        from page: PDFPage, hasHiddenOCG: Bool = false
    ) async throws -> [CharacterInfo] {
        try Task.checkCancellation()

        // OCG hidden text defense (AD-2-1, EXP-012): page.string extracts ALL
        // text including text in OCG layers marked /OFF. If hidden OCGs are
        // detected, throw to trigger per-page fallback to Secure Rasterization.
        // See ENGINE §5B.1.
        if Self.pageReferencesHiddenOCG(page, hasHiddenOCG: hasHiddenOCG) {
            throw PipelineError.redactionError(.reconstructionFailed)
        }

        guard let pageText = page.string else { return [] }
        let nsText = pageText as NSString
        let totalCodeUnits = page.numberOfCharacters  // UTF-16 count (Experiment F)
        var characters: [CharacterInfo] = []
        characters.reserveCapacity(totalCodeUnits)

        // Canonical coordinate contract — `sel.bounds(for:)` returns
        // coordinates in the source page's ABSOLUTE, UNROTATED (MediaBox/user)
        // space: it includes the cropBox origin offset (pinned for a
        // non-zero origin by `nonZeroCropBoxSelectionFrameProbe`) and is
        // INVARIANT under /Rotate (PDFKit treats /Rotate as a pure display
        // attribute; pinned for all four rotations by
        // `e1SelectionFrameUnderRotation`). To land every `CharacterInfo.bounds`
        // in OUTPUT-page coordinates — zero-origin AND rotation-applied
        // (displayed) — from extraction onward, the full source→output transform
        // is applied per glyph below:
        //   Translation: subtract the cropBox origin → cropBox-LOCAL.
        //   Rotation (T_rot): rotate the local rect into displayed space.
        // Order is local-FIRST-then-rotate: the mirror terms are only
        // meaningful against local extents, so rotation × non-zero CropBox
        // composes correctly only in this order. The rasterizer builds its
        // region-conversion basis on the matching zero-origin displayed output
        // page (`effectiveSize`), so the filter, the layout/bridge check,
        // and the Layer-7 digest all compare in ONE frame; the region side needs
        // NO mirror — it is produced in displayed space by every producer
        // Read the cropBox ONCE (not per glyph); `extractCharacters`
        // is a concurrency-validated PDFKit surface. For a
        // zero-origin, unrotated source page the transform is identity (the
        // PR #153 fixtures stay bit-identical).
        let cropBox = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360

        // ENGINE §5B.1: composed-character-sequence iteration via NSString.
        // PDFKit APIs use UTF-16 offsets (EXP-011).
        // PERF-8 / CANCEL-003: 256-iteration band counter — a 10k-character
        // page otherwise exceeds the 50 ms p95 cancel→surrender budget.
        var utf16Offset = 0
        var bandCounter = 0
        // PD-7 line partition: ticks at every line-separator source offset,
        // including offsets the guards below skip (nil selection, zero-size
        // bounds), so `lineIndex` is a property of the string alone.
        var lineIndex = 0
        // RC-10 break reference: the previous appended entry's PRE-rotation
        // width. Pre-rotation because /Rotate 90/270 swaps the axes and the
        // gutter test below compares along the advance axis.
        var previousLocalWidth: CGFloat?
        while utf16Offset < totalCodeUnits {
            if bandCounter & 0xFF == 0 { try Task.checkCancellation() }
            bandCounter += 1
            let composedRange = nsText.rangeOfComposedCharacterSequence(at: utf16Offset)

            let substring = nsText.substring(with: composedRange)
            if substring.contains(where: \.isNewline) {
                lineIndex += 1
                // Only a PURE separator cluster is consumed here. NSString
                // can compose a separator with a following combining mark
                // into one cluster ("\n" + U+0301); the mark is content and
                // its offset falls through to the normal walk (where the
                // clamp-signature skip still applies), keeping extraction
                // byte-identical to the pre-partition walk for such
                // clusters.
                if substring.allSatisfy(\.isNewline) {
                    utf16Offset += max(composedRange.length, 1)
                    continue
                }
            }

            guard let sel = page.selection(for: composedRange) else {
                utf16Offset += max(composedRange.length, 1)
                continue
            }
            let localBounds = sel.bounds(for: page)
                .offsetBy(dx: -cropBox.origin.x, dy: -cropBox.origin.y)  // cropBox-local translation
            let bounds = Self.rotateRectIntoOutputSpace(
                localBounds, sourceCropSize: cropBox.size, rotation: rotation
            )  // T_rot
            // Skip zero-size bounds (whitespace, control characters)
            guard bounds.width > 0, bounds.height > 0 else {
                utf16Offset += max(composedRange.length, 1)
                continue
            }

            let char = sel.string ?? substring
            if FilterResult.isLineageWhitespace(substring) {
                // `page.string` interleaves synthesized separator characters
                // (inter-run newlines/spaces) that have no glyph of their
                // own; `selection(for:)` over such an offset clamps to the
                // preceding glyph and reports that glyph's character with
                // its full-size, non-zero bounds — the zero-size guard above
                // does not exclude it. A whitespace-source offset
                // (`FilterResult.isLineageWhitespace`, the lineage-walk
                // predicate) whose selection returns a DIFFERENT character
                // is that clamp case: skip it.
                if char != substring {
                    utf16Offset += max(composedRange.length, 1)
                    continue
                }
                // Some whitespace offsets get a selection box
                // spanning a whole inter-run gutter (measured 17–397pt on
                // the sample fixture vs 1.9–6.8pt word spaces). Such an
                // entry sits gap-free against BOTH flanking columns, so the
                // run grouping can never split there and the drawn line
                // compresses the gutter to one cell — glyph geometry lands
                // far off the raster. The skip threshold is the grouping
                // adjacency break itself (`runMemberGroups`: a gap is a run
                // break at ≥ prev.width × 1.5): a whitespace entry at least
                // that wide is exactly one able to bridge a break — drop it
                // and the flanks split and bridge at raster-true positions.
                // Narrower whitespace cannot change grouping and keeps its
                // entry, so word spacing inside runs is preserved.
                let breakReference = previousLocalWidth ?? localBounds.height
                if localBounds.width >= breakReference * 1.5 {
                    utf16Offset += max(composedRange.length, 1)
                    continue
                }
            }
            characters.append(CharacterInfo(
                character: char, bounds: bounds, stringIndex: utf16Offset,
                lineIndex: lineIndex
            ))
            previousLocalWidth = localBounds.width

            utf16Offset += composedRange.length  // Advances by 2 for surrogate pairs
        }
        return characters
    }

    // MARK: - Rotation transform (T_rot)

    /// Map a cropBox-LOCAL rect (origin already subtracted) into OUTPUT-page
    /// space: zero-origin and rotation-applied (DISPLAYED). `/Rotate r` displays
    /// the page rotated r° clockwise (ISO 32000 §8.3.2; PixelOperations.swift §8.3
    /// note); PDFKit clamps r to {0, 90, 180, 270}, and the caller pre-normalizes.
    ///
    /// `size` is the SOURCE cropBox size, PRE-swap — the same `(w, h)` whose swap
    /// produces `effectiveSize`, never the effective/displayed dims (ADV-2 A2-7).
    /// `page.bounds(for: .cropBox)` reports this unrotated size for all rotations
    /// (pinned by E1). The four-case derivation (independently re-derived and
    /// corner-checked) is ADV-2 A2-7; with local rect `(x, y, wr, hr)`:
    ///   • r = 0:   identity.
    ///   • r = 90:  origin (y, w − x − wr), size (hr, wr).
    ///   • r = 180: origin (w − x − wr, h − y − hr), size (wr, hr) — double origin
    ///              mirror, NO dimension swap.
    ///   • r = 270: origin (h − y − hr, x), size (hr, wr).
    /// The region side needs no mirror (it is produced in displayed space by every
    /// producer, ADV-2 A2-8), so both filter inputs end in one displayed frame.
    static func rotateRectIntoOutputSpace(
        _ rect: CGRect, sourceCropSize size: CGSize, rotation: Int
    ) -> CGRect {
        let x = rect.minX, y = rect.minY, wr = rect.width, hr = rect.height
        let w = size.width, h = size.height
        switch rotation {
        case 90:
            return CGRect(x: y, y: w - x - wr, width: hr, height: wr)
        case 180:
            return CGRect(x: w - x - wr, y: h - y - hr, width: wr, height: hr)
        case 270:
            return CGRect(x: h - y - hr, y: x, width: hr, height: wr)
        default:  // 0 — and any unexpected value after clamping — is identity
            return rect
        }
    }

    // MARK: - OCG Hidden Layer Defense (AD-2-1)

    /// Check if a page references Optional Content Groups with hidden layers.
    /// Conservative approach for v1.0: any hidden OCG triggers fallback.
    ///
    /// page.string extracts text from ALL OCGs including those marked /OFF.
    /// If hidden text exists, the character filter could miss it (text is in
    /// page.string but not visually positioned), creating a leakage path.
    /// See ENGINE §5B.1 and EXP-012.
    ///
    /// M1: the doc-level walk (`/OCProperties → /D → /OFF`) is precomputed at
    /// import time and supplied via `hasHiddenOCG`. The previous in-engine
    /// walk went through `page.document?.documentURL`, which is nil for
    /// `PDFDocument(data:)` — i.e. every production import path — so the
    /// defense silently failed open. The page-level `/Resources /Properties`
    /// check stays here because it varies per page.
    static func pageReferencesHiddenOCG(
        _ page: PDFPage, hasHiddenOCG: Bool
    ) -> Bool {
        guard hasHiddenOCG else { return false }

        guard let pageRef = page.pageRef,
              let dict = pageRef.dictionary else { return false }

        // Check if the page's resources reference /Properties (OCG markers)
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else { return false }

        var properties: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "Properties", &properties),
              properties != nil else { return false }

        return true
    }

    /// Doc-level OCG check intended to run once at import time, when raw bytes
    /// are still available to build a `CGPDFDocument`. Walks the catalog for
    /// `/OCProperties → /D → /OFF` and reports whether any OCGs are marked
    /// hidden by the default config. The page-level companion
    /// `pageReferencesHiddenOCG(_:hasHiddenOCG:)` consumes this flag and adds
    /// the cheap per-page `/Resources /Properties` check. See ENGINE §5B.1
    /// (M1 fix).
    public static func documentHasHiddenOCG(_ document: CGPDFDocument) -> Bool {
        guard let catalog = document.catalog else { return false }

        var ocProps: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "OCProperties", &ocProps),
              let ocProperties = ocProps else { return false }

        var defaultConfig: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(ocProperties, "D", &defaultConfig),
              let config = defaultConfig else { return false }

        var offArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(config, "OFF", &offArray), let off = offArray {
            return CGPDFArrayGetCount(off) > 0
        }
        return false
    }
}

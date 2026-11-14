import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

/// The walk as it shipped before joined glyphs were written once, copied
/// unchanged but for its name and its references to the extractor's own
/// helpers. Each test runs it beside the walk of record on the same page.
enum WalkBeforeJoinedGlyphFix {

    @concurrent
    static func extractCharacters(
        from page: PDFPage, hasHiddenOCG: Bool = false
    ) async throws -> [CharacterInfo] {
        try Task.checkCancellation()

        // OCG hidden text defense: page.string extracts ALL
        // text including text in OCG layers marked /OFF. If hidden OCGs are
        // detected, throw to trigger per-page fallback to Secure Rasterization.
        if TextLayerExtractor.pageReferencesHiddenOCG(page, hasHiddenOCG: hasHiddenOCG) {
            throw PipelineError.redactionError(.reconstructionFailed)
        }

        guard let pageText = page.string else { return [] }
        let nsText = pageText as NSString
        let totalCodeUnits = page.numberOfCharacters  // UTF-16 count
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

        // Composed-character-sequence iteration via NSString.
        // PDFKit APIs use UTF-16 offsets.
        // 256-iteration band counter — a 10k-character
        // page otherwise exceeds the 50 ms p95 cancel→surrender budget.
        var utf16Offset = 0
        var bandCounter = 0
        // Line partition: ticks at every line-separator source offset,
        // including offsets the guards below skip (nil selection, zero-size
        // bounds), so `lineIndex` is a property of the string alone.
        var lineIndex = 0
        // Break reference: the previous appended entry's PRE-rotation
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
            let bounds = TextLayerExtractor.rotateRectIntoOutputSpace(
                localBounds, sourceCropSize: cropBox.size, rotation: rotation
            )  // T_rot
            // Skip zero-size bounds (whitespace, control characters)
            guard bounds.width > 0, bounds.height > 0 else {
                utf16Offset += max(composedRange.length, 1)
                continue
            }

            let char = sel.string ?? substring
            if SandwichMetrics.isLineageWhitespace(substring) {
                // `page.string` interleaves synthesized separator characters
                // (inter-run newlines/spaces) that have no glyph of their
                // own; `selection(for:)` over such an offset clamps to the
                // preceding glyph and reports that glyph's character with
                // its full-size, non-zero bounds — the zero-size guard above
                // does not exclude it. A whitespace-source offset
                // (`SandwichMetrics.isLineageWhitespace`, the lineage-walk
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
}

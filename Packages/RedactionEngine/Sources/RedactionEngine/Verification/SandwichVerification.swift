import PDFKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit  // macOS tooling destination: NSFont carries the .font attribute
#endif

// ENGINE §6.6 — Layers 6–10: Sandwich-specific verification.
// Runs only for Searchable Redaction pages.

/// Sandwich-specific verification layers for the Searchable Redaction pipeline.
/// These layers verify that the invisible text layer is correctly constructed
/// and does not leak redacted content.
public struct SandwichVerification: Sendable {

    /// Courier monospace advance-per-point constant. CoreText's 16-bit
    /// fixed-point representation of Adobe Font Metrics' 600-units-per-em
    /// Courier advance (600/1000 = 0.6). Probed against
    /// `CTFontGetAdvancesForGlyphs` for sizes {1, 6, 12, 24, 100}pt — the
    /// advance is exactly `0.60009765625 × fontSize` for every probed size.
    /// See ENGINE §6.6 SVT-1 and plan §3.1.
    public static let courierAdvancePerPoint: CGFloat = 0.60009765625

    /// Tolerance for the Layer 6 advance crosscheck at the 12pt REFERENCE
    /// size (M1 tightening). J-12 (2026-06-09) derives line pitches from
    /// source metrics, so the operative tolerance scales linearly with the
    /// glyph's own point size via `advanceWidthTolerancePerPoint`; this
    /// constant remains the 12pt anchor (and the value probe/test code
    /// built against the 12pt-era geometry still reads).
    public static let advanceWidthTolerance: CGFloat = 0.25

    /// Linear scaling of the advance tolerance: `0.25pt at 12pt`, applied
    /// as `advanceWidthTolerancePerPoint × pointSize` (J-12 rider).
    public static let advanceWidthTolerancePerPoint: CGFloat = 0.25 / 12.0

    /// Vertical sweep tolerance for canonical line banding (J-12): walking
    /// Y values in descending order, a gap greater than this opens a new
    /// band. Shared by the reconstructor's line pooling, the filter-side
    /// lineage walk, and the verifier's output walk so all three agree on
    /// band structure. Source line spacing in real documents is several
    /// points; sub-baseline offsets (superscripts, ordinals) sit well
    /// under 1pt — measured on the committed real-document fixture
    /// (RealDocProbeTests S06, 2026-06-09).
    public static let lineBandTolerance: CGFloat = 1.5

    /// Single-linkage sweep over Y values: returns each input index's band
    /// ordinal (0 = topmost). Deterministic in the input values only.
    /// ENGINE §6.6 SVT-2 (J-12 canonical order).
    static func yBands(_ ys: [CGFloat]) -> [Int] {
        let order = ys.indices.sorted { ys[$0] > ys[$1] }
        var band = [Int](repeating: 0, count: ys.count)
        var current = 0
        var prevY = CGFloat.nan
        for idx in order {
            if !prevY.isNaN, prevY - ys[idx] > lineBandTolerance { current += 1 }
            band[idx] = current
            prevY = ys[idx]
        }
        return band
    }

    /// Natural CoreText advance of one composed grapheme in the accepted
    /// family's own font at `pointSize` — the J-13 acceptance reference.
    /// A font's natural advance is a writer/font property, not a position
    /// channel an attacker controls; comparing a measured origin delta
    /// against it (plus whole gap cells) keeps encoding-external glyphs
    /// (e.g. U+2248, drawn by CTLine at their natural non-0.6-em widths)
    /// inside the verified lattice. A grapheme the family does not cover
    /// has no natural advance (nil → the caller falls back to the cell).
    static func naturalFamilyAdvance(
        _ grapheme: String, familyName: String, pointSize: CGFloat
    ) -> CGFloat? {
        let name = familyName.lowercased().contains("menlo")
            ? "Menlo-Regular" : "Courier"
        let font = CTFontCreateWithName(name as CFString, pointSize, nil)
        let utf16 = Array(grapheme.utf16)
        guard !utf16.isEmpty else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else {
            return nil
        }
        var advances = [CGSize](repeating: .zero, count: utf16.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, utf16.count)
        return advances.reduce(0) { $0 + $1.width }
    }

    /// True when a read-back point size is one the reconstructor's §5C.2
    /// pitch derivation can emit: a whole multiple of
    /// `pitchQuantizationStep` at or above `minimumFontSize` (J-14). The
    /// SVT-1 pitch-flip acceptance gates on this so a foreign text object
    /// at an arbitrary size never reads as a writer-band junction.
    static func isWriterQuantizedPitch(_ size: CGFloat) -> Bool {
        guard size >= TextLayerReconstructor.minimumFontSize - 0.01 else {
            return false
        }
        let steps = size / TextLayerReconstructor.pitchQuantizationStep
        return abs(steps - steps.rounded()) * TextLayerReconstructor.pitchQuantizationStep <= 0.01
    }

    /// Descent fraction of a read-back font's line box —
    /// `descent / (ascent + descent)` — used to shrink read-back selection
    /// boxes to their glyph-core row. The name mapping matches
    /// `naturalFamilyAdvance` (Menlo family → Menlo-Regular, everything
    /// else → Courier: the layer only carries accepted monospace families,
    /// Layer 8 reports any other). 0.25 without a resolvable font — at or
    /// above the accepted families' fractions (Courier 0.2465, Menlo
    /// 0.2028), so the unknown-font core is never larger than a known one.
    static func descentFraction(
        family: String?, pointSize: CGFloat
    ) -> CGFloat {
        guard let family, pointSize > 0 else { return 0.25 }
        let name = family.lowercased().contains("menlo")
            ? "Menlo-Regular" : "Courier"
        let font = CTFontCreateWithName(name as CFString, pointSize, nil)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        guard ascent + descent > 0 else { return 0.25 }
        return descent / (ascent + descent)
    }

    public init() {}

    // MARK: - Layer 6: Spatial Exclusion Verification (ENGINE §6.6)

    /// Verify that no character in the output text layer intersects any
    /// redaction region. This is a geometric re-check independent of string
    /// content — defense-in-depth against character filtering bugs.
    ///
    /// CC-5-1: Receives PDFPage (non-Sendable). Safety: verification runner
    /// calls layers sequentially; output PDFDocument is distinct from source.
    ///
    /// IMPORTANT: redactionRects must be in PDF page coordinates (bottom-left
    /// origin, in points). Use normalizedToPDFPageCoordinates() with the
    /// OUTPUT page bounds (always zero-origin per EXP-011).
    /// Called from the @concurrent runLayer() context — inherits caller isolation.
    /// Not marked @concurrent itself to avoid PDFPage sending errors (CC-5-1).
    /// This convenience overload checks one rect per region — raw
    /// intersection at the default 0pt margin — by building shapes whose
    /// floor and halo coincide at the (optionally margined) rect. The
    /// production dispatch (VerificationEngine Layer 6) builds two-tier
    /// shapes instead: un-expanded floor + safety-margin halo (PD-8; see
    /// the regionShapes overload).
    public func verifySpatialExclusion(
        outputPage: PDFPage,
        redactionRects: [CGRect],
        safetyMargin: CGFloat = 0.0,
        pageIndex: Int = 0
    ) async throws -> VerificationStatus {
        let shapes = redactionRects.map { rect in
            RegionShape(
                expandedBounds: rect.insetBy(dx: -safetyMargin, dy: -safetyMargin),
                polygonVertices: nil
            )
        }
        return try await verifySpatialExclusion(
            outputPage: outputPage,
            regionShapes: shapes,
            pageIndex: pageIndex
        )
    }

    /// DRAW-1 polygon-aware overload. Each `RegionShape` carries the
    /// safety-margin-expanded bounding rect, the un-expanded rect, and an
    /// optional polygon.
    ///
    /// Written contract (mirroring the character filter):
    /// no non-whitespace synthetic character's GLYPH-CORE box may
    /// intersect a region rect at 0pt — the unconditional floor; the
    /// safety-margin halo tier applies within band-intersecting lines,
    /// mirroring the filter. A contract trip is CLASSIFIED by the core
    /// box's center against the un-expanded region: center inside → the
    /// character sits in the region, FAIL; center outside → a positional
    /// edge graze whose content lies outside the region, reported as a
    /// WARN note after the lattice pass (drawn positions drift at band
    /// pitch, so a survivor beside an embedded region can cross the rect
    /// edge without its content entering the region; content coverage
    /// stays with Layers 7/9). The glyph-core box is the read-back box
    /// vertically inset at both ends by the read-back font's descent
    /// fraction: the writer anchors drawn baselines at source
    /// line-box edges, so a read-back LINE box legitimately shades into a
    /// sub-point-adjacent region by up to one descent — a font metric,
    /// not glyph core. Read-back characters whose text is
    /// lineage-whitespace are outside the check's domain: PDFKit
    /// synthesizes and coalesces inter-run whitespace on the output side
    /// (a coalesced bridge-space box can span a whole gutter and graze a
    /// region the drawn ink never touches), the SVT-1/L9 domains already
    /// exclude whitespace, and an invisible space carries no content.
    /// Line bands derive from the same `yBands` sweep the SVT-1 lattice
    /// uses, over the core boxes. For a shape whose
    /// `bounds == expandedBounds` (the legacy construction) the two tiers
    /// coincide and the check reduces to its previous single-rect form.
    public func verifySpatialExclusion(
        outputPage: PDFPage,
        regionShapes: [RegionShape],
        pageIndex: Int = 0
    ) async throws -> VerificationStatus {
        // PERF-8 / CANCEL-002: entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let pageText = outputPage.string else { return .pass }
        let nsText = pageText as NSString
        let count = outputPage.numberOfCharacters
        // Count-only guard. `!regionShapes.isEmpty` was dropped so the
        // SVT-1 origin-delta lattice (below) also runs on region-less pages —
        // glyph-position tampering on a page with no redaction regions was the
        // only positional blind spot. The per-character exclusion loop is a
        // no-op on [] shapes, and the lattice gap-skip skips no pairs (strictly
        // more pairs validated). The nil-`string` guard above still covers a
        // page with no text layer.
        guard count > 0 else { return .pass }

        // PERF-8 / CANCEL-002: 256-iteration band counter in the per-character
        // walk. A 10k-character page would otherwise exceed the 50 ms p95
        // cancel→surrender budget; bitmask check is amortized constant time.
        var bandCounter = 0
        var utf16Offset = 0
        // Non-whitespace units for the exclusion pass, in string order (the
        // band gate needs the whole page's Y structure before any verdict,
        // so collection precedes checking; failure order stays first-offset).
        var exclusionUnits: [(bounds: CGRect, utf16Offset: Int,
                              family: String?, pointSize: CGFloat)] = []
        // Units collected for the SVT-1 origin-delta lattice pass below.
        var latticeUnits: [(string: String, bounds: CGRect,
                            family: String, pointSize: CGFloat,
                            utf16Offset: Int)] = []
        while utf16Offset < count {
            if bandCounter & 0xFF == 0 { try Task.checkCancellation() }
            bandCounter += 1
            let composedRange = nsText.rangeOfComposedCharacterSequence(at: utf16Offset)
            guard let sel = outputPage.selection(for: composedRange) else {
                utf16Offset += max(composedRange.length, 1)
                continue
            }
            let bounds = sel.bounds(for: outputPage)
            guard bounds.width > 0, bounds.height > 0 else {
                utf16Offset += max(composedRange.length, 1)
                continue
            }

            // Selection bounds are used as-is horizontally. PDFKit's
            // reported bounds are the authoritative position for each
            // character; the exclusion pass below derives its glyph-core
            // boxes from them per unit.
            let charString = nsText.substring(with: composedRange)
            if !FilterResult.isLineageWhitespace(charString) {
                var family: String?
                var pointSize: CGFloat = 0
                #if canImport(UIKit)
                if let attr = sel.attributedString,
                   attr.length > 0,
                   let font = attr.attribute(
                    .font, at: 0, effectiveRange: nil) as? UIFont {
                    family = font.familyName
                    pointSize = font.pointSize
                }
                #else
                // macOS tooling destination: the attribute is an NSFont, whose
                // familyName is optional (fall back to fontName, same gating
                // outcome for the Courier/Menlo family check).
                if let attr = sel.attributedString,
                   attr.length > 0,
                   let font = attr.attribute(
                    .font, at: 0, effectiveRange: nil) as? NSFont {
                    family = font.familyName ?? font.fontName
                    pointSize = font.pointSize
                }
                #endif
                exclusionUnits.append((bounds, utf16Offset, family, pointSize))
                if let family {
                    latticeUnits.append((charString, bounds, family,
                                         pointSize, utf16Offset))
                }
            }

            utf16Offset += composedRange.length
        }

        // Exclusion pass: two tiers over the non-whitespace
        // units' glyph-core boxes. An edge graze (core box crossing a region
        // edge with its center outside) is held as a positional note and
        // returned WARN after the lattice pass below, so a lattice FAIL is
        // never masked by it.
        var firstGrazeMessage: String?
        try Task.checkCancellation()
        if !regionShapes.isEmpty, !exclusionUnits.isEmpty {
            var fractionCache: [String: CGFloat] = [:]
            let coreBoxes: [CGRect] = exclusionUnits.map { unit in
                let key = "\(unit.family ?? "-")|\(unit.pointSize)"
                let fraction = fractionCache[key] ?? {
                    let f = Self.descentFraction(
                        family: unit.family, pointSize: unit.pointSize)
                    fractionCache[key] = f
                    return f
                }()
                return unit.bounds.insetBy(
                    dx: 0, dy: fraction * unit.bounds.height)
            }
            let unitBands = Self.yBands(coreBoxes.map(\.minY))
            // Union rect per read-back band — the line-band the halo tier
            // gates on (mirror of the filter's per-lineIndex bands).
            var bandRects: [Int: CGRect] = [:]
            for (k, core) in coreBoxes.enumerated() {
                bandRects[unitBands[k]] =
                    bandRects[unitBands[k]].map { $0.union(core) } ?? core
            }
            unitLoop: for (k, unit) in exclusionUnits.enumerated() {
                let core = coreBoxes[k]
                let band = bandRects[unitBands[k]] ?? core
                for shape in regionShapes {
                    let overlaps: Bool
                    if let vertices = shape.polygonVertices {
                        // Tier (a) — 0pt floor: glyph-core box vs
                        // un-expanded polygon (expanded rect pre-gates).
                        if core.intersects(shape.expandedBounds),
                           rectIntersectsPolygon(core, vertices: vertices) {
                            overlaps = true
                        } else if shape.bounds.intersects(band) {
                            // Tier (b) — halo with the filter's Minkowski
                            // char-expansion mechanics, within
                            // band-intersecting lines.
                            let expandedChar = core.insetBy(
                                dx: -safetyMarginPoints, dy: -safetyMarginPoints
                            )
                            overlaps = expandedChar.intersects(shape.expandedBounds)
                                && rectIntersectsPolygon(expandedChar, vertices: vertices)
                        } else {
                            overlaps = false
                        }
                    } else {
                        // Tier (a) floor at the un-expanded rect; tier (b)
                        // halo at the expanded rect within band-intersecting
                        // lines.
                        overlaps = core.intersects(shape.bounds)
                            || (core.intersects(shape.expandedBounds)
                                && shape.bounds.intersects(band))
                    }
                    if overlaps {
                        // Classify by the glyph-core CENTER against the
                        // un-expanded region. Center inside → the character
                        // sits IN the region: an output defect, FAIL. Center
                        // outside → a positional edge graze: band-pitch drawn
                        // positions drift, so a survivor beside an embedded
                        // region can land with its core box crossing the rect
                        // edge while its content stays outside — a
                        // writer↔verifier contract note, not exposed content
                        // (content leaks stay covered by Layers 7/9). The
                        // first graze is held so a later in-region hit on
                        // this page is never masked by it.
                        let center = CGPoint(x: core.midX, y: core.midY)
                        let centerInRegion: Bool
                        if let vertices = shape.polygonVertices {
                            centerInRegion = Self.polygonContainsPoint(
                                center, vertices: vertices)
                        } else {
                            centerInRegion = shape.bounds.contains(center)
                        }
                        if centerInRegion {
                            return .fail(
                                "A character overlaps a redacted area on page \(pageIndex + 1) (position \(unit.utf16Offset))"
                            )
                        }
                        if firstGrazeMessage == nil {
                            firstGrazeMessage =
                                "A character touches the edge of a redacted area on page \(pageIndex + 1). "
                                + "Its content is outside the redacted area. (position \(unit.utf16Offset))"
                        }
                        continue unitLoop
                    }
                }
            }
        }

        // ENGINE §6.6 SVT-1 (J-13 refinement, 2026-06-09): origin-delta
        // lattice crosscheck, replacing the M1 selection-WIDTH check. The
        // Bland et al. kerning channel displaces glyph ORIGINS, so the
        // consecutive same-band origin delta is the direct signal; PDFKit
        // selection widths absorb adjacent gap slack on any faithful-pitch
        // layout (a glyph before an intra-line hole reports the hole's
        // span in its width) and cannot distinguish tampering from gap
        // synthesis. Per canonical band (Y sweep, X ascending), every
        // consecutive non-whitespace pair in an accepted monospace family
        // must sit at `delta == natural(prev) + j × cell`, integer j ≥ 0
        // (j counts whole skipped gap cells — bridge/synthesized spaces
        // are whitespace and excluded above), within the linearly scaled
        // tolerance. The natural-advance reference (J-13/N1, approved
        // 2026-06-09) is the accepted family's own CoreText advance — a
        // writer/font property, not a position channel — so encoding-
        // external glyphs (U+2248 at 0.549 em) verify without widening
        // the lattice; TJ kerning injections land off it and still FAIL
        // (RT-1). A point-size change inside a band FAILs: the
        // reconstructor draws each band at one pooled pitch, so a mid-band
        // pitch flip in an accepted family reports output this writer did
        // not produce. Pairs whose gap interval intersects a redaction
        // shape are skipped — the layout hole at a region is the region's
        // own geometry, already visible in the raster.
        try Task.checkCancellation()
        if !latticeUnits.isEmpty {
            let bands = Self.yBands(latticeUnits.map(\.bounds.minY))
            let order = latticeUnits.indices.sorted {
                bands[$0] != bands[$1]
                    ? bands[$0] < bands[$1]
                    : latticeUnits[$0].bounds.minX < latticeUnits[$1].bounds.minX
            }
            for k in 1..<order.count {
                let prev = latticeUnits[order[k - 1]]
                let curr = latticeUnits[order[k]]
                guard bands[order[k - 1]] == bands[order[k]],
                      Self.isCourierMonospaceFamily(prev.family),
                      Self.isCourierMonospaceFamily(curr.family),
                      prev.pointSize > 0
                else { continue }
                if abs(prev.pointSize - curr.pointSize) > 0.01 {
                    // J-14 (2026-07-20): the writer pools ONE pitch per
                    // SOURCE-Y band, but PDFKit read-back pools adjacent
                    // writer lines into one selection line box, so a
                    // verifier band can legitimately straddle a writer-band
                    // junction and carry two pitches. The junction is
                    // accepted only when BOTH sizes sit on the writer's own
                    // pitch lattice (§5C.2 quantization step, minimum size)
                    // — the grammar no foreign text object follows for free
                    // — and it resets the delta chain: each writer band
                    // re-anchors on its own cell grid, so no cross-pitch
                    // origin relation exists to verify. Positions within
                    // each pitch run stay lattice-pinned; the run-start
                    // origin gains only the freedom every band start
                    // already has. The size class itself is the §5C.4
                    // accepted bounded-bits channel. Any off-lattice size
                    // flip still reports output this writer did not
                    // produce.
                    if Self.isWriterQuantizedPitch(prev.pointSize),
                       Self.isWriterQuantizedPitch(curr.pointSize) {
                        continue
                    }
                    return .fail(
                        "Non-uniform glyph advance on page \(pageIndex + 1) at offset \(curr.utf16Offset)"
                    )
                }
                let delta = curr.bounds.minX - prev.bounds.minX
                guard delta > 0 else { continue }
                let gapRect = CGRect(
                    x: prev.bounds.minX,
                    y: min(prev.bounds.minY, curr.bounds.minY),
                    width: delta,
                    height: max(prev.bounds.maxY, curr.bounds.maxY)
                        - min(prev.bounds.minY, curr.bounds.minY))
                // Gap-skip tests the UN-expanded rect: a layout hole at a
                // region is the region's own geometry; the halo is a filter
                // buffer, not drawn geometry.
                if regionShapes.contains(where: {
                    $0.bounds.intersects(gapRect)
                }) { continue }
                let cell = Self.courierAdvancePerPoint * prev.pointSize
                let tolerance = Self.advanceWidthTolerancePerPoint * prev.pointSize
                let natural = Self.naturalFamilyAdvance(
                    prev.string, familyName: prev.family,
                    pointSize: prev.pointSize) ?? cell
                let j = max(0, ((delta - natural) / cell).rounded())
                if abs(delta - (natural + j * cell)) > tolerance {
                    return .fail(
                        "Non-uniform glyph advance on page \(pageIndex + 1) at offset \(curr.utf16Offset)"
                    )
                }
            }
        }
        if let firstGrazeMessage {
            return .warn(firstGrazeMessage)
        }
        return .pass
    }

    /// Even-odd point-in-polygon test (ray cast), matching the even-odd
    /// convention `rectIntersectsPolygon` uses for region polygons.
    static func polygonContainsPoint(
        _ point: CGPoint, vertices: [CGPoint]
    ) -> Bool {
        guard vertices.count >= 3 else { return false }
        var inside = false
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let a = vertices[i]
            let b = vertices[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: - Layer 7: Character Count Cross-Check (ENGINE §6.6)

    /// Layer 7 excess tolerance, in composed characters (VH-1 re-pin).
    /// With both sides of the comparison counting NON-whitespace only
    /// (below), PDFKit's synthesized inter-run whitespace is out of the
    /// domain and the two counts agree exactly on the sample-statement and
    /// loan-packet fixtures (measured 0 excess on every page). The
    /// prior `max(n/10, 100)` band absorbed a per-line duplicate-character
    /// defect wholesale; a small constant keeps the check sensitive at any
    /// page size while leaving room for a stray decoder divergence.
    static let characterCountExcessTolerance = 2

    /// Compare the number of non-whitespace characters in the output text
    /// layer against the PageFilterDigest from the extraction phase (VH-1).
    ///
    /// Uses composed-character-sequence iteration (same as extractCharacters)
    /// to count output characters — NOT PDFPage.numberOfCharacters which
    /// uses inconsistent counting for emoji/supplementary-plane (EXP C1.1).
    /// The count domain is non-whitespace on BOTH sides (mirror of the L9
    /// lineage domain): PDFKit synthesizes inter-run whitespace — and
    /// clamp-reports synthesized separators with non-zero bounds — on the
    /// output side, while the extraction stream legitimately carries
    /// word-spacing whitespace entries; neither view's whitespace exists
    /// in the other.
    ///
    /// A mismatch indicates characters were added or dropped during reconstruction.
    public func verifyCharacterCount(
        outputPage: PDFPage,
        digest: PageFilterDigest
    ) async throws -> VerificationStatus {
        // PERF-8 / CANCEL-002: entry-level cooperative cancellation.
        try Task.checkCancellation()
        let outputCount = try countComposedCharacters(outputPage)
        let expectedCount = digest.survivingNonWhitespaceCount

        // Deficit = characters lost during reconstruction (security concern)
        if outputCount < expectedCount {
            return .fail(
                "Character count deficit on page \(digest.pageIndex + 1): "
                + "output has \(outputCount), expected \(expectedCount)"
            )
        }
        if outputCount > expectedCount + Self.characterCountExcessTolerance {
            return .warn(
                "Character count excess on page \(digest.pageIndex + 1): "
                + "output has \(outputCount), expected \(expectedCount)"
            )
        }
        return .pass
    }

    /// Count non-whitespace characters using composed-character-sequence
    /// iteration, matching extractCharacters()'s unit (§5B.1) and the
    /// output lineage walk's two skip conditions (zero bounds, lineage
    /// whitespace — see `computeOutputLineageHash`).
    private func countComposedCharacters(_ page: PDFPage) throws -> Int {
        guard let text = page.string else { return 0 }
        let nsText = text as NSString
        let totalCodeUnits = page.numberOfCharacters
        var count = 0
        var utf16Offset = 0
        // PERF-8 / CANCEL-002: 256-iteration band counter in the per-character
        // walk — mirrors verifySpatialExclusion's cancel-checkpoint cadence.
        var bandCounter = 0

        while utf16Offset < totalCodeUnits {
            if bandCounter & 0xFF == 0 { try Task.checkCancellation() }
            bandCounter += 1
            let composedRange = nsText.rangeOfComposedCharacterSequence(at: utf16Offset)
            // Only count characters with non-zero bounds (matching
            // extractCharacters behavior) whose text is not lineage
            // whitespace (the shared L7/L9 count domain).
            if !FilterResult.isLineageWhitespace(nsText.substring(with: composedRange)),
               let sel = page.selection(for: composedRange) {
                let bounds = sel.bounds(for: page)
                if bounds.width > 0 && bounds.height > 0 {
                    count += 1
                }
            }
            utf16Offset += max(composedRange.length, 1)
        }
        return count
    }

    // MARK: - Layer 8: Font Verification (ENGINE §6.6)

    /// Accepted monospace font suffixes for the invisible text layer.
    /// Courier is the primary target; Menlo is accepted because
    /// CTFontCreateWithName("Courier") maps to Menlo-Regular on some
    /// iOS versions. Both are monospace with uniform advance widths —
    /// security properties are equivalent (no ligatures, no variable spacing).
    private static let acceptedFontSuffixes = [
        "+Courier", "+Courier-Bold", "+CourierNewPSMT",
        "+Menlo-Regular", "+Menlo-Bold", "+Menlo-Italic", "+Menlo-BoldItalic"
    ]
    private static let acceptedBareNames: Set<String> = [
        "Courier", "Courier-Bold", "CourierNewPSMT",
        "Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Menlo-BoldItalic"
    ]

    /// True when the UIFont family name corresponds to one of the accepted
    /// monospace families (Courier or Menlo). Used by the Layer 6 advance-
    /// width crosscheck (SVT-1) to gate the check on outputs the
    /// reconstructor itself produces; non-monospace fixtures running through
    /// `verifySpatialExclusion` are reported by Layer 8 instead.
    static func isCourierMonospaceFamily(_ familyName: String) -> Bool {
        let lower = familyName.lowercased()
        return lower.contains("courier") || lower.contains("menlo")
    }

    /// Verify that all fonts in the output PDF are accepted monospace fonts.
    /// No original-document fonts should survive.
    ///
    /// EXP E5.1: CGPDFContext embeds fonts as TrueType with a random
    /// 6-letter subset prefix (e.g., "AAAAAB+Courier"). Layer 8 matches
    /// against /BaseFont using suffix check.
    public func verifyFontsAreMonospace(
        outputPage: PDFPage,
        pageIndex: Int
    ) async throws -> VerificationStatus {
        // PERF-8 / CANCEL-002: entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let pageRef = outputPage.pageRef,
              let dict = pageRef.dictionary else {
            return .warn("Could not inspect page fonts on page \(pageIndex + 1)")
        }

        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else {
            // A page with NO page-level /Resources cannot be font-
            // verified here. Pages-tree-inherited /Resources are legal PDF but
            // out of the threat model (verifying Resecta's own reconstruction,
            // which always writes page-level /Resources for drawn fonts). WARN
            // rather than silently passing, per the fail-visible convention.
            return .warn("Page \(pageIndex + 1) has no page-level /Resources — font verification skipped")
        }

        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "Font", &fonts),
              let fontDict = fonts else {
            return .pass
        }

        var result: VerificationStatus = .pass
        let pageNum = pageIndex + 1
        CGPDFDictionaryApplyBlock(fontDict, { key, value, ctx in
            var fontObj: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &fontObj),
                  let font = fontObj else { return true }

            // The /BaseFont accept-check is the Layer-8 security boundary
            // and is UNCHANGED by the J-5 refinement below: an unaccepted
            // BaseFont FAILs with or without a CMap, and a font dict with
            // no readable /BaseFont is never `accepted`.
            var accepted = false
            var baseFont: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(font, "BaseFont", &baseFont),
               let name = baseFont {
                let fontName = String(cString: name)
                accepted = Self.acceptedBareNames.contains(fontName)
                    || Self.acceptedFontSuffixes.contains(where: { fontName.hasSuffix($0) })
                if !accepted {
                    let resultPtr = ctx!.assumingMemoryBound(to: VerificationStatus.self)
                    resultPtr.pointee = .fail("Non-monospace font found on page \(pageNum): \(fontName)")
                    return false
                }
            }

            // ENGINE §6.6 SVT-4 (J-5 refinement, 2026-06-09): a /ToUnicode
            // CMap is tolerated ONLY on a font the /BaseFont check above
            // accepted (a fresh CGPDFContext Courier/Menlo subset); on any
            // other font dict it remains a structural anomaly and FAILs.
            // EXP-E6.2 superseded EXP-E5.1's no-CMap attestation: the writer
            // emits a /ToUnicode-bearing subset for any glyph outside its
            // simple 8-bit encoding — under fully explicit, fully covered
            // draws — and that CMap is load-bearing for those glyphs'
            // extraction, so a strict no-CMap rule rejects faithful output
            // (probe F reproduces the real-doc 20/23-page CMap picture with
            // no reconstructor involvement).
            //
            // Preserved-invariant argument (00-PLAN §3.4, J-5 APPROVED):
            // an Apple-writer-emitted CMap on an accepted fresh subset maps
            // only the drawn surviving glyphs — redacted content was
            // filtered before drawing and never embedded, so the CMap
            // cannot carry it. Content/operator leakage is independently
            // covered by Layer 3 (SVT-3) and Layer 10 (SVT-5). The residual
            // given up — a hand-injected, content-divergent CMap on a
            // spoofed accepted BaseFont — requires post-export tampering,
            // outside the threat boundary (RT-6, §6.6 M4 residual).
            var cmap: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(font, "ToUnicode", &cmap), !accepted {
                let resultPtr = ctx!.assumingMemoryBound(to: VerificationStatus.self)
                resultPtr.pointee = .fail(
                    "Unaccepted font carries /ToUnicode CMap on page \(pageNum)"
                )
                return false
            }
            return true
        }, &result)

        return result
    }

    // MARK: - Layer 9: Character Lineage (ENGINE §6.6 SVT-2)

    /// Re-compute the SHA-256 over the output page's composed-character
    /// iteration and report mismatch against the filter's recorded
    /// `lineageHash`. Reordering, insertion, deletion, or replacement of
    /// non-zero-bounds composed characters between the filter's surviving
    /// set and the final PDF flips the hash. Zero-width injections do NOT
    /// flip it — both sides iterate non-zero-bounds composed characters
    /// only (skip condition 1 below), so a zero-bounds insertion is outside
    /// the hash domain. That is the pinned M4 residual (adversarial suite
    /// SVT-3/SVT-5 coverage): a term-bearing injection, zero-width or not,
    /// is surfaced by Layers 3 and 10's term scans instead. Spatial
    /// tampering (chars shifted to different page coordinates with
    /// identical content and order) is the responsibility of Layer 6 SVT-1,
    /// which compares raw `selection.bounds` against the redaction shapes
    /// per character. See plan §4.4.
    ///
    /// Hash domain (post-H1 redesign): `(character.utf8, globalPos)` per
    /// non-zero-bounds composed character, where `globalPos` is a 0-indexed
    /// integer counter. The pre-redesign domain folded snapped X and Y
    /// into the hash, which required matching floating-point positions
    /// across filter (source-side bounds) and verifier (PDFKit output-side
    /// bounds). The new domain drops positions and pins the iteration unit
    /// to NSString composed sequences on both sides — see
    /// `FilterResult.computeLineageHash` for the matching filter-side
    /// walk.
    ///
    /// CC-5-1: Receives PDFPage (non-Sendable). Safety: verification runner
    /// calls layers sequentially; output PDFDocument is distinct from source.
    public func verifyCharacterLineage(
        outputPage: PDFPage,
        digest: PageFilterDigest
    ) async throws -> VerificationStatus {
        // PERF-8 / CANCEL-002 (VQ-24): entry-level cooperative cancellation —
        // Layer 9 previously had none, so a cancel arriving mid-lineage-walk
        // was not honored until the layer completed. The composed-character
        // walk below carries the banded 256-cadence checks (house pattern).
        try Task.checkCancellation()
        // Pages where the filter recorded no surviving characters have an
        // empty lineage hash; the corresponding output page is expected to
        // have no composed characters of its own.
        guard !digest.lineageHash.isEmpty else { return .pass }

        let outputHash = try Self.computeOutputLineageHash(outputPage)
        if outputHash != digest.lineageHash {
            return .fail(
                "Character lineage mismatch on page \(digest.pageIndex + 1)"
            )
        }
        return .pass
    }

    /// SHA-256 over the output page's composed characters in CANONICAL
    /// order (J-12 redesign, 2026-06-09). Mirrors
    /// `FilterResult.computeLineageHash` so filter and verifier produce
    /// matching digests in the non-tampered case. Two skip conditions
    /// apply uniformly on both sides:
    ///
    ///   1. Zero-bounds composed characters are skipped — both `extractCharacters`
    ///      and this function exclude characters PDFKit reports with
    ///      `bounds.width <= 0 || bounds.height <= 0`.
    ///   2. Whitespace composed characters are skipped — PDFKit synthesizes
    ///      inter-run whitespace (and the reconstructor draws bridge
    ///      spaces) with non-zero bounds on the output side that the
    ///      filter's surviving `CharacterInfo` set does not contain.
    ///      Skipping whitespace on both sides keeps the hash domain a pure
    ///      content/ordering signal. See N2 residual.
    ///
    /// Canonical order (J-12): units sort by Y sweep band (descending; see
    /// `yBands`/`lineBandTolerance`), then X ascending within a band —
    /// NOT by PDFKit's string order. PDFKit's composition order on
    /// multi-baseline form rows is a layout heuristic the filter side
    /// cannot reproduce (measured on the committed real-document fixture:
    /// the heuristic re-orders same-band columns unpredictably under any
    /// faithful-pitch redraw). The canonical sort anchors both sides to
    /// the drawn geometry itself. Detection power: insertions, deletions,
    /// and replacements still flip the hash; spatially moving a glyph
    /// re-orders the canonical walk and flips it (RT-5); a content-stream
    /// operator shuffle that leaves every glyph at identical coordinates
    /// hashes identically BY DESIGN — same glyphs at same positions is
    /// the same document (position-sorted domain; the raster and Layers
    /// 3/10 cover content channels independently).
    ///
    /// Hash domain: each emitted composed character contributes
    /// `(character.utf8, globalPos)` separated by `0x1F`, where `globalPos`
    /// is a 0-indexed integer counter incremented per emitted character.
    /// See plan §4.4 and ENGINE §6.6 SVT-2.
    static func computeOutputLineageHash(_ outputPage: PDFPage) throws -> Data {
        guard let pageText = outputPage.string else { return Data() }
        let nsText = pageText as NSString
        let totalCodeUnits = outputPage.numberOfCharacters
        guard totalCodeUnits > 0 else { return Data() }

        var units: [(string: String, minY: CGFloat, minX: CGFloat)] = []
        var utf16Offset = 0
        // PERF-8 / CANCEL-002 (VQ-24): banded cooperative cancellation in the
        // composed-character walk, matching the 256-iteration cadence of the
        // other per-character layer loops.
        var bandCounter = 0
        while utf16Offset < totalCodeUnits {
            if bandCounter & 0xFF == 0 { try Task.checkCancellation() }
            bandCounter += 1
            let composedRange = nsText.rangeOfComposedCharacterSequence(
                at: utf16Offset
            )
            defer { utf16Offset += max(composedRange.length, 1) }
            guard let sel = outputPage.selection(for: composedRange) else {
                continue
            }
            let bounds = sel.bounds(for: outputPage)
            guard bounds.width > 0 && bounds.height > 0 else { continue }
            let charString = nsText.substring(with: composedRange)
            guard !FilterResult.isLineageWhitespace(charString) else { continue }
            units.append((charString, bounds.minY, bounds.minX))
        }

        let bands = Self.yBands(units.map(\.minY))
        let order = units.indices.sorted {
            bands[$0] != bands[$1]
                ? bands[$0] < bands[$1]
                : units[$0].minX < units[$1].minX
        }
        var hasher = SHA256()
        let separator = Data([0x1F])
        for (globalPos, idx) in order.enumerated() {
            hasher.update(data: Data(units[idx].string.utf8))
            hasher.update(data: separator)
            hasher.update(data: Data(String(globalPos).utf8))
            hasher.update(data: separator)
        }
        return Data(hasher.finalize())
    }

    // MARK: - Layer 10: Operator Re-Extraction (ENGINE §6.6 SVT-5)

    /// Walk each output page's content stream via `CGPDFScanner` and
    /// accumulate the per-page semantic text decoded from the four
    /// PDF 1.7 §9.4.3 text-show operators (`Tj`, `TJ`, `'`, `"`). Each string
    /// operand is decoded via `CGPDFStringCopyTextString` — an Apple-
    /// maintained string-text decoder independent of PDFKit's `page.string`
    /// (the basis of Layer 3 SVT-3). Reports presence of any sensitive
    /// term in the accumulated bytes via Aho-Corasick.
    ///
    /// Pairs with Layer 3 SVT-3 as a two-decoder cross-check: a sensitive
    /// term surfaced by exactly one of the two layers reports a decoder
    /// divergence (e.g., a Name-object Tj operand surfaced only by the
    /// scanner; a literal-string surrogate-pair surfaced by both decoders).
    /// See plan §4.5 and ENGINE §5C.3 SVT-5.
    ///
    /// Convenience for callers holding a plain term list: every term keeps
    /// substring matching (`requiresTokenBoundary` false), the
    /// pre-`SensitiveTerm` behavior byte for byte. `@_disfavoredOverload` so
    /// an empty-array literal resolves to the `[SensitiveTerm]` overload
    /// instead of being ambiguous; the two are interchangeable when empty.
    @_disfavoredOverload
    public func verifyTextOperatorSemantics(
        outputDocument: SendablePDFDocument,
        sensitiveTerms: [String]
    ) async -> VerificationStatus {
        await verifyTextOperatorSemantics(
            outputDocument: outputDocument,
            sensitiveTerms: sensitiveTerms.map { SensitiveTerm(text: $0) }
        ).status
    }

    /// CC-5-1: receives a SendablePDFDocument. The page walk reads
    /// `pageRef` (non-Sendable); the verification runner calls this layer
    /// on a single executor at a time. Hand-off across the @concurrent
    /// dispatch boundary uses the existing `SendablePDFDocument` wrapper.
    /// Returns (status, pageReferences, reviewTermTexts). `pageReferences`
    /// carries the 0-based page behind an `.attention` verdict for the UI's
    /// tappable page chips; `reviewTermTexts` carries the display-only term
    /// texts behind that verdict (the status message itself stays
    /// content-free, ARCH §12.2). Both nil for every other status.
    public func verifyTextOperatorSemantics(
        outputDocument: SendablePDFDocument,
        sensitiveTerms: [SensitiveTerm]
    ) async -> (status: VerificationStatus, pageReferences: [Int]?, reviewTermTexts: [String]?) {
        // No terms provided — expected for manual-only redaction. VQ-30:
        // INFO, not PASS — the operator-semantic search did not run, and
        // "No issues found" would overstate what this layer observed
        // (mirrors Layer 3's guard).
        guard !sensitiveTerms.isEmpty else {
            return (.info("No sensitive terms were provided — string search did not run."), nil, nil)
        }
        // Filter terms too short to search (matches Layer 3 §6.3, shared
        // `AhoCorasick.isSearchableTerm`): ≥3 scalars (supports 3-letter PII
        // abbreviations like SSN, DOB, PHI) or a 2-character CJK name.
        // VQ-30: the all-short case previously read as a clean PASS here
        // while Layer 3 WARNed — align on Layer 3's tier and copy.
        let validTerms = sensitiveTerms.filter { AhoCorasick.isSearchableTerm($0.text) }
        guard !validTerms.isEmpty else {
            return (.warn("All sensitive terms shorter than 3 characters"), nil, nil)
        }
        // Surfaced on the otherwise-clean path below (mirrors Layer 3).
        let droppedTermCount = sensitiveTerms.count - validTerms.count

        // Boundary-required terms (PD-3) drop matches embedded in an
        // alphanumeric run; plain terms keep substring semantics.
        let termAutomaton = SensitiveTermAutomaton(validTerms: validTerms)
        guard termAutomaton.hasPatterns else { return (.pass, nil, nil) }
        if termAutomaton.isDegraded {
            return (.warn(
                "Operator-semantic term search exceeded size limit — results may be incomplete"
            ), nil, nil)
        }

        let doc = outputDocument.document
        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIdx),
                  let pageRef = page.pageRef else {
                return (.warn(
                    "Operator scanner unavailable for page \(pageIdx + 1)"
                ), nil, nil)
            }

            // Accumulate per-page semantic text bytes. The C callbacks below
            // append decoded UTF-8 bytes plus a 0x1F separator to this Data
            // via the scanner's `info` pointer; @convention(c) callbacks
            // cannot capture Swift context, so the accumulator is the only
            // channel for state across operator hits.
            var accumulator = Data()
            let scanned: Bool = withUnsafeMutablePointer(to: &accumulator) { accPtr in
                guard let table = CGPDFOperatorTableCreate() else { return false }
                defer { CGPDFOperatorTableRelease(table) }

                // PDF 1.7 §9.4.3 Table 107 — text-showing operators:
                //   Tj   operand = string             (pop one object)
                //   '    operand = string             (pop one object)
                //   "    operands = a_w a_c string    (pop one object off top)
                //   TJ   operand = array              (pop array, walk objects)
                //
                // Pop via CGPDFScannerPopObject so a malformed Name operand
                // (e.g., `/SSN Tj`) — invalid under spec but surfaced by a
                // forgiving viewer — is observed alongside well-formed
                // String operands. CGPDFStringCopyTextString is the
                // independent decoder vs. PDFKit's `page.string` (Layer 3
                // SVT-3). nil decodes are tolerated — false negatives are
                // acceptable on a defense-in-depth layer; false positives
                // are not (plan §4.5 traps).
                CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
                    sandwichLayer10AppendPoppedOperand(scanner: scanner, info: info)
                }
                CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
                    sandwichLayer10AppendPoppedOperand(scanner: scanner, info: info)
                }
                CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
                    sandwichLayer10AppendPoppedOperand(scanner: scanner, info: info)
                }
                CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                    var pdfArray: CGPDFArrayRef?
                    guard CGPDFScannerPopArray(scanner, &pdfArray),
                          let arr = pdfArray,
                          let info else { return }
                    let ptr = info.assumingMemoryBound(to: Data.self)
                    let count = CGPDFArrayGetCount(arr)
                    for i in 0..<count {
                        var obj: CGPDFObjectRef?
                        guard CGPDFArrayGetObject(arr, i, &obj),
                              let o = obj else {
                            // Numeric kerning displacements are interleaved
                            // with string/name elements in a TJ array; they
                            // carry no text content and are skipped.
                            continue
                        }
                        sandwichLayer10AppendObjectText(o, into: ptr)
                    }
                }

                let contentStream = CGPDFContentStreamCreateWithPage(pageRef)
                defer { CGPDFContentStreamRelease(contentStream) }
                let scanner = CGPDFScannerCreate(
                    contentStream, table, UnsafeMutableRawPointer(accPtr)
                )
                defer { CGPDFScannerRelease(scanner) }
                return CGPDFScannerScan(scanner)
            }
            if !scanned {
                return (.warn(
                    "Operator scanner could not traverse page \(pageIdx + 1)"
                ), nil, nil)
            }

            // ARCH §12.2: the status message reports page index + match count
            // only; the matched term content is never echoed in it. Mirrors
            // Layer 3 SVT-3's shape at VerificationEngine.runLayer3BinarySearch.
            // The term texts travel beside the status in the display-only
            // third element instead. A hit here is decoded operator text that
            // survives OUTSIDE every region (in-region content is removed
            // from the stream) — residual, user-recoverable via text search
            // → ATTENTION, not FAIL.
            let matches = termAutomaton.tokenFilteredMatches(in: accumulator)
            if !matches.isEmpty {
                // Physical-occurrence count: unique (position, length), so one
                // occurrence never multi-counts across case/encoding variants.
                let count = AhoCorasick.uniqueOccurrenceCount(matches)
                return (.attention(
                    "Text matching your redactions is readable in page \(pageIdx + 1) content "
                    + "(\(count) instance\(count == 1 ? "" : "s"))"
                ), [pageIdx], termAutomaton.matchedTermTexts(matches))
            }
        }
        if droppedTermCount > 0 {
            return (.info(shortTermTail(droppedTermCount)), nil, nil)
        }
        return (.pass, nil, nil)
    }
}

// MARK: - Layer 10 callback helpers
//
// `@convention(c)` callbacks installed via `CGPDFOperatorTableSetCallback`
// cannot capture Swift context. These file-private helpers run inside the
// callback body and operate purely on the scanner ref + the info pointer
// (which the callback site populates with a `&Data` accumulator).

fileprivate func sandwichLayer10AppendPoppedOperand(
    scanner: CGPDFScannerRef,
    info: UnsafeMutableRawPointer?
) {
    var obj: CGPDFObjectRef?
    guard CGPDFScannerPopObject(scanner, &obj),
          let o = obj,
          let info else { return }
    let ptr = info.assumingMemoryBound(to: Data.self)
    sandwichLayer10AppendObjectText(o, into: ptr)
}

fileprivate func sandwichLayer10AppendObjectText(
    _ obj: CGPDFObjectRef,
    into ptr: UnsafeMutablePointer<Data>
) {
    switch CGPDFObjectGetType(obj) {
    case .string:
        var s: CGPDFStringRef?
        let popped = withUnsafeMutablePointer(to: &s) { sPtr in
            CGPDFObjectGetValue(obj, .string, UnsafeMutableRawPointer(sPtr))
        }
        guard popped,
              let str = s,
              let decoded = CGPDFStringCopyTextString(str) else { return }
        ptr.pointee.append(Data((decoded as String).utf8))
        ptr.pointee.append(0x1F)
    case .name:
        // PDF 1.7 §7.3.5: Name objects are UTF-8 byte sequences. A spec-
        // valid `Tj` operand is always a string; observing a Name operand
        // here surfaces a malformed-but-renderable construction that the
        // Layer 3 PDFKit decoder may also surface as glyph-shaped text.
        var cstr: UnsafePointer<Int8>? = nil
        let popped = withUnsafeMutablePointer(to: &cstr) { cPtr in
            CGPDFObjectGetValue(obj, .name, UnsafeMutableRawPointer(cPtr))
        }
        guard popped, let p = cstr else { return }
        ptr.pointee.append(Data(String(cString: p).utf8))
        ptr.pointee.append(0x1F)
    default:
        // Numeric kerning displacements and other non-text operands carry
        // no semantic text content for Layer 10 to surface.
        break
    }
}

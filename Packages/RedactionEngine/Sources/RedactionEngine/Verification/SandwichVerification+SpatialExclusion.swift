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

extension SandwichVerification {
    /// The scan state the three spatial-exclusion techniques share: what
    /// the unit collection gathered, the reading axis derived from it, and
    /// the edge graze the overlap tiers hold for the exit.
    struct SpatialExclusionScan {
        /// Non-whitespace units whose read-back selection is missing or has
        /// no measurable bounds. They cannot be position-checked; counted here
        /// and reported as a WARN on the otherwise-PASS exit instead of being
        /// dropped.
        var zeroBoundsUnits = 0
        /// Non-whitespace units for the exclusion pass, in string order (the
        /// band gate needs the whole page's Y structure before any verdict,
        /// so collection precedes checking; failure order stays first-offset).
        var exclusionUnits: [(bounds: CGRect, utf16Offset: Int,
                              family: String?, pointSize: CGFloat)] = []
        /// Units collected for the origin-delta lattice pass.
        var latticeUnits: [(string: String, bounds: CGRect,
                            family: String, pointSize: CGFloat,
                            utf16Offset: Int)] = []
        /// The axis the text layer's lines run along (a page written from
        /// a `/Rotate 90`/`270` source is drawn along its source lines, so
        /// its lines are vertical runs here). The line bands of both passes
        /// and the lattice's advance direction follow it; on a horizontal
        /// page every step is the unchanged walk.
        var axis: TextAxis = .horizontal
        /// Set on the first edge graze; the graze is held (never returned
        /// from inside the overlap loop) so a later in-region hit on this
        /// page is never masked by it.
        var grazed = false

        /// The band coordinate: a line's position ACROSS the reading axis.
        func across(_ b: CGRect) -> CGFloat { axis.isVertical ? b.minX : b.minY }
    }

    /// Technique 1 — unit collection: one walk over the page text gathering
    /// every non-whitespace unit's read-back bounds and font for the two
    /// passes, and counting the units it could not place.
    static func collectSpatialUnits(
        outputPage: PDFPage, nsText: NSString, count: Int,
        into scan: inout SpatialExclusionScan
    ) throws {
        // 256-iteration band counter in the per-character
        // walk. A 10k-character page would otherwise exceed the 50 ms p95
        // cancel→surrender budget; bitmask check is amortized constant time.
        var bandCounter = 0
        var utf16Offset = 0
        while utf16Offset < count {
            if bandCounter & 0xFF == 0 { try Task.checkCancellation() }
            bandCounter += 1
            let composedRange = nsText.rangeOfComposedCharacterSequence(at: utf16Offset)
            guard let sel = outputPage.selection(for: composedRange) else {
                // No read-back selection at all: as unmeasurable as an empty
                // bounds box — counted, never silently skipped.
                if !SandwichMetrics.isLineageWhitespace(nsText.substring(with: composedRange)) {
                    scan.zeroBoundsUnits += 1
                }
                utf16Offset += max(composedRange.length, 1)
                continue
            }
            let bounds = sel.bounds(for: outputPage)
            guard bounds.width > 0, bounds.height > 0 else {
                if !SandwichMetrics.isLineageWhitespace(nsText.substring(with: composedRange)) {
                    scan.zeroBoundsUnits += 1
                }
                utf16Offset += max(composedRange.length, 1)
                continue
            }

            // Selection bounds are used as-is horizontally. PDFKit's
            // reported bounds are the authoritative position for each
            // character; the exclusion pass below derives its glyph-core
            // boxes from them per unit.
            let charString = nsText.substring(with: composedRange)
            if !SandwichMetrics.isLineageWhitespace(charString) {
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
                scan.exclusionUnits.append((bounds, utf16Offset, family, pointSize))
                if let family {
                    scan.latticeUnits.append((charString, bounds, family,
                                         pointSize, utf16Offset))
                }
            }

            utf16Offset += composedRange.length
        }
    }

    /// Technique 2 — the region-overlap tiers over the collected units'
    /// glyph-core boxes. A core centre inside a region is the FAIL returned;
    /// an edge graze is held on the scan for the exit.
    static func spatialOverlapFailure(
        regionShapes: [RegionShape], scan: inout SpatialExclusionScan, pageIndex: Int
    ) -> VerificationStatus? {
        // Exclusion pass: two tiers over the non-whitespace
        // units' glyph-core boxes. An edge graze (core box crossing a region
        // edge with its center outside) is held as a positional note and
        // returned WARN after the lattice pass below, so a lattice FAIL is
        // never masked by it.
        if !regionShapes.isEmpty, !scan.exclusionUnits.isEmpty {
            var fractionCache: [String: CGFloat] = [:]
            let coreBoxes: [CGRect] = scan.exclusionUnits.map { unit in
                let key = "\(unit.family ?? "-")|\(unit.pointSize)"
                let fraction = fractionCache[key] ?? {
                    let f = SandwichMetrics.descentFraction(
                        family: unit.family, pointSize: unit.pointSize)
                    fractionCache[key] = f
                    return f
                }()
                // The core shrinks the box along the FONT's vertical axis —
                // the page's X on a vertical run. Symmetric, so the centre
                // the FAIL test reads is the same in either frame.
                return scan.axis.isVertical
                    ? unit.bounds.insetBy(dx: fraction * unit.bounds.width, dy: 0)
                    : unit.bounds.insetBy(dx: 0, dy: fraction * unit.bounds.height)
            }
            let unitBands = SandwichMetrics.yBands(coreBoxes.map(scan.across))
            // Union rect per read-back band — the line-band the halo tier
            // gates on (mirror of the filter's per-lineIndex bands).
            var bandRects: [Int: CGRect] = [:]
            for (k, core) in coreBoxes.enumerated() {
                bandRects[unitBands[k]] =
                    bandRects[unitBands[k]].map { $0.union(core) } ?? core
            }
            unitLoop: for (k, unit) in scan.exclusionUnits.enumerated() {
                let core = coreBoxes[k]
                let band = bandRects[unitBands[k]] ?? core
                for shape in regionShapes {
                    // Tier (a) floor at the un-expanded rect; tier (b)
                    // halo at the expanded rect within band-intersecting
                    // lines.
                    let overlaps = core.intersects(shape.bounds)
                        || (core.intersects(shape.expandedBounds)
                            && shape.bounds.intersects(band))
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
                        // graze is held so a later in-region hit on this
                        // page is never masked by it. Messages name the page
                        // and nothing else — the read-back offset is not
                        // user copy.
                        let center = CGPoint(x: core.midX, y: core.midY)
                        if shape.bounds.contains(center) {
                            return .fail(
                                "A character overlaps a redacted area on page \(pageIndex + 1)"
                            )
                        }
                        scan.grazed = true
                        continue unitLoop
                    }
                }
            }
        }
        return nil
    }

    /// Technique 3 — the origin-delta advance lattice over the collected
    /// units, per band in reading order. An off-lattice advance or an
    /// off-pitch size flip is the FAIL returned.
    static func advanceLatticeFailure(
        regionShapes: [RegionShape], scan: SpatialExclusionScan, pageIndex: Int
    ) -> VerificationStatus? {
        // Origin-delta
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
        // tolerance. The natural-advance reference
        // is the accepted family's own CoreText advance — a
        // writer/font property, not a position channel — so encoding-
        // external glyphs (U+2248 at 0.549 em) verify without widening
        // the lattice; TJ kerning injections land off it and still FAIL
        // A point-size change inside a band FAILs: the
        // reconstructor draws each band at one pooled pitch, so a mid-band
        // pitch flip in an accepted family reports output this writer did
        // not produce. Pairs whose gap interval intersects a redaction
        // shape are skipped — the layout hole at a region is the region's
        // own geometry, already visible in the raster.
        if !scan.latticeUnits.isEmpty {
            let bands = SandwichMetrics.yBands(scan.latticeUnits.map { scan.across($0.bounds) })
            // The origin's coordinate ALONG the reading axis, signed so
            // reading order ascends: X on a horizontal line; on a vertical
            // run −Y when the run reads down the page, +Y when up. The
            // consecutive delta along it is the glyph advance the lattice
            // checks, and `prev` is the earlier glyph in reading order
            // whose natural advance the delta is measured against.
            func along(_ b: CGRect) -> CGFloat {
                switch scan.axis {
                case .horizontal: return b.minX
                case .vertical(let downward): return downward ? -b.minY : b.minY
                }
            }
            let order = scan.latticeUnits.indices.sorted {
                bands[$0] != bands[$1]
                    ? bands[$0] < bands[$1]
                    : along(scan.latticeUnits[$0].bounds) < along(scan.latticeUnits[$1].bounds)
            }
            for k in 1..<order.count {
                let prev = scan.latticeUnits[order[k - 1]]
                let curr = scan.latticeUnits[order[k]]
                guard bands[order[k - 1]] == bands[order[k]],
                      Self.isCourierMonospaceFamily(prev.family),
                      Self.isCourierMonospaceFamily(curr.family),
                      prev.pointSize > 0
                else { continue }
                if abs(prev.pointSize - curr.pointSize) > 0.01 {
                    // The writer pools ONE pitch per
                    // SOURCE-Y band, but PDFKit read-back pools adjacent
                    // writer lines into one selection line box, so a
                    // verifier band can legitimately straddle a writer-band
                    // junction and carry two pitches. The junction is
                    // accepted only when BOTH sizes sit on the writer's own
                    // pitch lattice (quantization step, minimum size)
                    // — the grammar no foreign text object follows for free
                    // — and it resets the delta chain: each writer band
                    // re-anchors on its own cell grid, so no cross-pitch
                    // origin relation exists to verify. Positions within
                    // each pitch run stay lattice-pinned; the run-start
                    // origin gains only the freedom every band start
                    // already has. The size class itself is the
                    // accepted bounded-bits channel. Any off-lattice size
                    // flip still reports output this writer did not
                    // produce.
                    if SandwichMetrics.isWriterQuantizedPitch(prev.pointSize),
                       SandwichMetrics.isWriterQuantizedPitch(curr.pointSize) {
                        continue
                    }
                    return .fail(
                        "Non-uniform glyph advance on page \(pageIndex + 1)"
                    )
                }
                let delta = along(curr.bounds) - along(prev.bounds)
                guard delta > 0 else { continue }
                // The interval between the two origins along the axis,
                // spanning the boxes' union across it.
                let gapRect = scan.axis.isVertical
                    ? CGRect(
                        x: min(prev.bounds.minX, curr.bounds.minX),
                        y: min(prev.bounds.minY, curr.bounds.minY),
                        width: max(prev.bounds.maxX, curr.bounds.maxX)
                            - min(prev.bounds.minX, curr.bounds.minX),
                        height: delta)
                    : CGRect(
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
                let cell = SandwichMetrics.courierAdvancePerPoint * prev.pointSize
                let tolerance = SandwichMetrics.advanceWidthTolerancePerPoint * prev.pointSize
                let natural = Self.naturalFamilyAdvance(
                    prev.string, familyName: prev.family,
                    pointSize: prev.pointSize) ?? cell
                let j = max(0, ((delta - natural) / cell).rounded())
                if abs(delta - (natural + j * cell)) > tolerance {
                    return .fail(
                        "Non-uniform glyph advance on page \(pageIndex + 1)"
                    )
                }
            }
        }
        return nil
    }
}

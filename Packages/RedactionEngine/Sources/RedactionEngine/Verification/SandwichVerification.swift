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

// Layers 6–10: Sandwich-specific verification.
// Runs only for Searchable Redaction pages.

/// Sandwich-specific verification layers for the Searchable Redaction pipeline.
/// These layers verify that the invisible text layer is correctly constructed
/// and does not leak redacted content.
struct SandwichVerification: Sendable {

    /// Natural CoreText advance of one composed grapheme in the accepted
    /// family's own font at `pointSize`.
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

    /// Which page axis a text layer's lines run along, read from the
    /// geometry of the page's own read-back.
    ///
    /// The reconstructor draws a page written from a rotated source along
    /// its source lines, so on a `/Rotate 90`/`270` page every drawn line is
    /// a vertical run in the output and consecutive glyphs advance in Y;
    /// on an unrotated or `/Rotate 180` page they advance in X. The
    /// spatial check bands and walks along this axis: banding a vertical
    /// run on Y put every glyph in a band of its own and the origin-delta
    /// lattice checked no pair of it.
    enum TextAxis: Equatable {
        /// Lines run along X — an unrotated page, or one stored with
        /// `/Rotate 180` (mirrored, still horizontal).
        case horizontal
        /// Lines run along Y — a page stored with `/Rotate 90` or `270`.
        /// `downward` says the reading order descends the page (90) rather
        /// than ascends it (270).
        case vertical(downward: Bool)

        var isVertical: Bool {
            if case .vertical = self { return true }
            return false
        }
    }

    /// The axis of a page's text layer from its non-whitespace read-back
    /// boxes in read-back (string) order: vertical when more than half of
    /// the consecutive pairs move further in Y than in X. Within a
    /// horizontal line consecutive glyphs share a baseline (|Δy| ≈ 0), and
    /// a line break moves a whole line width back in X, so an unrotated
    /// page reads horizontal by a wide margin; within a vertical run the
    /// glyphs share an X column and advance in Y by the cell. Fewer than
    /// two boxes read horizontal (nothing to check either way).
    static func readBackAxis(_ boundsInReadBackOrder: [CGRect]) -> TextAxis {
        let n = boundsInReadBackOrder.count
        guard n >= 2 else { return .horizontal }
        var vertical = 0
        var downward = 0
        for k in 1..<n {
            let prev = boundsInReadBackOrder[k - 1], curr = boundsInReadBackOrder[k]
            let dx = curr.minX - prev.minX, dy = curr.minY - prev.minY
            if abs(dy) > abs(dx) {
                vertical += 1
                if dy < 0 { downward += 1 }
            }
        }
        guard vertical * 2 > n - 1 else { return .horizontal }
        return .vertical(downward: downward * 2 >= vertical)
    }

    /// `readBackAxis` over an output page's non-whitespace units with
    /// measurable bounds, in string order; nil when the page has no text
    /// layer or fewer than two such units. The corpus runner records it per
    /// page beside the verdict.
    static func readBackAxis(outputPage: PDFPage) -> TextAxis? {
        guard let pageText = outputPage.string else { return nil }
        let nsText = pageText as NSString
        let count = outputPage.numberOfCharacters
        var boxes: [CGRect] = []
        var offset = 0
        while offset < count {
            let range = nsText.rangeOfComposedCharacterSequence(at: offset)
            offset += max(range.length, 1)
            guard !SandwichMetrics.isLineageWhitespace(nsText.substring(with: range)),
                  let sel = outputPage.selection(for: range) else { continue }
            let bounds = sel.bounds(for: outputPage)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            boxes.append(bounds)
        }
        guard boxes.count >= 2 else { return nil }
        return readBackAxis(boxes)
    }

    public init() {}

    // MARK: - Layer 6: Spatial Exclusion Verification

    /// Verify that no character in the output text layer intersects any
    /// redaction region. This is a geometric re-check independent of string
    /// content — defense-in-depth against character filtering bugs.
    ///
    /// Receives PDFPage (non-Sendable). Safety: verification runner
    /// calls layers sequentially; output PDFDocument is distinct from source.
    ///
    /// IMPORTANT: each `RegionShape`'s bounds must be in PDF page coordinates
    /// (bottom-left origin, in points). Use normalizedToPDFPageCoordinates()
    /// with the OUTPUT page bounds (always zero-origin).
    /// Called from the @concurrent runLayer() context — inherits caller isolation.
    /// Not marked @concurrent itself to avoid PDFPage sending errors.
    ///
    /// Polygon-aware overload. Each `RegionShape` carries the
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
    /// region the drawn ink never touches), Layers 6 and 9's domains already
    /// exclude whitespace, and an invisible space carries no content.
    /// A NON-whitespace unit whose read-back selection has empty bounds has
    /// no measurable position: it is counted and, when the page would
    /// otherwise PASS, reported as a WARN (`zeroBoundsWarning`) rather than
    /// dropped — the check cannot say where that character sits.
    /// Line bands derive from the same `yBands` sweep the Layer 6 lattice
    /// uses, over the core boxes. For a shape whose
    /// `bounds == expandedBounds` (the legacy construction) the two tiers
    /// coincide and the check reduces to its previous single-rect form.
    func verifySpatialExclusion(
        outputPage: PDFPage,
        regionShapes: [RegionShape],
        pageIndex: Int = 0
    ) async throws -> VerificationStatus {
        try await spatialExclusionOutcome(
            outputPage: outputPage, regionShapes: regionShapes, pageIndex: pageIndex
        ).status
    }

    /// The exclusion check with its WARN classification: the
    /// unmeasured-position WARN (`zeroBoundsWarning`) says the check did not
    /// fully run (`couldNotVerify`); the edge-graze WARN is a positional
    /// note (`grazed`). The Layer-6 dispatcher reads the classes and
    /// composes the graze sentence once over every grazed page;
    /// `verifySpatialExclusion` is this page's status alone.
    func spatialExclusionOutcome(
        outputPage: PDFPage,
        regionShapes: [RegionShape],
        pageIndex: Int = 0
    ) async throws -> (status: VerificationStatus, couldNotVerify: Bool, grazed: Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let pageText = outputPage.string else { return (.pass, false, false) }
        let nsText = pageText as NSString
        let count = outputPage.numberOfCharacters
        // Count-only guard. `!regionShapes.isEmpty` was dropped so the
        // The origin-delta lattice (below) also runs on region-less pages —
        // glyph-position tampering on a page with no redaction regions was the
        // only positional blind spot. The per-character exclusion loop is a
        // no-op on [] shapes, and the lattice gap-skip skips no pairs (strictly
        // more pairs validated). The nil-`string` guard above still covers a
        // page with no text layer.
        guard count > 0 else { return (.pass, false, false) }
        var scan = SpatialExclusionScan()
        try Self.collectSpatialUnits(outputPage: outputPage, nsText: nsText, count: count, into: &scan)

        scan.axis = Self.readBackAxis(scan.exclusionUnits.map(\.bounds))

        // The region-overlap tiers, then the advance lattice; a lattice FAIL
        // is never masked by an edge graze, which is held for the exit.
        try Task.checkCancellation()
        if let failure = Self.spatialOverlapFailure(
            regionShapes: regionShapes, scan: &scan, pageIndex: pageIndex) {
            return (failure, false, false)
        }
        try Task.checkCancellation()
        if let failure = Self.advanceLatticeFailure(
            regionShapes: regionShapes, scan: scan, pageIndex: pageIndex) {
            return (failure, false, false)
        }
        if scan.zeroBoundsUnits > 0 {
            // Characters the check could not place — it did not fully run.
            return (Self.zeroBoundsWarning(count: scan.zeroBoundsUnits, pageIndex: pageIndex), true, false)
        }
        if scan.grazed {
            // A positional note (the content is outside the region; the check
            // ran), below the unplaced characters on the same page.
            return (Self.grazeWarning(pages: [pageIndex]), false, true)
        }
        return (.pass, false, false)
    }

    /// WARN copy for the edge-graze class, composed once over every grazed
    /// page: "on page 2" for one page, "on 2 pages: 2, 3" for more.
    /// `pages` are 0-based (the UI chip convention); the copy prints
    /// 1-based numbers. Mechanism only — no read-back offset.
    static func grazeWarning(pages: [Int]) -> VerificationStatus {
        let list = pages.map { String($0 + 1) }.joined(separator: ", ")
        return .warn(
            "A character touches the edge of a redacted area on \(pagePhrase(pages, list: list)). "
            + "Its content is outside the redacted area."
        )
    }

    /// WARN copy for non-whitespace read-back units whose selection bounds
    /// were empty: they had no measurable position and were not
    /// position-checked. Mechanism only; `pageIndex` is 0-based.
    static func zeroBoundsWarning(count: Int, pageIndex: Int) -> VerificationStatus {
        .warn(
            "\(count) character\(count == 1 ? "" : "s") on page \(pageIndex + 1) "
            + "had no measurable position and \(count == 1 ? "was" : "were") not position-checked"
        )
    }

    // MARK: - Layer 7: Character Count Cross-Check

    /// Layer 7 excess tolerance, in composed characters.
    /// With both sides of the comparison counting NON-whitespace only
    /// (below), PDFKit's synthesized inter-run whitespace is out of the
    /// domain and the two counts agree exactly on the sample-statement and
    /// loan-packet fixtures (measured 0 excess on every page). The
    /// prior `max(n/10, 100)` band absorbed a per-line duplicate-character
    /// defect wholesale; a small constant keeps the check sensitive at any
    /// page size while leaving room for a stray decoder divergence.
    static let characterCountExcessTolerance = 2

    /// Compare the number of non-whitespace characters in the output text
    /// layer against the PageFilterDigest from the extraction phase.
    ///
    /// Uses composed-character-sequence iteration (same as extractCharacters)
    /// to count output characters — NOT PDFPage.numberOfCharacters which
    /// uses inconsistent counting for emoji/supplementary-plane.
    /// The count domain is non-whitespace on BOTH sides (mirror of the Layer 9
    /// lineage domain): PDFKit synthesizes inter-run whitespace — and
    /// clamp-reports synthesized separators with non-zero bounds — on the
    /// output side, while the extraction stream legitimately carries
    /// word-spacing whitespace entries; neither view's whitespace exists
    /// in the other.
    ///
    /// A mismatch indicates characters were added or dropped during reconstruction.
    func verifyCharacterCount(
        outputPage: PDFPage,
        digest: PageFilterDigest
    ) async throws -> VerificationStatus {
        // Entry-level cooperative cancellation.
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
    /// iteration, matching extractCharacters()'s unit and the
    /// output lineage walk's two skip conditions (zero bounds, lineage
    /// whitespace — see `computeOutputLineageHash`).
    ///
    /// The nil-selection and zero-bounds skips here are the SAME predicate
    /// `computeOutputLineageHash` applies: Layer 7's count and Layer 9's hash
    /// walk it on both sides of their comparisons, so an unmeasurable unit is
    /// outside both domains by design (the symmetry is the contract, not a
    /// gap). Layer 6 is the layer that counts such units and reports them as
    /// unmeasured (`zeroBoundsWarning`).
    private func countComposedCharacters(_ page: PDFPage) throws -> Int {
        guard let text = page.string else { return 0 }
        let nsText = text as NSString
        let totalCodeUnits = page.numberOfCharacters
        var count = 0
        var utf16Offset = 0
        // 256-iteration band counter in the per-character
        // walk — mirrors verifySpatialExclusion's cancel-checkpoint cadence.
        var bandCounter = 0

        while utf16Offset < totalCodeUnits {
            if bandCounter & 0xFF == 0 { try Task.checkCancellation() }
            bandCounter += 1
            let composedRange = nsText.rangeOfComposedCharacterSequence(at: utf16Offset)
            // Only count characters with non-zero bounds (matching
            // extractCharacters behavior) whose text is not lineage
            // whitespace (the shared Layer 7 / Layer 9 count domain).
            if !SandwichMetrics.isLineageWhitespace(nsText.substring(with: composedRange)),
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

    // MARK: - Layer 8: Font Verification

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
    /// width crosscheck (Layer 6) to gate the check on outputs the
    /// reconstructor itself produces; non-monospace fixtures running through
    /// `verifySpatialExclusion` are reported by Layer 8 instead.
    static func isCourierMonospaceFamily(_ familyName: String) -> Bool {
        let lower = familyName.lowercased()
        return lower.contains("courier") || lower.contains("menlo")
    }

    /// Verify that all fonts in the output PDF are accepted monospace fonts.
    /// No original-document fonts should survive.
    ///
    /// CGPDFContext embeds fonts as TrueType with a random
    /// 6-letter subset prefix (e.g., "AAAAAB+Courier"). Layer 8 matches
    /// against /BaseFont using suffix check.
    func verifyFontsAreMonospace(
        outputPage: PDFPage,
        pageIndex: Int
    ) async throws -> VerificationStatus {
        // Entry-level cooperative cancellation.
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
            // and is UNCHANGED by the refinement below: an unaccepted
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

            // A /ToUnicode
            // CMap is tolerated ONLY on a font the /BaseFont check above
            // accepted (a fresh CGPDFContext Courier/Menlo subset); on any
            // other font dict it remains a structural anomaly and FAILs.
            // A newer writer behavior superseded the original no-CMap attestation: the writer
            // emits a /ToUnicode-bearing subset for any glyph outside its
            // simple 8-bit encoding — under fully explicit, fully covered
            // draws — and that CMap is load-bearing for those glyphs'
            // extraction, so a strict no-CMap rule rejects faithful output
            // (probe F reproduces the real-doc 20/23-page CMap picture with
            // no reconstructor involvement).
            //
            // Preserved-invariant argument:
            // an Apple-writer-emitted CMap on an accepted fresh subset maps
            // only the drawn surviving glyphs — redacted content was
            // filtered before drawing and never embedded, so the CMap
            // cannot carry it. Content/operator leakage is independently
            // covered by Layer 3 and Layer 10. The residual
            // given up — a hand-injected, content-divergent CMap on a
            // spoofed accepted BaseFont — requires post-export tampering,
            // outside the threat boundary (M4 residual).
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

    // MARK: - Layer 9: Character Lineage

    /// Re-compute the SHA-256 over the output page's composed-character
    /// iteration and report mismatch against the filter's recorded
    /// `lineageHash`. Reordering, insertion, deletion, or replacement of
    /// non-zero-bounds composed characters between the filter's surviving
    /// set and the final PDF flips the hash. Zero-width injections do NOT
    /// flip it — both sides iterate non-zero-bounds composed characters
    /// only (skip condition 1 below), so a zero-bounds insertion is outside
    /// the hash domain. That is the pinned M4 residual (adversarial suite
    /// coverage): a term-bearing injection, zero-width or not,
    /// is surfaced by Layers 3 and 10's term scans instead. Spatial
    /// tampering (chars shifted to different page coordinates with
    /// identical content and order) is the responsibility of Layer 6,
    /// which compares raw `selection.bounds` against the redaction shapes
    /// per character.
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
    /// Receives PDFPage (non-Sendable). Safety: verification runner
    /// calls layers sequentially; output PDFDocument is distinct from source.
    func verifyCharacterLineage(
        outputPage: PDFPage,
        digest: PageFilterDigest
    ) async throws -> VerificationStatus {
        // Entry-level cooperative cancellation —
        // Layer 9 previously had none, so a cancel arriving mid-lineage-walk
        // was not honored until the layer completed. The composed-character
        // walk below carries the banded 256-cadence checks (house pattern).
        try Task.checkCancellation()
        // An empty `Data()` means NO lineage recorded (legacy reports,
        // hand-built test digests): nothing to compare, pass. A page whose
        // filter kept no survivor is different — it carries the empty-set
        // digest (`SandwichMetrics.emptyLineageDigest`), which the output walk of a textless
        // page reproduces: 0 expected and 0 found compare equal; 0 expected
        // with any measurable output unit compares unequal and FAILs (an
        // injection).
        guard !digest.lineageHash.isEmpty else { return .pass }

        let outputHash = try Self.computeOutputLineageHash(
            outputPage, pageRotation: digest.pageRotation)
        if outputHash != digest.lineageHash {
            return .fail(
                "Character lineage mismatch on page \(digest.pageIndex + 1)"
            )
        }
        return .pass
    }

    /// SHA-256 over the output page's composed characters in CANONICAL
    /// order. Mirrors
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
    ///      content/ordering signal.
    ///
    /// Canonical order: units sort by Y sweep band (descending; see
    /// `yBands`/`SandwichMetrics.lineBandTolerance`), then X ascending within a band —
    /// NOT by PDFKit's string order. PDFKit's composition order on
    /// multi-baseline form rows is a layout heuristic the filter side
    /// cannot reproduce (measured on the committed real-document fixture:
    /// the heuristic re-orders same-band columns unpredictably under any
    /// faithful-pitch redraw). The canonical sort anchors both sides to
    /// the drawn geometry itself. Detection power: insertions, deletions,
    /// and replacements still flip the hash; spatially moving a glyph
    /// re-orders the canonical walk and flips it; a content-stream
    /// operator shuffle that leaves every glyph at identical coordinates
    /// hashes identically BY DESIGN — same glyphs at same positions is
    /// the same document (position-sorted domain; the raster and Layers
    /// 3/10 cover content channels independently).
    ///
    /// Hash domain: each emitted composed character contributes
    /// `(character.utf8, globalPos)` separated by `0x1F`, where `globalPos`
    /// is a 0-indexed integer counter incremented per emitted character.
    ///
    /// An EMPTY walk — no text layer, no code units, or no measurable
    /// non-whitespace unit — returns `SandwichMetrics.emptyLineageDigest`, the SHA-256 of
    /// zero updates, which is what the filter records for a page whose
    /// survivor set is empty; never `Data()`, which `verifyCharacterLineage`
    /// reads as "no lineage recorded". The nil-selection and zero-bounds
    /// skips below are the same predicate Layer 7's `countComposedCharacters`
    /// applies — the two layers walk one domain on both sides of their
    /// comparisons by design; Layer 6 counts and reports the units they skip.
    ///
    /// `pageRotation` is the source page's `/Rotate` as the digest records
    /// it: on a page written from a rotated source each read-back box is
    /// carried into the SOURCE frame (the output page is zero-origin and
    /// unrotated; its crop size is the displayed size) before the sort, so
    /// the canonical order is read along the source lines — as
    /// `FilterResult.computeLineageHash(over:frame:)` reads it on the
    /// filter side. At 0 the walk is unchanged.
    static func computeOutputLineageHash(
        _ outputPage: PDFPage, pageRotation: Int = 0
    ) throws -> Data {
        guard let pageText = outputPage.string else { return SandwichMetrics.emptyLineageDigest }
        let nsText = pageText as NSString
        let totalCodeUnits = outputPage.numberOfCharacters
        guard totalCodeUnits > 0 else { return SandwichMetrics.emptyLineageDigest }
        let pageBox = outputPage.bounds(for: .cropBox)
        let frame = PageFrame(rotation: pageRotation, displayedSize: pageBox.size)

        var units: [(string: String, minY: CGFloat, minX: CGFloat)] = []
        var utf16Offset = 0
        // Banded cooperative cancellation in the
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
            guard !SandwichMetrics.isLineageWhitespace(charString) else { continue }
            let placed = frame.isUnrotated
                ? bounds
                : frame.sourceRect(bounds.offsetBy(dx: -pageBox.minX, dy: -pageBox.minY))
            units.append((charString, placed.minY, placed.minX))
        }

        let bands = SandwichMetrics.yBands(units.map(\.minY))
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
}

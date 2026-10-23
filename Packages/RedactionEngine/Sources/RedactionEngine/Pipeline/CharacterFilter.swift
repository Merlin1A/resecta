import CoreGraphics
import CryptoKit
import Foundation

// Coordinate conversion and character filtering.
// Security-critical: over-redaction is safe, under-redaction is a breach.

// MARK: - Coordinate Conversion

/// Convert a normalized rectangle (0–1, bottom-left origin) to PDF page
/// coordinates (bottom-left origin, in points).
///
/// Produces coordinates in the page frame defined by `pageRect` — a pure
/// scale-by-size + offset-by-origin that never reads `page.rotation`. The
/// frame is the caller's; production sites pass the zero-origin
/// displayed/effective output page (`effectiveSize` basis — PageRasterizer
/// builds it explicitly, VerificationEngine uses the zero-origin output
/// cropBox), the same frame the character filter and the spatial checks
/// compare in (the canonical coordinate contract). The earlier "un-rotated PDF page space"
/// wording predated the displayed-frame migration and was stale.
///
/// Both coordinate systems use bottom-left origin, so no Y-flip is needed.
/// The conversion scales by page dimensions and offsets by page origin.
///
/// SECURITY NOTE: An incorrect conversion here is a data-leakage vulnerability —
/// characters at redaction boundaries could survive filtering if coordinates
/// are scaled wrong.
public func normalizedToPDFPageCoordinates(
    _ normalizedRect: CGRect,
    pageRect: CGRect  // target output-page frame (zero-origin displayed; see header)
) -> CGRect {
    let clamped = normalizedRect.clampedToNormalized()
    return CGRect(
        x: pageRect.origin.x + clamped.minX * pageRect.width,
        y: pageRect.origin.y + clamped.minY * pageRect.height,
        width: clamped.width * pageRect.width,
        height: clamped.height * pageRect.height
    )
}

// MARK: - Character Filtering

/// Safety margin in PDF points applied to each edge of every redaction rectangle.
/// Absorbs bounding-box imprecision, font descender/ascender overflow, and
/// the PDFSelection workaround's reduced accuracy on iOS 18+.
let safetyMarginPoints: CGFloat = 3.0

/// Result of character filtering. Records counts for testing without
/// logging sensitive data.
struct FilterResult: Sendable {
    public let surviving: [CharacterInfo]
    let totalCharacters: Int
    let excludedCount: Int

    public init(surviving: [CharacterInfo], totalCharacters: Int, excludedCount: Int) {
        self.surviving = surviving
        self.totalCharacters = totalCharacters
        self.excludedCount = excludedCount
    }
}

// MARK: - Region shapes

/// A redaction region in PDF-point-space: the safety-margin-expanded rect
/// the Y-range pre-filter sorts on, and the un-expanded rect.
///
/// `bounds` is the UN-expanded region rect — the unconditional
/// exclusion floor and the line-band gate both test against it, while
/// `expandedBounds` carries the halo tier. A caller that omits `bounds`
/// gets `bounds == expandedBounds`, under which both tiers coincide and
/// the shape behaves as it did before the line-aware split.
struct RegionShape: Sendable {
    let expandedBounds: CGRect
    /// The region's un-expanded rect (no safety margin).
    public let bounds: CGRect

    public init(expandedBounds: CGRect, bounds: CGRect? = nil) {
        self.expandedBounds = expandedBounds
        self.bounds = bounds ?? expandedBounds
    }
}

/// Union rect of the bounds of all characters sharing each `lineIndex` —
/// the per-line band the halo gate tests regions against. Computed
/// once per page per filter call.
private func lineBandRects(_ characters: [CharacterInfo]) -> [Int: CGRect] {
    var bands: [Int: CGRect] = [:]
    for char in characters {
        bands[char.lineIndex] =
            bands[char.lineIndex].map { $0.union(char.bounds) } ?? char.bounds
    }
    return bands
}

/// Filter characters against redaction regions with safety margin.
///
/// Two-tier any-overlap exclusion (line-aware halo). A character is
/// removed iff
///  (a) its bounding box intersects the UN-expanded region rect — the
///      unconditional floor; or
///  (b) its bounding box intersects the safety-margin-expanded rect AND
///      the un-expanded rect intersects the character's LINE BAND (the
///      union of bounds of all characters sharing its `lineIndex`).
/// Character ink lies inside its own line band, so tier (b) is a superset
/// of tier (a) on band-intersecting lines: relative to a 0pt filter this
/// never under-excludes. What the band gate removes is the halo's reach
/// across sub-point line gaps (measured 0.22–0.25pt on tabular fixtures)
/// into lines the region does not touch — the over-removal that blanked
/// neighboring lines and swallowed whole label blocks. Within a
/// region's own lines the halo behaves exactly as before. No
/// partial-overlap threshold. Over-redaction is safe, under-redaction is
/// a breach.
///
/// Uses a Y-range pre-filter: expanded rects are sorted by minY, and for each
/// character we binary-search to find only the rects whose Y-range overlaps.
/// This reduces the inner loop from O(m) to O(log m + k) where k is the
/// number of Y-overlapping rects (typically 1–3). The security invariant
/// (any-overlap exclusion) is preserved — we only narrow the candidate set
/// (the expanded rect contains the un-expanded one) before the same
/// intersects() checks.
///
/// Deterministic, conservative, boundary-safe.
@concurrent
func filterCharacters(
    characters: [CharacterInfo],
    redactionRects: [CGRect],
    safetyMargin: CGFloat = safetyMarginPoints
) async throws -> FilterResult {
    // Expand all redaction rectangles by the safety margin, keeping each
    // paired with its un-expanded source rect (floor + band gate). A uniform
    // margin preserves minY order, so the sort by the un-expanded minY
    // orders the expanded rects the same way.
    let regions = redactionRects.map {
        (expanded: $0.insetBy(dx: -safetyMargin, dy: -safetyMargin), unexpanded: $0)
    }
    return try filterCharactersWalk(
        characters: characters, regions: regions,
        sortKey: { $0.unexpanded.minY },
        expandedBounds: { $0.expanded }, unexpandedBounds: { $0.unexpanded }
    ) { char, region, haloApplies in
        guard char.bounds.intersects(region.expanded) else { return false }
        // Tier (a) — unconditional floor at the un-expanded rect.
        if char.bounds.intersects(region.unexpanded) { return true }
        // Tier (b) — halo, gated on the region touching this
        // character's line band.
        return haloApplies
    }
}

// MARK: - The shared filter walk

/// The walk `filterCharacters` runs: the regions sorted by
/// the caller's key, the Y-range pre-filter (a binary search over the sorted
/// regions' expanded minY against each character's maxY, so the inner loop
/// is O(log m + k) for the k Y-overlapping regions), the per-character
/// cooperative cancellation and the line-band halo gate. The innermost
/// tier test is passed in: it reads the
/// character, the candidate region and whether the halo applies on this
/// character's line, and says whether the character is excluded. Survivors
/// keep their input order; the security invariant (any-overlap exclusion)
/// is the closure's — the walk only narrows the candidate set.
///
/// Per-character cooperative cancellation: the inner body is binary-search
/// bounded, so a check on every iteration is negligible overhead here. The
/// sibling per-character walks (`verifySpatialExclusion`,
/// `TextLayerExtractor`) check once per 256-character band instead, because
/// their per-character bodies cost more.
func filterCharactersWalk<Region>(
    characters: [CharacterInfo],
    regions: [Region],
    sortKey: (Region) -> CGFloat,
    expandedBounds: (Region) -> CGRect,
    unexpandedBounds: (Region) -> CGRect,
    excludes: (_ char: CharacterInfo, _ region: Region, _ haloApplies: Bool) -> Bool
) throws -> FilterResult {
    let sorted = regions.sorted { sortKey($0) < sortKey($1) }
    // Pre-compute minY values for upper-bound search
    let minYValues = sorted.map { expandedBounds($0).minY }

    let lineBands = lineBandRects(characters)
    var surviving: [CharacterInfo] = []
    var excludedCount = 0

    for char in characters {
        try Task.checkCancellation()
        let charMinY = char.bounds.minY
        let charMaxY = char.bounds.maxY

        // Binary search: the last region whose expanded minY <= charMaxY.
        // Any region with minY > charMaxY cannot overlap this character vertically.
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if minYValues[mid] <= charMaxY {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // lo = first index where minY > charMaxY; only check 0..<lo

        var excluded = false
        for j in 0..<lo {
            let region = sorted[j]
            // Skip regions whose maxY is below charMinY (no vertical overlap)
            guard expandedBounds(region).maxY >= charMinY else { continue }
            // Halo gate: the halo tier applies only when the region's
            // un-expanded rect touches this character's line band. The 0pt
            // floor is unconditional. A character always contributes to
            // its own band; a missing band degrades to the halo applying
            // (fail-safe).
            let band = lineBands[char.lineIndex]
            let haloApplies = band == nil || unexpandedBounds(region).intersects(band!)
            if excludes(char, region, haloApplies) {
                excluded = true
                break
            }
        }
        if excluded {
            excludedCount += 1
        } else {
            surviving.append(char)
        }
    }

    return FilterResult(
        surviving: surviving,
        totalCharacters: characters.count,
        excludedCount: excludedCount
    )
}

// MARK: - Edge Distance Calculation

/// Minimum distance from a character bounding box edge to the nearest
/// redaction rectangle edge, in PDF points. Used for boundary character
/// identification in PageFilterDigest.
func minEdgeDistance(_ charBounds: CGRect, to rect: CGRect) -> CGFloat {
    // Compute distance from each edge of charBounds to nearest edge of rect.
    // If they overlap, distance is 0.
    let dx: CGFloat
    if charBounds.maxX < rect.minX {
        dx = rect.minX - charBounds.maxX
    } else if charBounds.minX > rect.maxX {
        dx = charBounds.minX - rect.maxX
    } else {
        dx = 0
    }

    let dy: CGFloat
    if charBounds.maxY < rect.minY {
        dy = rect.minY - charBounds.maxY
    } else if charBounds.minY > rect.maxY {
        dy = charBounds.minY - rect.maxY
    } else {
        dy = 0
    }

    // Chebyshev distance — either axis separation counts
    return max(dx, dy)
}

// MARK: - FilterResult → PageFilterDigest

extension FilterResult {
    /// Compute the lightweight digest for Layer 7 verification.
    /// Call immediately after filtering, then let the full FilterResult
    /// go out of scope to release the surviving array.
    ///
    /// - Parameters:
    ///   - pageIndex: The 0-based page index.
    ///   - redactionRects: Redaction rectangles in PDF-point-space (already converted
    ///     from normalized coordinates via normalizedToPDFPageCoordinates).
    ///   - safetyMargin: The safety margin used during filtering.
    ///   - drawnCellRuleExcludedCount: How many of `excludedCount` the
    ///     writer-side drawn-cell rule dropped after the filter
    ///     (`TextLayerReconstructor.validateSurvivors`); 0 when the rule
    ///     has not run on this result.
    ///   - frame: The page's frame. On a page stored with a rotation the
    ///     lineage hash is taken in the SOURCE frame and the digest records
    ///     the rotation for Layer 9; nil or an unrotated frame is the
    ///     unchanged digest.
    func toDigest(
        pageIndex: Int,
        redactionRects: [CGRect],
        safetyMargin: CGFloat,
        drawnCellRuleExcludedCount: Int = 0,
        frame: PageFrame? = nil
    ) -> PageFilterDigest {
        // Identify boundary characters: surviving characters within safetyMargin * 2
        // of any redaction edge (the "near miss" zone).
        let boundaryChars = surviving.compactMap { char -> BoundaryCharacterInfo? in
            let minDist = redactionRects.map { rect in
                minEdgeDistance(char.bounds, to: rect)
            }.min() ?? .greatestFiniteMagnitude
            guard minDist < safetyMargin * 2 else { return nil }
            return BoundaryCharacterInfo()
        }
        return PageFilterDigest(
            pageIndex: pageIndex,
            extractedCount: totalCharacters,
            excludedCount: excludedCount,
            survivingCount: surviving.count,
            boundaryCharacters: boundaryChars,
            lineageHash: Self.computeLineageHash(over: surviving, frame: frame),
            survivingNonWhitespaceCount: surviving.count(where: {
                !SandwichMetrics.isLineageWhitespace($0.character)
            }),
            drawnCellRuleExcludedCount: drawnCellRuleExcludedCount,
            pageRotation: frame?.rotation ?? 0
        )
    }

    /// `computeLineageHash(over:)` in the page's SOURCE frame: on a page
    /// stored with a rotation the survivors' bounds are carried back through
    /// the inverse of the rotation transform first, so the canonical order
    /// (Y bands, X ascending) is read along the source lines — the frame the
    /// writer assembles in, and the frame Layer 9 carries its read-back
    /// boxes into (`SandwichVerification.computeOutputLineageHash`). In the
    /// displayed frame of a 90°/270° page every source line is a vertical
    /// run and the glyphs' Y values form one near-continuum across lines,
    /// so the two sides' single-linkage bands would not agree there. On an
    /// unrotated page (or with no frame) the hash is unchanged.
    static func computeLineageHash(
        over characters: [CharacterInfo], frame: PageFrame?
    ) -> Data {
        guard let frame, !frame.isUnrotated else {
            return computeLineageHash(over: characters)
        }
        return computeLineageHash(over: characters.map(frame.sourceEntry))
    }

    /// SHA-256 over `(character, globalPos)` for each non-whitespace
    /// composed-character sequence in CANONICAL order (J-12, 2026-06-09):
    /// run groups band by the shared Y sweep (`SandwichMetrics.yBands`),
    /// X ascending within a band — mirroring `computeOutputLineageHash`'s
    /// canonical sort of the output units. PDFKit's string order on
    /// multi-baseline form rows is a layout heuristic no filter-side walk
    /// reproduces (measured, RealDocProbeTests on the committed real
    /// document); anchoring both sides to the drawn geometry makes the
    /// hash independent of the composition heuristic. Each field is
    /// followed by a unit-separator (`0x1F`) so re-encoded boundaries
    /// cannot collide.
    ///
    /// Hash domain (post-H1 redesign): `(character.utf8, globalPos)` where
    /// `globalPos` is a 0-indexed integer counter incremented per emitted
    /// composed sequence. Position fields are intentionally omitted —
    /// Layer 6 owns spatial tampering (raw `selection.bounds`
    /// intersection against the redaction shapes), and Layer 9 owns
    /// content/ordering tampering (insertion / deletion / replacement /
    /// reordering of non-whitespace content). The pre-redesign domain
    /// folded snapped X and Y into the hash, which required filter and
    /// verifier to derive matching floating-point positions across two
    /// independent code paths (source-side bounds vs PDFKit's output-side
    /// bounds); descender glyphs, source-font/Courier descent mismatches,
    /// and PDFKit's synthesized inter-run whitespace all produced
    /// false-positive mismatches on legitimate output.
    ///
    /// Whitespace skip: characters whose `Character.isWhitespace` is true
    /// (space, tab, newline, NBSP, line/paragraph separators, etc.) are
    /// excluded on both sides. PDFKit synthesizes inter-run whitespace on
    /// the output side (text-show operators on different lines emit
    /// `\n`-bearing `page.string` output even when the filter's surviving
    /// set has no newline `CharacterInfo`). Whitespace carries no PII
    /// content; Layer 3 and Layer 10 surface any sensitive-
    /// term overlap. The residual is documented in N2.
    ///
    /// Iteration unit: NSString composed-character-sequence ranges over
    /// `run.text` — matches the verifier's `outputPage.string` iteration
    /// unit. Swift `Character` (grapheme cluster) and NSString composed
    /// sequences diverge on regional-indicator pairs and emoji ZWJ
    /// sequences; the NSString form pins the unit to what PDFKit reports.
    static func computeLineageHash(over characters: [CharacterInfo]) -> Data {
        var hasher = SHA256()
        let separator = Data([0x1F])
        var globalPos = 0
        let groups = TextLayerReconstructor.runMemberGroups(characters)
        let bands = SandwichMetrics.yBands(
            groups.map { characters[$0[0]].bounds.origin.y })
        let order = groups.indices.sorted {
            bands[$0] != bands[$1]
                ? bands[$0] < bands[$1]
                : characters[groups[$0][0]].bounds.minX
                    < characters[groups[$1][0]].bounds.minX
        }
        for gi in order {
            let nsText = groups[gi]
                .map { characters[$0].character }.joined() as NSString
            let total = nsText.length
            var offset = 0
            while offset < total {
                let range = nsText.rangeOfComposedCharacterSequence(at: offset)
                let charString = nsText.substring(with: range)
                offset += max(range.length, 1)
                guard !SandwichMetrics.isLineageWhitespace(charString) else { continue }
                hasher.update(data: Data(charString.utf8))
                hasher.update(data: separator)
                hasher.update(data: Data(String(globalPos).utf8))
                hasher.update(data: separator)
                globalPos += 1
            }
        }
        return Data(hasher.finalize())
    }

}

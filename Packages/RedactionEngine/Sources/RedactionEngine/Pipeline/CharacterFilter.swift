import CoreGraphics
import CryptoKit
import Foundation

// ENGINE §5B.1a, §5B.2 — Coordinate conversion and character filtering.
// Security-critical: over-redaction is safe, under-redaction is a breach.

// MARK: - Coordinate Conversion (ENGINE §5B.1a)

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
/// are scaled wrong. See ENGINE §5B.1a.
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

// MARK: - Character Filtering (ENGINE §5B.2)

/// Safety margin in PDF points applied to each edge of every redaction rectangle.
/// Absorbs bounding-box imprecision, font descender/ascender overflow, and
/// the PDFSelection workaround's reduced accuracy on iOS 18+.
/// See ENGINE §5B.2.
public let safetyMarginPoints: CGFloat = 3.0

/// Result of character filtering. Records counts for testing without
/// logging sensitive data (ARCH §12.2).
public struct FilterResult: Sendable {
    public let surviving: [CharacterInfo]
    public let totalCharacters: Int
    public let excludedCount: Int

    public init(surviving: [CharacterInfo], totalCharacters: Int, excludedCount: Int) {
        self.surviving = surviving
        self.totalCharacters = totalCharacters
        self.excludedCount = excludedCount
    }
}

// MARK: - Polygon Geometry (DRAW-1)

/// A redaction region in PDF-point-space, carrying both the safety-margin-
/// expanded bounding rect and an optional polygon path. The character
/// filter consults the rect for the fast Y-range pre-filter (still O(log m
/// + k)) and falls back to the polygon test only on candidates that pass
/// the bounding-box overlap. Rectangle regions have `polygonVertices ==
/// nil`; polygon regions still carry the bounding rect so the pre-filter
/// works uniformly across both shapes.
///
/// DRAW-1: this is the engine-internal shape consumed by `filterCharacters`.
/// Callers in the coordinator convert `RedactionRegion` to this shape via
/// `RegionShape.fromRegion(_:pageRect:)` so the conversion happens once per
/// page instead of per character.
///
/// PD-7: `bounds` is the UN-expanded region rect — the unconditional
/// exclusion floor and the line-band gate both test against it, while
/// `expandedBounds` carries the halo tier. A caller that omits `bounds`
/// gets `bounds == expandedBounds`, under which both tiers coincide and
/// the shape behaves as it did before the line-aware split.
public struct RegionShape: Sendable {
    public let expandedBounds: CGRect
    public let polygonVertices: [CGPoint]?
    /// The region's un-expanded bounding rect (no safety margin). For
    /// polygon regions this is the polygon's bounding rect.
    public let bounds: CGRect

    public init(expandedBounds: CGRect, polygonVertices: [CGPoint]?,
                bounds: CGRect? = nil) {
        self.expandedBounds = expandedBounds
        self.polygonVertices = polygonVertices
        self.bounds = bounds ?? expandedBounds
    }
}

/// Even-odd point-in-polygon test. Vertices are in the same coordinate
/// system as `point`. Used by `filterCharacters` to confirm overlap when
/// a character bounding box passes the polygon's expanded bounding rect.
///
/// SECURITY: returns `true` if the centre lies inside the polygon. The
/// caller pairs this with the bounding-box pre-filter so a character whose
/// centre is outside the polygon but whose bounds still graze the polygon
/// edge is excluded — over-redaction is safe, under-redaction is a breach.
@inlinable
public func pointInPolygon(_ point: CGPoint, vertices: [CGPoint]) -> Bool {
    guard vertices.count >= 3 else { return false }
    var inside = false
    let n = vertices.count
    var j = n - 1
    for i in 0..<n {
        let vi = vertices[i]
        let vj = vertices[j]
        if (vi.y > point.y) != (vj.y > point.y) {
            let dy = vi.y - vj.y
            if dy != 0 {
                let xIntersect = vj.x + (point.y - vj.y) * (vi.x - vj.x) / dy
                if point.x < xIntersect {
                    inside.toggle()
                }
            }
        }
        j = i
    }
    return inside
}

/// Rect-polygon overlap. True iff the rect either contains any polygon
/// vertex, or any rect corner lies inside the polygon, or any rect edge
/// intersects any polygon edge. Used for the polygon-aware character
/// filter — the rect is the character bounds, the polygon is the
/// safety-margin-expanded redaction.
///
/// SECURITY: keep this conservative. When in doubt, prefer to return
/// `true` (over-redaction is safe; under-redaction is a breach — see
/// ENGINE §5B.2). We do not attempt to detect "polygon strictly contains
/// rect" separately because vertex-in-rect or rect-corner-in-polygon
/// already cover that case for any polygon whose interior touches a rect
/// corner; pathological zero-area characters degrade safely to centre
/// inclusion.
@inlinable
public func rectIntersectsPolygon(_ rect: CGRect, vertices: [CGPoint]) -> Bool {
    guard vertices.count >= 3 else { return false }
    // Fast reject on disjoint bounding rects of the polygon and the rect.
    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    for v in vertices {
        if v.x < minX { minX = v.x }
        if v.x > maxX { maxX = v.x }
        if v.y < minY { minY = v.y }
        if v.y > maxY { maxY = v.y }
    }
    let polyBounds = CGRect(x: minX, y: minY,
                            width: maxX - minX, height: maxY - minY)
    guard rect.intersects(polyBounds) else { return false }

    // Check any vertex inside the rect.
    for v in vertices where rect.contains(v) {
        return true
    }
    // Check any rect corner inside the polygon.
    let corners = [
        CGPoint(x: rect.minX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.minX, y: rect.maxY),
        CGPoint(x: rect.maxX, y: rect.maxY),
    ]
    for c in corners where pointInPolygon(c, vertices: vertices) {
        return true
    }
    // Edge-edge crossings. Standard segment-intersection test.
    let rectEdges: [(CGPoint, CGPoint)] = [
        (corners[0], corners[1]),
        (corners[1], corners[3]),
        (corners[3], corners[2]),
        (corners[2], corners[0]),
    ]
    let n = vertices.count
    var j = n - 1
    for i in 0..<n {
        let polyEdge = (vertices[j], vertices[i])
        for r in rectEdges {
            if segmentsIntersect(polyEdge.0, polyEdge.1, r.0, r.1) {
                return true
            }
        }
        j = i
    }
    return false
}

/// True iff the rect lies entirely inside the polygon: every rect corner is
/// inside, no polygon vertex is inside the rect, and no polygon edge crosses
/// a rect edge (a concave notch cutting through the interior). Used by the
/// verifier's fill-calibration probe to anchor a sample rect in the
/// polygon's interior. Conservative in the OPPOSITE direction from
/// `rectIntersectsPolygon`: when in doubt, return `false` — the caller falls
/// back to a bounding-rect probe whose wrong calibration stays fail-safe
/// (the verifier's outlier/recall floors keep readable ink regardless).
@inlinable
public func rectFullyInsidePolygon(_ rect: CGRect, vertices: [CGPoint]) -> Bool {
    guard vertices.count >= 3 else { return false }
    let corners = [
        CGPoint(x: rect.minX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.minX, y: rect.maxY),
        CGPoint(x: rect.maxX, y: rect.maxY),
    ]
    for c in corners where !pointInPolygon(c, vertices: vertices) {
        return false
    }
    // With all four corners inside, only a vertex inside the rect or an
    // edge-edge crossing can still put part of the rect outside.
    for v in vertices where rect.contains(v) {
        return false
    }
    let rectEdges: [(CGPoint, CGPoint)] = [
        (corners[0], corners[1]),
        (corners[1], corners[3]),
        (corners[3], corners[2]),
        (corners[2], corners[0]),
    ]
    let n = vertices.count
    var j = n - 1
    for i in 0..<n {
        let polyEdge = (vertices[j], vertices[i])
        for r in rectEdges {
            if segmentsIntersect(polyEdge.0, polyEdge.1, r.0, r.1) {
                return false
            }
        }
        j = i
    }
    return true
}

/// Area centroid (shoelace) of a simple polygon, in the vertices' own
/// coordinate system; nil when the signed area is (near-)zero — a degenerate
/// polygon has no interior to anchor a probe in. For a concave polygon the
/// centroid can fall OUTSIDE the interior (a U-shape's notch); callers must
/// pair it with an interior test such as `rectFullyInsidePolygon`.
@inlinable
public func polygonCentroid(_ vertices: [CGPoint]) -> CGPoint? {
    guard vertices.count >= 3 else { return nil }
    var area2: CGFloat = 0
    var cx: CGFloat = 0
    var cy: CGFloat = 0
    var j = vertices.count - 1
    for i in 0..<vertices.count {
        let cross = vertices[j].x * vertices[i].y - vertices[i].x * vertices[j].y
        area2 += cross
        cx += (vertices[j].x + vertices[i].x) * cross
        cy += (vertices[j].y + vertices[i].y) * cross
        j = i
    }
    guard abs(area2) > 1e-9 else { return nil }
    return CGPoint(x: cx / (3 * area2), y: cy / (3 * area2))
}

@inlinable
internal func segmentsIntersect(
    _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint
) -> Bool {
    func orient(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
        (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
    }
    let o1 = orient(a, b, c)
    let o2 = orient(a, b, d)
    let o3 = orient(c, d, a)
    let o4 = orient(c, d, b)
    return (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0)
}

/// Union rect of the bounds of all characters sharing each `lineIndex` —
/// the per-line band the PD-7 halo gate tests regions against. Computed
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
/// Two-tier any-overlap exclusion (PD-7 line-aware halo). A character is
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
/// neighboring lines and swallowed whole label blocks (RC-2). Within a
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
/// ENGINE §5B.2: deterministic, conservative, boundary-safe.
@concurrent
public func filterCharacters(
    characters: [CharacterInfo],
    redactionRects: [CGRect],
    safetyMargin: CGFloat = safetyMarginPoints
) async throws -> FilterResult {
    // Expand all redaction rectangles by the safety margin, keeping each
    // paired with its un-expanded source rect (floor + band gate). A uniform
    // margin preserves minY order, so one sort serves both arrays.
    let order = redactionRects.indices.sorted {
        redactionRects[$0].minY < redactionRects[$1].minY
    }
    let sortedExpanded = order.map {
        redactionRects[$0].insetBy(dx: -safetyMargin, dy: -safetyMargin)
    }
    let sortedUnexpanded = order.map { redactionRects[$0] }
    // Pre-compute minY values for upper-bound search
    let minYValues = sortedExpanded.map(\.minY)

    let lineBands = lineBandRects(characters)
    var surviving: [CharacterInfo] = []
    var excludedCount = 0

    // PERF-8 / CANCEL-004: per-character cooperative cancellation. The inner
    // body is binary-search bounded (O(log m + k)); a per-iteration check is
    // negligible overhead and matches the cancel-checkpoint cadence used by
    // sibling per-character walks (verifySpatialExclusion, TextLayerExtractor).
    for char in characters {
        try Task.checkCancellation()
        let charMinY = char.bounds.minY
        let charMaxY = char.bounds.maxY

        // Binary search: find last rect whose minY <= charMaxY.
        // Any rect with minY > charMaxY cannot overlap this character vertically.
        var lo = 0
        var hi = sortedExpanded.count
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
            let expanded = sortedExpanded[j]
            // Skip rects whose maxY is below charMinY (no vertical overlap)
            guard expanded.maxY >= charMinY else { continue }
            guard char.bounds.intersects(expanded) else { continue }
            // Tier (a) — unconditional floor at the un-expanded rect.
            if char.bounds.intersects(sortedUnexpanded[j]) {
                excluded = true
                break
            }
            // Tier (b) — halo, gated on the region touching this
            // character's line band. A character always contributes to its
            // own band; a missing band degrades to exclusion (fail-safe).
            let band = lineBands[char.lineIndex]
            if band == nil || sortedUnexpanded[j].intersects(band!) {
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

/// DRAW-1 polygon-aware filter. Same security contract as the rectangle
/// overload: the PD-7 two-tier exclusion — an unconditional 0pt floor
/// against the un-expanded shape, plus the safety-margin halo gated on
/// the region's un-expanded rect intersecting the character's line band.
/// The Y-range pre-filter on bounding rects survives — every shape
/// carries its expanded bounding rect, so the `O(log m + k)` pre-filter
/// is identical. For shapes that carry a polygon, `rectIntersectsPolygon`
/// confirms each tier's overlap is not just a corner of the bounding
/// rect; the halo tier keeps the H2 Minkowski char-expansion mechanics.
///
/// ENGINE §5B.2 (DRAW-1 amended): rectangle regions pass through with no
/// behaviour change; polygon regions consult `vertices` for the final
/// intersection. Conservative — when in doubt, exclude.
@concurrent
public func filterCharacters(
    characters: [CharacterInfo],
    regionShapes: [RegionShape]
) async throws -> FilterResult {
    // Sort by expandedBounds.minY for the binary-search pre-filter.
    let sorted = regionShapes.sorted {
        $0.expandedBounds.minY < $1.expandedBounds.minY
    }
    let minYValues = sorted.map(\.expandedBounds.minY)

    let lineBands = lineBandRects(characters)
    var surviving: [CharacterInfo] = []
    var excludedCount = 0

    // PERF-8 / CANCEL-004: per-character cooperative cancellation. See sibling
    // overload above for cadence rationale (binary-search bounded inner body).
    for char in characters {
        try Task.checkCancellation()
        let charMinY = char.bounds.minY
        let charMaxY = char.bounds.maxY

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

        var excluded = false
        for j in 0..<lo {
            let shape = sorted[j]
            guard shape.expandedBounds.maxY >= charMinY else { continue }
            // PD-7 halo gate: the halo tier applies only when the region's
            // un-expanded rect touches this character's line band. The 0pt
            // floor is unconditional. A character always contributes to
            // its own band; a missing band degrades to the halo applying
            // (fail-safe).
            let band = lineBands[char.lineIndex]
            let haloApplies = band == nil || shape.bounds.intersects(band!)
            if let vertices = shape.polygonVertices {
                // Tier (a) — 0pt floor: un-expanded char vs un-expanded
                // polygon (the expanded bounding rect is a cheap pre-gate,
                // a superset of the polygon).
                if char.bounds.intersects(shape.expandedBounds),
                   rectIntersectsPolygon(char.bounds, vertices: vertices) {
                    excluded = true
                    break
                }
                // Tier (b) — halo. Expand the character bounds by
                // safetyMarginPoints (instead of expanding the polygon
                // vertices) so the boundary halo applies uniformly.
                // Minkowski-sum identity: `char ∩ (P ⊕ disk) ≡ (char ⊕ disk) ∩ P`
                // for a symmetric disk (here, the L∞ square of radius
                // safetyMarginPoints). H2 fix — vertices come UN-expanded
                // from PageRasterizer; expanding the char produces the same
                // set of excluded characters a vertex offset would, without
                // the edge-normal / concave-corner pitfalls. See ENGINE §5B.2.
                guard haloApplies else { continue }
                let expandedChar = char.bounds.insetBy(
                    dx: -safetyMarginPoints, dy: -safetyMarginPoints
                )
                guard expandedChar.intersects(shape.expandedBounds) else { continue }
                if rectIntersectsPolygon(expandedChar, vertices: vertices) {
                    excluded = true
                    break
                }
            } else {
                // Rect-only regions have safetyMarginPoints baked into
                // expandedBounds, so both tiers test the un-expanded char
                // (no double halo).
                guard char.bounds.intersects(shape.expandedBounds) else { continue }
                // Tier (a) — unconditional floor at the un-expanded rect.
                if char.bounds.intersects(shape.bounds) {
                    excluded = true
                    break
                }
                // Tier (b) — halo within band-intersecting lines.
                if haloApplies {
                    excluded = true
                    break
                }
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
public func minEdgeDistance(_ charBounds: CGRect, to rect: CGRect) -> CGFloat {
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

// MARK: - FilterResult → PageFilterDigest (ENGINE §5B.2)

extension FilterResult {
    /// Compute the lightweight digest for Layer 7 verification.
    /// Call immediately after filtering, then let the full FilterResult
    /// go out of scope to release the surviving array.
    ///
    /// - Parameters:
    ///   - pageIndex: The 0-based page index.
    ///   - redactionRects: Redaction rectangles in PDF-point-space (already converted
    ///     from normalized coordinates via normalizedToPDFPageCoordinates).
    ///   - safetyMargin: The safety margin used during filtering (§5B.2).
    public func toDigest(
        pageIndex: Int,
        redactionRects: [CGRect],
        safetyMargin: CGFloat
    ) -> PageFilterDigest {
        // Identify boundary characters: surviving characters within safetyMargin * 2
        // of any redaction edge (the "near miss" zone). See ENGINE §5B.2.
        let boundaryChars = surviving.compactMap { char -> BoundaryCharacterInfo? in
            let minDist = redactionRects.map { rect in
                minEdgeDistance(char.bounds, to: rect)
            }.min() ?? .greatestFiniteMagnitude
            guard minDist < safetyMargin * 2 else { return nil }
            return BoundaryCharacterInfo(
                character: char.character,
                bounds: char.bounds,
                distanceToEdge: minDist
            )
        }
        return PageFilterDigest(
            pageIndex: pageIndex,
            extractedCount: totalCharacters,
            excludedCount: excludedCount,
            survivingCount: surviving.count,
            boundaryCharacters: boundaryChars,
            lineageHash: Self.computeLineageHash(over: surviving),
            survivingNonWhitespaceCount: surviving.count(where: {
                !Self.isLineageWhitespace($0.character)
            })
        )
    }

    /// SHA-256 over `(character, globalPos)` for each non-whitespace
    /// composed-character sequence in CANONICAL order (J-12, 2026-06-09):
    /// run groups band by the shared Y sweep (`SandwichVerification.yBands`),
    /// X ascending within a band — mirroring `computeOutputLineageHash`'s
    /// canonical sort of the output units. PDFKit's string order on
    /// multi-baseline form rows is a layout heuristic no filter-side walk
    /// reproduces (measured, RealDocProbeTests S06 on the committed real
    /// document); anchoring both sides to the drawn geometry makes the
    /// hash independent of the composition heuristic. Each field is
    /// followed by a unit-separator (`0x1F`) so re-encoded boundaries
    /// cannot collide. See ENGINE §6.6 SVT-2.
    ///
    /// Hash domain (post-H1 redesign): `(character.utf8, globalPos)` where
    /// `globalPos` is a 0-indexed integer counter incremented per emitted
    /// composed sequence. Position fields are intentionally omitted —
    /// Layer 6 SVT-1 owns spatial tampering (raw `selection.bounds`
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
    /// content; Layer 3 SVT-3 and Layer 10 SVT-5 surface any sensitive-
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
        let bands = SandwichVerification.yBands(
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
                guard !isLineageWhitespace(charString) else { continue }
                hasher.update(data: Data(charString.utf8))
                hasher.update(data: separator)
                hasher.update(data: Data(String(globalPos).utf8))
                hasher.update(data: separator)
                globalPos += 1
            }
        }
        return Data(hasher.finalize())
    }

    /// Whitespace skip predicate shared with `SandwichVerification.computeOutputLineageHash`.
    /// PDFKit's `page.string` synthesizes inter-run whitespace asymmetrically
    /// between the source (`extractCharacters`) and output (reconstructed)
    /// views; skipping whitespace on both sides keeps the hash domain a
    /// content/ordering signal. See ENGINE §6.6 SVT-2 (N2 residual).
    static func isLineageWhitespace(_ charString: String) -> Bool {
        guard !charString.isEmpty else { return true }
        return charString.allSatisfy { $0.isWhitespace }
    }
}

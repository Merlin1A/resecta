import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// VF-02 — polygon-aware Layer-2 classifier and fill calibration.
//
// A polygon region's `normalizedRect` is only its bounding box. Before VF-02
// the classifier treated everything inside the bbox as redacted, so text the
// user deliberately preserved inside bbox-minus-polygon (an L-shape's notch)
// classified as an in-region leak, and the fill-calibration probe averaged
// fill with page background over the mixed bbox interior. These tests pin:
//   1. notch text is OUT of region (classifier), for plain text and terms;
//   2. readable text INSIDE the polygon still classifies in-region (the fix
//      must not weaken real-leak detection);
//   3. rect-only regions are byte-identical to the pre-VF-02 behaviour;
//   4. the calibration probe anchors inside the polygon, with a fail-safe
//      bbox fallback when no interior rect emerges.
@Suite("Polygon-aware Layer 2 (VF-02)")
struct PolygonAwareLayer2Tests {

    // MARK: - Shared fixture geometry (normalized, bottom-left origin)

    /// L-shape: the bbox (0.1,0.1)–(0.9,0.9) minus the top-right quadrant
    /// notch (0.5,0.5)–(0.9,0.9). Counter-clockwise.
    static let lShapeVertices = [
        CGPoint(x: 0.1, y: 0.1),
        CGPoint(x: 0.9, y: 0.1),
        CGPoint(x: 0.9, y: 0.5),
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.5, y: 0.9),
        CGPoint(x: 0.1, y: 0.9),
    ]
    static let lShapeBBox = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    private func region(_ rect: CGRect, vertices: [CGPoint]? = nil) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual, vertices: vertices)
    }

    private func lShapeRegion() -> RedactionRegion {
        region(Self.lShapeBBox, vertices: Self.lShapeVertices)
    }

    private func hit(_ box: CGRect, text: String, confidence: Float = 0.9) -> VerificationEngine.OCRHit {
        VerificationEngine.OCRHit(box: box, wordBoxes: [], text: text, confidence: confidence)
    }

    /// A box wholly inside the notch: full bbox coverage, disjoint from
    /// the polygon.
    static let notchBox = CGRect(x: 0.6, y: 0.6, width: 0.25, height: 0.1)
    /// A box wholly inside the polygon's lower arm.
    static let insidePolygonBox = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1)

    // MARK: - Classifier: preserved text in the notch is OUT of region

    @Test("L-shape: text in bbox-minus-polygon classifies out-of-region, not in-region")
    func notchTextIsOutOfRegion() {
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit(Self.notchBox, text: "PRESERVED LABEL")],
            pageRegions: [lShapeRegion()], sensitiveTerms: [])
        #expect(verdict == .textOutsideRegionsOnly,
                "bbox coverage alone must not pull a notch box in-region; got \(verdict)")
    }

    @Test("L-shape: a term readable in the notch raises the OUT-of-region term signal, never the in-region FAIL")
    func notchTermIsNotAnInRegionFail() {
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit(Self.notchBox, text: "ACME-SECRET")],
            pageRegions: [lShapeRegion()], sensitiveTerms: ["acme-secret"])
        #expect(verdict == .sensitiveTermOutsideRegions)
        #expect(verdict != .sensitiveTermInRegion)
    }

    // MARK: - Classifier: real leaks inside the polygon still surface

    @Test("L-shape: readable text inside the polygon stays in-region (paint miss)")
    func insidePolygonTextStaysInRegion() {
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit(Self.insidePolygonBox, text: "leaked")],
            pageRegions: [lShapeRegion()], sensitiveTerms: [])
        #expect(verdict == .textInRegion)
    }

    @Test("L-shape: a sensitive term inside the polygon still FAILs")
    func insidePolygonTermStillFails() {
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit(Self.insidePolygonBox, text: "ACME-SECRET")],
            pageRegions: [lShapeRegion()], sensitiveTerms: ["acme-secret"])
        #expect(verdict == .sensitiveTermInRegion)
    }

    @Test("L-shape: a box straddling the polygon edge is in-region (intersection, not containment)")
    func straddlingBoxIsInRegion() {
        // Crosses the x = 0.5 polygon edge inside the upper arm; bbox
        // coverage is 1.0 and the polygon intersection holds.
        let straddle = CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.1)
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit(straddle, text: "leaked")],
            pageRegions: [lShapeRegion()], sensitiveTerms: [])
        #expect(verdict == .textInRegion)
    }

    // MARK: - Classifier: rect-only regions are untouched

    @Test("rect region (nil vertices): the notch box stays in-region exactly as before")
    func rectRegionUnchanged() {
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit(Self.notchBox, text: "leaked")],
            pageRegions: [region(Self.lShapeBBox)], sensitiveTerms: [])
        #expect(verdict == .textInRegion)
    }

    @Test("fewer than 3 vertices: region behaves as a rect")
    func degenerateVerticesBehaveAsRect() {
        let twoVertex = region(Self.lShapeBBox,
                               vertices: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)])
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit(Self.notchBox, text: "leaked")],
            pageRegions: [twoVertex], sensitiveTerms: [])
        #expect(verdict == .textInRegion)
    }

    // MARK: - Geometry helpers

    @Test("rectFullyInsidePolygon: interior rect of the lower arm → true")
    func fullyInsideLowerArm() {
        #expect(rectFullyInsidePolygon(CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1),
                                       vertices: Self.lShapeVertices))
    }

    @Test("rectFullyInsidePolygon: rect in the notch → false")
    func notchRectNotInside() {
        #expect(!rectFullyInsidePolygon(Self.notchBox, vertices: Self.lShapeVertices))
    }

    @Test("rectFullyInsidePolygon: rect crossing the notch edge → false")
    func crossingRectNotInside() {
        // All in-bbox, corners at (0.4,0.6)–(0.7,0.7): the left corners are
        // inside the polygon, the right corners are in the notch.
        #expect(!rectFullyInsidePolygon(CGRect(x: 0.4, y: 0.6, width: 0.3, height: 0.1),
                                        vertices: Self.lShapeVertices))
    }

    @Test("rectFullyInsidePolygon: rect containing the whole polygon → false")
    func containingRectNotInside() {
        #expect(!rectFullyInsidePolygon(CGRect(x: 0, y: 0, width: 1, height: 1),
                                        vertices: Self.lShapeVertices))
    }

    @Test("polygonCentroid: unit square → its centre")
    func squareCentroid() throws {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                      CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let c = try #require(polygonCentroid(square))
        #expect(abs(c.x - 0.5) < 1e-9 && abs(c.y - 0.5) < 1e-9)
    }

    @Test("polygonCentroid: collinear (zero-area) vertices → nil")
    func degenerateCentroidIsNil() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)]
        #expect(polygonCentroid(line) == nil)
    }

    // MARK: - Calibration probe selection

    @Test("polygonCalibrationProbe: L-shape yields a probe fully inside the polygon")
    func lShapeProbeIsInterior() throws {
        let probe = try #require(VerificationEngine.polygonCalibrationProbe(
            vertices: Self.lShapeVertices, bbox: Self.lShapeBBox,
            marginX: 0.002, marginY: 0.002))
        #expect(probe.width > 0 && probe.height > 0)
        #expect(rectFullyInsidePolygon(probe, vertices: Self.lShapeVertices))
        // Disjoint from the notch — the probe never samples preserved content.
        #expect(!probe.intersects(CGRect(x: 0.501, y: 0.501, width: 0.398, height: 0.398)))
    }

    @Test("polygonCalibrationProbe: U-shape whose centroid falls in the notch → nil (bbox fallback)")
    func uShapeCentroidInNotchYieldsNil() {
        // Unit-square U: side walls of width 0.2, bottom slab up to y = 0.3;
        // the notch (0.2–0.8) × (0.3–1.0) opens at the top. The area centroid
        // lands at (0.5, ≈0.39) — inside the notch, outside the material.
        let u = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                 CGPoint(x: 1, y: 1), CGPoint(x: 0.8, y: 1),
                 CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.2, y: 0.3),
                 CGPoint(x: 0.2, y: 1), CGPoint(x: 0, y: 1)]
        let probe = VerificationEngine.polygonCalibrationProbe(
            vertices: u, bbox: CGRect(x: 0, y: 0, width: 1, height: 1),
            marginX: 0.002, marginY: 0.002)
        #expect(probe == nil, "no interior probe → caller falls back to the bbox inset")
    }

    // MARK: - calibrateFillColor over a polygon-shaped fill (hand-built BGRA)

    /// Tightly-packed BGRA buffer (bytesPerRow = width·4): black inside the
    /// polygon, white outside. Buffer row 0 is the TOP scanline while the
    /// vertices are normalized bottom-left, so the y-axis flips — the same
    /// convention `calibrateFillColor` itself applies.
    private func polygonFillBuffer(width: Int, height: Int, vertices: [CGPoint]) -> [UInt8] {
        var buf = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let ny = 1 - (CGFloat(row) + 0.5) / CGFloat(height)
            for col in 0..<width {
                let nx = (CGFloat(col) + 0.5) / CGFloat(width)
                if pointInPolygon(CGPoint(x: nx, y: ny), vertices: vertices) {
                    let off = (row * width + col) * 4
                    buf[off + 0] = 0; buf[off + 1] = 0; buf[off + 2] = 0
                }
            }
        }
        return buf
    }

    @Test("calibrateFillColor: polygon probe reads the true fill; the bbox probe reads a mix")
    func polygonCalibrationReadsTrueFill() throws {
        let w = 100, h = 100
        let buf = polygonFillBuffer(width: w, height: h, vertices: Self.lShapeVertices)
        let (withPolygon, bboxOnly) = try buf.withUnsafeBufferPointer {
            let base = try #require($0.baseAddress)
            let a = VerificationEngine.calibrateFillColor(
                region: Self.lShapeBBox, vertices: Self.lShapeVertices,
                rgba: base, width: w, height: h, bytesPerRow: w * 4)
            let b = VerificationEngine.calibrateFillColor(
                region: Self.lShapeBBox,
                rgba: base, width: w, height: h, bytesPerRow: w * 4)
            return (a, b)
        }
        let polygonFill = try #require(withPolygon)
        #expect(max(polygonFill.r, polygonFill.g, polygonFill.b) < 0.05,
                "polygon-anchored probe must read the black bar, got \(polygonFill)")
        // The bbox-inset probe overlaps the white notch, so its average is
        // visibly lighter — the miscalibration VF-02 removes for polygons.
        let bboxFill = try #require(bboxOnly)
        #expect(bboxFill.r > 0.15,
                "bbox probe over the mixed interior reads lighter, got \(bboxFill)")
    }

    @Test("calibrateFillColor: degenerate polygon falls back to the bbox probe (fail-safe)")
    func degeneratePolygonFallsBackToBBox() throws {
        let w = 50, h = 50
        // Solid black page: both probe shapes read the same fill.
        let buf = [UInt8](repeating: 0, count: w * h * 4)
        let line = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.8)]
        let fill = try buf.withUnsafeBufferPointer {
            let base = try #require($0.baseAddress)
            return VerificationEngine.calibrateFillColor(
                region: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), vertices: line,
                rgba: base, width: w, height: h, bytesPerRow: w * 4)
        }
        let f = try #require(fill)
        #expect(max(f.r, f.g, f.b) < 0.05)
    }
}

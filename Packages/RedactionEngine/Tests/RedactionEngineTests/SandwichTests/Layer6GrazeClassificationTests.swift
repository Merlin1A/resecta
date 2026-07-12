import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Layer 6 contract-trip classification: a glyph-core box crossing a region
// edge with its CENTER outside the un-expanded region is a positional edge
// graze (WARN note); a core box whose center lies inside the region is an
// in-region character (FAIL). The graze is held so it never masks a later
// in-region hit or a lattice verdict on the same page.

@Suite("Layer 6 graze-vs-in-region classification")
struct Layer6GrazeClassificationTests {
    private let verifier = SandwichVerification()

    /// First non-whitespace character's read-back bounds on page 0.
    private func firstCharBounds(_ page: PDFPage) throws -> CGRect {
        let sel = try #require(page.selection(for: NSRange(location: 0, length: 1)))
        let bounds = sel.bounds(for: page)
        try #require(bounds.width > 0 && bounds.height > 0)
        return bounds
    }

    @Test("Center inside a region → in-region FAIL with position")
    func centerInsideFails() async throws {
        let data = TestFixtures.textLayerPDF(text: "SECRET CONTENT")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let bounds = try firstCharBounds(page)
        // Region fully containing the first character.
        let region = bounds.insetBy(dx: -2, dy: -2)

        let result = try await verifier.verifySpatialExclusion(
            outputPage: page, redactionRects: [region])
        #expect(result.isFail, "center-inside must FAIL; got \(result)")
        if case .fail(let msg) = result {
            #expect(msg.contains("overlaps a redacted area on page 1 (position"),
                    "got: \(msg)")
        }
    }

    @Test("Core box crossing a region edge, center outside → graze WARN")
    func edgeGrazeWarns() async throws {
        let data = TestFixtures.textLayerPDF(text: "SECRET CONTENT")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let bounds = try firstCharBounds(page)
        // Sliver region overlapping only the left 20% of the character's
        // box — the core box (vertical inset only) crosses the region's
        // right edge while the character's center stays outside.
        let sliver = CGRect(
            x: bounds.minX - 10, y: bounds.minY,
            width: 10 + bounds.width * 0.2, height: bounds.height)

        let result = try await verifier.verifySpatialExclusion(
            outputPage: page, redactionRects: [sliver])
        #expect(result.isWarn, "edge graze must WARN; got \(result)")
        if case .warn(let msg) = result {
            #expect(msg.contains("touches the edge of a redacted area on page 1"),
                    "got: \(msg)")
            #expect(msg.contains("Its content is outside the redacted area."),
                    "got: \(msg)")
            #expect(msg.contains("(position"), "got: \(msg)")
        }
    }

    @Test("A graze never masks a later in-region hit on the same page")
    func grazeDoesNotMaskInRegion() async throws {
        let data = TestFixtures.textLayerPDF(text: "SECRET CONTENT")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let first = try firstCharBounds(page)
        // Graze the first character…
        let sliver = CGRect(
            x: first.minX - 10, y: first.minY,
            width: 10 + first.width * 0.2, height: first.height)
        // …and fully contain the third character.
        let thirdSel = try #require(page.selection(for: NSRange(location: 2, length: 1)))
        let third = thirdSel.bounds(for: page).insetBy(dx: -1, dy: -1)

        let result = try await verifier.verifySpatialExclusion(
            outputPage: page, redactionRects: [sliver, third])
        #expect(result.isFail,
                "in-region hit must win over an earlier graze; got \(result)")
    }

    @Test("No overlap → pass (classification adds no new trips)")
    func noOverlapStillPasses() async throws {
        let data = TestFixtures.textLayerPDF(text: "SECRET CONTENT")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let result = try await verifier.verifySpatialExclusion(
            outputPage: page,
            redactionRects: [CGRect(x: 0, y: 0, width: 20, height: 20)])
        #expect(result == .pass)
    }

    @Test("Layer 6 dispatch folds a page graze to WARN with page references")
    func dispatchFoldsGrazeToWarn() async throws {
        let data = TestFixtures.textLayerPDF(text: "SECRET CONTENT")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let bounds = try firstCharBounds(page)
        let pageBounds = page.bounds(for: .cropBox)
        // Normalized sliver over the left 20% of the first character
        // (normalizedRect is a linear fraction of the zero-origin page).
        let sliverPoints = CGRect(
            x: bounds.minX - 10, y: bounds.minY,
            width: 10 + bounds.width * 0.2, height: bounds.height)
        let normalized = CGRect(
            x: sliverPoints.minX / pageBounds.width,
            y: sliverPoints.minY / pageBounds.height,
            width: sliverPoints.width / pageBounds.width,
            height: sliverPoints.height / pageBounds.height)
        let region = RedactionRegion(
            id: UUID(), normalizedRect: normalized, source: .manual)

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            5, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        #expect(result.status.isWarn,
                "page graze must fold to a WARN note; got \(result.status)")
        #expect(result.pageReferences == [0],
                "graze page must be referenced; got \(String(describing: result.pageReferences))")
    }

    @Test("polygonContainsPoint even-odd matrix")
    func pointInPolygonMatrix() {
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 10)]
        #expect(SandwichVerification.polygonContainsPoint(
            CGPoint(x: 5, y: 3), vertices: triangle))
        #expect(!SandwichVerification.polygonContainsPoint(
            CGPoint(x: 0, y: 9), vertices: triangle))
        #expect(!SandwichVerification.polygonContainsPoint(
            CGPoint(x: 12, y: 1), vertices: triangle))
        // Degenerate input: fewer than 3 vertices contains nothing.
        #expect(!SandwichVerification.polygonContainsPoint(
            CGPoint(x: 1, y: 1),
            vertices: [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 2)]))
    }
}

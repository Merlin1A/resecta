import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Layer 6's layer-level copy: the edge-graze WARN is composed ONCE over
// every grazed page ("on page 2" / "on 2 pages: 2, 3") and its
// `pageReferences` are exactly those pages; the overlap and lattice FAILs
// name the page and nothing else — no read-back offset rides any message.
// The per-page classification itself is `Layer6GrazeClassificationTests`.

@Suite("Layer 6 aggregate copy: graze pages, no offsets")
struct Layer6SpatialAggregateWarnTests {

    /// First non-whitespace character's read-back bounds on a page.
    private func firstCharBounds(_ page: PDFPage) throws -> CGRect {
        let sel = try #require(page.selection(for: NSRange(location: 0, length: 1)))
        let bounds = sel.bounds(for: page)
        try #require(bounds.width > 0 && bounds.height > 0)
        return bounds
    }

    /// A self-contained document of `pageCount` text pages, each the
    /// single-page `textLayerPDF` fixture (re-serialized so no page leans
    /// on a source document that goes away).
    private func textPages(_ pageCount: Int) throws -> PDFDocument {
        let merged = PDFDocument()
        for _ in 0..<pageCount {
            let single = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "SECRET CONTENT")))
            merged.insert(try #require(single.page(at: 0)), at: merged.pageCount)
        }
        let data = try #require(merged.dataRepresentation())
        let doc = try #require(PDFDocument(data: data))
        try #require(doc.pageCount == pageCount)
        return doc
    }

    /// A sliver region over the left 20 % of the page's first character:
    /// the glyph-core box crosses the region's right edge while the
    /// character's center stays outside — the edge-graze shape of
    /// `Layer6GrazeClassificationTests`, normalized for the dispatcher.
    private func grazeRegion(on page: PDFPage) throws -> RedactionRegion {
        let bounds = try firstCharBounds(page)
        let pageBounds = page.bounds(for: .cropBox)
        let sliver = CGRect(
            x: bounds.minX - 10, y: bounds.minY,
            width: 10 + bounds.width * 0.2, height: bounds.height)
        return RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(
                x: sliver.minX / pageBounds.width, y: sliver.minY / pageBounds.height,
                width: sliver.width / pageBounds.width, height: sliver.height / pageBounds.height),
            source: .manual)
    }

    private func runLayer6(_ doc: PDFDocument, regions: [Int: [RedactionRegion]]) async -> LayerResult {
        let engine = VerificationEngine()
        return await engine.runLayer(
            5, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: doc.pageCount, regions: regions, sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: Array(repeating: .searchableRedaction, count: doc.pageCount))
    }

    @Test("One grazed page of two: the singular page phrase, that page referenced")
    func singleGrazedPageComposesWithPagePhraseSingular() async throws {
        let doc = try textPages(2)
        let region = try grazeRegion(on: try #require(doc.page(at: 0)))
        let result = await runLayer6(doc, regions: [0: [region]])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg == "A character touches the edge of a redacted area on page 1. Its content is outside the redacted area.",
                    "got: \(msg)")
        }
        #expect(result.pageReferences == [0], "got \(String(describing: result.pageReferences))")
    }

    @Test("Both pages grazed: one sentence over the two pages, both referenced")
    func twoGrazedPagesComposeWithPagePhrasePlural() async throws {
        let doc = try textPages(2)
        let r0 = try grazeRegion(on: try #require(doc.page(at: 0)))
        let r1 = try grazeRegion(on: try #require(doc.page(at: 1)))
        let result = await runLayer6(doc, regions: [0: [r0], 1: [r1]])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg == "A character touches the edge of a redacted area on 2 pages: 1, 2. Its content is outside the redacted area.",
                    "got: \(msg)")
        }
        #expect(result.pageReferences == [0, 1], "got \(String(describing: result.pageReferences))")
    }

    @Test("An in-region character FAILs with the page alone — no read-back position")
    func overlapFailDropsThePositionOffset() async throws {
        let doc = try textPages(1)
        let page = try #require(doc.page(at: 0))
        let bounds = try firstCharBounds(page)
        let pageBounds = page.bounds(for: .cropBox)
        // A region fully containing the first character (center inside).
        let box = bounds.insetBy(dx: -2, dy: -2)
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(
                x: box.minX / pageBounds.width, y: box.minY / pageBounds.height,
                width: box.width / pageBounds.width, height: box.height / pageBounds.height),
            source: .manual)
        let result = await runLayer6(doc, regions: [0: [region]])
        #expect(result.status.isFail, "got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg == "A character overlaps a redacted area on page 1", "got: \(msg)")
        }
    }

    @Test("A glyph advance off the lattice FAILs with the page alone — no offset")
    func latticeFailDropsTheOffset() async throws {
        // TJ-kerning-tampered Courier on a region-less page: the origin
        // deltas leave the monospace lattice.
        let doc = try #require(PDFDocument(data: TestFixtures.withBlandKerningInjection()))
        let result = await runLayer6(doc, regions: [:])
        #expect(result.status.isFail, "got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg == "Non-uniform glyph advance on page 1", "got: \(msg)")
        }
    }
}

import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The position check reads the page's rectangles from the text path's own
// function, with the run's record: each rectangle has a kind. A character
// centred inside a rectangle of any kind fails the page; the edge note is read
// against the ordinary rectangles only; the spacing test skips a gap that
// crosses an ordinary rectangle or the plan's rectangle, never one that
// crosses only a rectangle under a widened box. The failing test is read
// against every rectangle before any edge is noted.

@Suite("The position check reads the record's rectangles")
struct PositionCheckRecordTests {

    enum Case: String, CaseIterable {
        case plansRectangleNotesNoEdge
        case ordinaryRectangleNotesTheEdge
        case centredInTheWidenedBox
        case ordinaryBesideThePlansRectangle
        case breakAtTheWidenedBox
        case centredInALaterRectangle
        case regionOutsideItsWidenedBox
    }

    @Test("The table holds exactly seven cases")
    func tableLength() {
        #expect(Case.allCases.count == 7)
    }

    @Test("Each case", arguments: Case.allCases)
    func each(_ c: Case) async throws {
        switch c {
        case .plansRectangleNotesNoEdge: try await plansRectangleNotesNoEdge()
        case .ordinaryRectangleNotesTheEdge: try await ordinaryRectangleNotesTheEdge()
        case .centredInTheWidenedBox: try await centredInTheWidenedBox()
        case .ordinaryBesideThePlansRectangle: try await ordinaryBesideThePlansRectangle()
        case .breakAtTheWidenedBox: try await breakAtTheWidenedBox()
        case .centredInALaterRectangle: try await centredInALaterRectangle()
        case .regionOutsideItsWidenedBox: try await regionOutsideItsWidenedBox()
        }
    }

    // MARK: - Pages

    private let verifier = SandwichVerification()

    /// "SECRET CONTENT" in the system font, at 24 pt: not a monospace
    /// family, so the spacing test reads no pair on it.
    static func typedPage() throws -> (doc: PDFDocument, page: PDFPage) {
        let doc = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "SECRET CONTENT")))
        return (doc, try #require(doc.page(at: 0)))
    }

    /// Character `index`'s read-back box, in page points.
    static func box(_ page: PDFPage, _ index: Int) throws -> CGRect {
        let selection = try #require(page.selection(for: NSRange(location: index, length: 1)))
        let bounds = selection.bounds(for: page)
        try #require(bounds.width > 0 && bounds.height > 0, "character \(index) has a box")
        return bounds
    }

    static func shape(_ rect: CGRect) -> RegionShape {
        RegionShape(expandedBounds: rect.insetBy(dx: -safetyMarginPoints, dy: -safetyMarginPoints), bounds: rect)
    }

    /// A rectangle over the right fifth of `b`, stopping half a point short
    /// of its right edge: the character's box crosses its left edge with the
    /// centre outside, and the next character on the line lies within 3 pt
    /// of it and clear of it.
    static func sliver(rightOf b: CGRect) -> CGRect {
        CGRect(x: b.maxX - b.width * 0.2, y: b.minY, width: b.width * 0.2 - 0.5, height: b.height)
    }

    /// The space between "SECRET" and "CONTENT", one point clear of either
    /// word, across the line.
    static func spaceBetweenWords(_ page: PDFPage) throws -> CGRect {
        let t = try box(page, 5), c = try box(page, 7)
        try #require(c.minX - t.maxX > 3, "the space is wider than 3 pt: \(t) \(c)")
        return CGRect(x: t.maxX + 1, y: t.minY, width: c.minX - t.maxX - 2, height: t.height)
    }

    static func normalized(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let p = page.bounds(for: .cropBox)
        return CGRect(x: rect.minX / p.width, y: rect.minY / p.height,
                      width: rect.width / p.width, height: rect.height / p.height)
    }

    static func sixtyFourths(_ rect: CGRect) throws -> PageRect64 {
        try #require(PageRect64(outwardFromPoints: Double(rect.minX), minY: Double(rect.minY),
                                maxX: Double(rect.maxX), maxY: Double(rect.maxY)))
    }

    /// A record of one page with one widened box over `region`, its inner
    /// rectangle `inner` (page points).
    static func record(_ page: PDFPage, region: UUID, inner: CGRect) throws -> RunRecord {
        let p = page.bounds(for: .cropBox)
        let rect = try sixtyFourths(inner)
        let box = PaintedBox(
            regionIDs: [region], inner: rect, paint: rect, tight: rect, limitAbove: nil, limitBelow: nil,
            exposure: .hidden, treatment: .widened, bandMade: true,
            inkEnlargedCovered: false, inkEnlargedToCap: false, asDrawn: false)
        let plan = PaintPlan(widthSixtyFourths: Int(p.width) * 64, heightSixtyFourths: Int(p.height) * 64,
                             boxes: [box])
        let drawn = RunRecord.DrawnRegion(id: region, normalizedRect: .zero)
        return RunRecord(
            confirmed: RunRecord.Confirmed(fillColor: .black, exportDPI: 300, pages: [
                RunRecord.Page(pageIndex: 0, regions: [drawn], plan: plan)]),
            produced: RunRecord.Produced())
    }

    /// The position check through the dispatcher, as a run calls it.
    static func check(_ doc: PDFDocument, regions: [RedactionRegion], record: RunRecord?) async -> VerificationStatus {
        await VerificationEngine().runLayer(
            .spatialVerification, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: doc.pageCount, regions: [0: regions], sensitiveTerms: [],
            pipelineMode: .searchableRedaction, filterDigests: [], perPageModes: [.searchableRedaction],
            record: record).status
    }

    static let inRegion = VerificationStatus.fail("A character overlaps a redacted area on page 1")

    // MARK: - The check

    /// The plan's rectangle: no edge note for a character crossing its edge
    /// or one within 3 pt of it.
    func plansRectangleNotesNoEdge() async throws {
        let (_, page) = try Self.typedPage()
        let rect = Self.sliver(rightOf: try Self.box(page, 0))
        let status = try await verifier.verifySpatialExclusion(
            outputPage: page, regionShapes: [Self.shape(rect)], kinds: [.plansRectangle])
        #expect(status == .pass, "\(status)")
    }

    /// The same rectangle, ordinary: the edge note, as before the record.
    func ordinaryRectangleNotesTheEdge() async throws {
        let (_, page) = try Self.typedPage()
        let rect = Self.sliver(rightOf: try Self.box(page, 0))
        let status = try await verifier.verifySpatialExclusion(
            outputPage: page, regionShapes: [Self.shape(rect)], kinds: [.ordinary])
        #expect(status.isWarn, "\(status)")
        #expect(status == SandwichVerification.grazeWarning(pages: [0]), "\(status)")
    }

    /// Through the dispatcher: a character centred inside the widened box's
    /// inner rectangle and outside its region's own rectangle fails.
    func centredInTheWidenedBox() async throws {
        let (doc, page) = try Self.typedPage()
        let s = try Self.box(page, 0)
        // The region: above the line, more than 3 pt clear of it.
        let own = CGRect(x: s.minX, y: s.maxY + 6, width: s.width, height: 4)
        let region = RedactionRegion(id: UUID(), normalizedRect: Self.normalized(own, on: page), source: .manual)
        let inner = own.union(s.insetBy(dx: -1, dy: -1))
        let record = try Self.record(page, region: region.id, inner: inner)
        let status = await Self.check(doc, regions: [region], record: record)
        #expect(status == Self.inRegion, "\(status)")
    }

    /// One plan's rectangle and one ordinary rectangle: a character within
    /// 3 pt of the ordinary one on its line is noted.
    func ordinaryBesideThePlansRectangle() async throws {
        let (_, page) = try Self.typedPage()
        let plans = Self.sliver(rightOf: try Self.box(page, 0))
        let ordinary = try Self.spaceBetweenWords(page)
        let status = try await verifier.verifySpatialExclusion(
            outputPage: page, regionShapes: [Self.shape(plans), Self.shape(ordinary)],
            kinds: [.plansRectangle, .ordinary])
        #expect(status == SandwichVerification.grazeWarning(pages: [0]), "\(status)")
    }

    /// Courier, 12 pt, at 100 700: "ABCD", a break 18 pt wider than a cell
    /// (two and a half cells, off the grid), then "EFGH".
    static func breakPage() throws -> (doc: PDFDocument, page: PDFPage) {
        let stream = "BT /F1 12 Tf 100 700 Td [(ABCD) -1500 (EFGH)] TJ ET"
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                + "/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
        let doc = try #require(PDFDocument(data: data))
        return (doc, try #require(doc.page(at: 0)))
    }

    /// Through the dispatcher: the line breaks at the widened box's inner
    /// rectangle and not at its region's own rectangle, which sits one point
    /// above the line, in the break; the character before the break is not
    /// one cell wide. With the record the spacing test skips the break at
    /// the inner rectangle; with none, the break is off the grid.
    func breakAtTheWidenedBox() async throws {
        let (doc, page) = try Self.breakPage()
        // The read-back may hold a space PDFKit makes at the break, so the
        // two letters are found by the page's text, not by their place.
        let text = (page.string ?? "") as NSString
        let d = try Self.box(page, text.range(of: "D").location)
        let e = try Self.box(page, text.range(of: "E").location)
        // A read-back box before a hole may take the hole's width, so the
        // inner rectangle starts past the letter's cell and past its centre.
        let start = max(d.minX + 7.2, d.midX) + 0.5
        try #require(e.minX - start > 6, "the break is wider than 6 pt: \(d) \(e)")
        let top = max(d.maxY, e.maxY), bottom = min(d.minY, e.minY)
        let own = CGRect(x: start + 1, y: top + 1, width: e.minX - start - 3, height: 3)
        let region = RedactionRegion(id: UUID(), normalizedRect: Self.normalized(own, on: page), source: .manual)
        let inner = CGRect(x: start, y: bottom, width: e.minX - start - 1, height: own.maxY - bottom)
        let record = try Self.record(page, region: region.id, inner: inner)

        let withRecord = await Self.check(doc, regions: [region], record: record)
        #expect(withRecord == .pass, "with the record: \(withRecord)")
        let withNone = await Self.check(doc, regions: [region], record: nil)
        #expect(withNone == .fail("Non-uniform glyph advance on page 1"), "with no record: \(withNone)")
    }

    /// A character centred inside a rectangle and within 3 pt, on its line,
    /// of a rectangle listed before it fails.
    func centredInALaterRectangle() async throws {
        let (_, page) = try Self.typedPage()
        let earlier = try Self.spaceBetweenWords(page)
        let later = try Self.box(page, 5).insetBy(dx: -0.25, dy: -0.25)
        let status = try await verifier.verifySpatialExclusion(
            outputPage: page, regionShapes: [Self.shape(earlier), Self.shape(later)])
        #expect(status == Self.inRegion, "\(status)")
    }

    /// Through the dispatcher: (a) the inner rectangle stops 2 pt short of
    /// its region on the left, with a character centred in the strip
    /// between; (b) the inner rectangle holds the region and no character
    /// is centred in either; (c) as (b), with a character's box crossing
    /// the region's own edge, its centre outside both.
    func regionOutsideItsWidenedBox() async throws {
        let (doc, page) = try Self.typedPage()

        let e = try Self.box(page, 1)
        let ownA = CGRect(x: e.midX - 1, y: e.minY, width: e.maxX - e.midX + 1, height: e.height)
        let regionA = RedactionRegion(id: UUID(), normalizedRect: Self.normalized(ownA, on: page), source: .manual)
        let innerA = CGRect(x: ownA.minX + 2, y: ownA.minY - 1, width: ownA.width - 2, height: ownA.height + 2)
        let a = await Self.check(doc, regions: [regionA], record: try Self.record(page, region: regionA.id, inner: innerA))
        #expect(a == Self.inRegion, "(a) \(a)")

        let ownB = try Self.spaceBetweenWords(page)
        let regionB = RedactionRegion(id: UUID(), normalizedRect: Self.normalized(ownB, on: page), source: .manual)
        let innerB = ownB.insetBy(dx: 0, dy: -2)
        let b = await Self.check(doc, regions: [regionB], record: try Self.record(page, region: regionB.id, inner: innerB))
        #expect(b == .pass, "(b) \(b)")

        let t = try Self.box(page, 5)
        let ownC = CGRect(x: t.maxX - t.width * 0.2, y: ownB.minY, width: ownB.maxX - (t.maxX - t.width * 0.2), height: ownB.height)
        let regionC = RedactionRegion(id: UUID(), normalizedRect: Self.normalized(ownC, on: page), source: .manual)
        let innerC = ownC.insetBy(dx: 0, dy: -2)
        let c = await Self.check(doc, regions: [regionC], record: try Self.record(page, region: regionC.id, inner: innerC))
        #expect(c == .pass, "(c) \(c)")
    }
}

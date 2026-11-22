import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The coverage check's two blind spots. A re-run that reaches the searcher's
// result cap stops part-way, and a page it never reached reports nothing:
// the pages it did not finish are unread, never passed by silence. And a box
// a search or scan placed speaks only through a match of its own term or
// category: another category's match lying under it neither makes it a
// neighbour's box nor keeps it from reading as drifted.

@Suite("Coverage check: the result cap and a box's own category", .tags(.search))
struct RegionCoverageCapAndCategoryTests {

    /// Two pages: the first holds `dense` occurrences of SEED in small type,
    /// twenty to a line; the second holds one SEED and a line of body text,
    /// so the page reads as a full text layer and is searched as text, not
    /// left for recognition (a page of under ten letters is sparse).
    static func densePageThenOne(dense: Int) -> Data {
        var lines: [String] = []
        var left = dense
        while left > 0 {
            let n = min(20, left)
            lines.append("(" + Array(repeating: "SEED", count: n).joined(separator: " ") + ") Tj T*")
            left -= n
        }
        let first = "BT /F1 6 Tf 7 TL 20 770 Td\n" + lines.joined(separator: "\n") + "\nET"
        let second = "BT /F1 24 Tf 72 700 Td (SEED) Tj ET\nBT /F1 12 Tf 72 600 Td (Second page body) Tj ET"
        func page(_ id: Int, contents: Int) -> PDFObject {
            PDFObject(id: id, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents \(contents) 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """)
        }
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"),
            page(3, contents: 4),
            PDFObject(id: 4, content: "<< /Length \(first.utf8.count) >>\nstream\n\(first)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
            page(6, contents: 7),
            PDFObject(id: 7, content: "<< /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream"),
        ], rootId: 1)
    }

    /// A search box over the left 60 per cent of the second page's SEED.
    private func shortBox(on document: PDFDocument) throws -> RedactionRegion {
        let page = try #require(document.page(at: 1))
        let raw = try #require(page.string)
        let range = (raw as NSString).range(of: "SEED")
        let rect = try #require(DocumentSearcher().boundingRect(for: range, page: page))
        return RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.6, height: rect.height),
            source: .searchMatch(term: "SEED"))
    }

    @Test("A re-run that reaches the result cap leaves the page it stopped on and every later page unread: the box short of its match past the cap is never passed by silence; one result under the cap, the same box is compared and is a shortfall")
    func cappedReRunLeavesLaterPagesUnread() async throws {
        let options = SearchOptions(includeOCR: false)
        let request = TestFixtures.textRequest("SEED", options: options, pages: [1])

        let capped = try #require(PDFDocument(data: Self.densePageThenOne(dense: DocumentSearcher.maxResults)))
        try #require(capped.pageCount == 2)
        let atCap = try await RegionCoverage.check(
            source: SendablePDFDocument(capped), requests: [request], regions: [1: [try shortBox(on: capped)]])
        #expect(atCap.unreadPages == [1], "the page past the cap is unread; got \(atCap.unreadPages)")
        #expect(atCap.shortfalls.isEmpty, "\(atCap.shortfalls)")

        // The first page's matches and the second page's one come to one
        // short of the cap, so the re-run reads both pages whole.
        let under = try #require(PDFDocument(data: Self.densePageThenOne(dense: DocumentSearcher.maxResults - 2)))
        let compared = try await RegionCoverage.check(
            source: SendablePDFDocument(under), requests: [request], regions: [1: [try shortBox(on: under)]])
        #expect(compared.unreadPages.isEmpty, "got \(compared.unreadPages)")
        #expect(compared.shortfalls.count == 1 && compared.shortfalls.first?.pageIndex == 1, "\(compared.shortfalls)")
    }

    private static func match(_ request: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ term: String) -> RegionCoverage.PageMatch {
        RegionCoverage.PageMatch(requestIndex: request, rect: CGRect(x: x, y: y, width: w, height: h), term: term)
    }

    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ source: RedactionRegion.Source) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: x, y: y, width: w, height: h), source: source)
    }

    @Test("A scan's box drifted onto another category's match is still drifted: the address box over the phone line below its address pairs with that address; over a second address it is that address's box; a typed search's box over another term's match pairs with its own term's match")
    func driftedOntoAnotherCategory() {
        let address = Self.match(0, 0.10, 0.80, 0.60, 0.04, PIICategory.address.rawValue)
        let phone = Self.match(0, 0.10, 0.74, 0.30, 0.04, PIICategory.phone.rawValue)
        let drifted = Self.box(0.10, 0.74, 0.60, 0.04, .detectedPII(kind: .address))
        #expect(RegionCoverage.pageShortfalls(page: 0, matches: [address, phone], boxes: [drifted])
                == [RegionCoverage.Shortfall(pageIndex: 0, requestIndex: 0, coveredFraction: 0)])
        let secondAddress = Self.match(0, 0.10, 0.74, 0.30, 0.04, PIICategory.address.rawValue)
        #expect(RegionCoverage.pageShortfalls(page: 0, matches: [address, secondAddress], boxes: [drifted]).isEmpty)

        let name = Self.match(0, 0.10, 0.80, 0.60, 0.04, "Delia")
        let street = Self.match(1, 0.10, 0.74, 0.30, 0.04, "Main St")
        let typed = Self.box(0.10, 0.74, 0.60, 0.04, .searchMatch(term: "Delia"))
        #expect(RegionCoverage.pageShortfalls(page: 0, matches: [name, street], boxes: [typed])
                == [RegionCoverage.Shortfall(pageIndex: 0, requestIndex: 0, coveredFraction: 0)])
    }

    @Test("A box partly over a match is a neighbour's box only through a match of its own category: an address box over half its address and the whole phone number beside it is a shortfall; over a second address it is that address's box; a manual box keeps the neighbour rule")
    func neighbourExcuseOwnCategoryOnly() {
        let address = Self.match(0, 0.10, 0.80, 0.40, 0.04, PIICategory.address.rawValue)
        let phone = Self.match(0, 0.52, 0.80, 0.20, 0.04, PIICategory.phone.rawValue)
        let scanBox = Self.box(0.30, 0.79, 0.44, 0.06, .detectedPII(kind: .address))
        let found = RegionCoverage.pageShortfalls(page: 0, matches: [address, phone], boxes: [scanBox])
        #expect(found.count == 1 && found.first?.requestIndex == 0, "\(found)")
        #expect(abs((found.first?.coveredFraction ?? 0) - 0.5) < 0.03, "\(found)")
        let secondAddress = Self.match(0, 0.52, 0.80, 0.20, 0.04, PIICategory.address.rawValue)
        #expect(RegionCoverage.pageShortfalls(page: 0, matches: [address, secondAddress], boxes: [scanBox]).isEmpty)
        let manual = Self.box(0.30, 0.79, 0.44, 0.06, .manual)
        #expect(RegionCoverage.pageShortfalls(page: 0, matches: [address, phone], boxes: [manual]).isEmpty)
    }
}

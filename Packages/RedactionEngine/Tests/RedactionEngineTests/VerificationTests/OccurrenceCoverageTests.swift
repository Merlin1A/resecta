import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A search match that runs onto a second line is one occurrence: the
// searcher returns one result per line it touches, each with its own rect
// and the same occurrence id. When only one line's box is applied, or one
// of the boxes is removed, the other line's words are printed on the output
// while the re-check on the output reads nothing (the whole phrase no
// longer exists there once half of it is boxed). The coverage check on the
// original pages reads that occurrence as partly covered — a FAIL — rather
// than as a match the user left unselected.
//
// The page is the two-line shape of the fixture library's line-wrap pair
// ("The claimant is Marisol" / "Vance-Oduya and her counsel."), rebuilt
// inline as a raw Courier page.
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.

@Suite("Search Re-check — a match that wraps onto a second line", .tags(.search))
struct OccurrenceCoverageTests {

    static let name = "Marisol Vance-Oduya"

    static let wrappedNamePage = WrappedPhraseRectTests.courierPage(
        "BT /F1 14 Tf 72 700 Td (The claimant is Marisol) Tj ET\nBT /F1 14 Tf 72 683 Td (Vance-Oduya and her counsel.) Tj ET")

    /// The three ways a user searches for the name, as the app records
    /// each applied search.
    static let requests: [(label: String, mode: SearchMode, request: SearchRecheckRequest)] = [
        ("text", .text(name, options: SearchOptions()), TestFixtures.textRequest(name)),
        ("regex", .regex(#"Marisol\s+Vance-Oduya"#, options: SearchOptions()), TestFixtures.regexRequest(#"Marisol\s+Vance-Oduya"#)),
        ("multi-term", .multiTerm([name], options: SearchOptions()), TestFixtures.multiTermRequest([name])),
    ]

    enum Applied: CaseIterable { case firstLine, secondLine, both }

    /// The searcher's line pieces of the wrapped name, top line first.
    static func pieces(_ doc: PDFDocument, mode: SearchMode) async throws -> [SearchResult] {
        var hits: [SearchResult] = []
        for await r in DocumentSearcher().search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) {
            hits.append(r)
        }
        try #require(hits.count == 2, "one result per line the name touches: \(hits.map(\.matchedText))")
        try #require(hits[0].occurrenceID != nil && hits[0].occurrenceID == hits[1].occurrenceID)
        return hits.sorted { $0.normalizedRect.minY > $1.normalizedRect.minY }
    }

    /// The boxes a search places for the chosen pieces: each records the
    /// term the searcher reported.
    static func boxes(_ pieces: [SearchResult], _ applied: Applied) -> [RedactionRegion] {
        let chosen: [SearchResult] = switch applied {
        case .firstLine: [pieces[0]]
        case .secondLine: [pieces[1]]
        case .both: pieces
        }
        return chosen.map { RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .searchMatch(term: $0.term)) }
    }

    /// The Search Re-check over the Searchable output of `regions`, with
    /// the original pages for the coverage check.
    static func recheck(
        _ data: Data, request: SearchRecheckRequest, regions: [RedactionRegion]
    ) async throws -> SearchRecheck.Outcome {
        let source = try #require(PDFDocument(data: data))
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: [0: regions])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try #require(PDFDocument(url: url))
        return try await SearchRecheck().run(
            outputDocument: SendablePDFDocument(output), requests: [request],
            sourceDocument: SendablePDFDocument(source), regions: [0: regions])
    }

    @Test("A wrapped name with one line's box applied FAILS the re-check as partly covered; with both lines boxed it does not",
          arguments: Applied.allCases)
    func oneLineBoxedFails(applied: Applied) async throws {
        let doc = try #require(PDFDocument(data: Self.wrappedNamePage))
        #expect(doc.page(at: 0)?.string == "The claimant is Marisol\nVance-Oduya and her counsel.", "the fixture's two lines")
        for (label, mode, request) in Self.requests {
            let pieces = try await Self.pieces(doc, mode: mode)
            let outcome = try await Self.recheck(Self.wrappedNamePage, request: request, regions: Self.boxes(pieces, applied))
            switch applied {
            case .firstLine, .secondLine:
                #expect(outcome.status == .fail("1 match is only partly covered by its redaction box on page 1"),
                        "\(label), \(applied): got \(outcome.status)")
                #expect(outcome.pageReferences == [0], "\(label), \(applied)")
                #expect(outcome.reviewTermTexts == [request.record.query.displayText], "\(label), \(applied)")
            case .both:
                #expect(!outcome.status.isFail, "\(label): every line boxed — got \(outcome.status)")
            }
        }
    }

    @Test("A hand box completes a search box: covered; a hand box alone vouches for no search: the bare line was left unselected")
    func handBoxes() async throws {
        let data = Self.wrappedNamePage
        let doc = try #require(PDFDocument(data: data))
        let pieces = try await Self.pieces(doc, mode: .text(Self.name, options: SearchOptions()))
        let request = TestFixtures.textRequest(Self.name)
        let first = RedactionRegion(id: UUID(), normalizedRect: pieces[0].normalizedRect, source: .searchMatch(term: pieces[0].term))
        // Both lines boxed, the second by hand: covered, so no shortfall.
        let second = RedactionRegion(id: UUID(), normalizedRect: pieces[1].normalizedRect, source: .manual)
        let covered = try await Self.recheck(data, request: request, regions: [first, second])
        #expect(!covered.status.isFail, "got \(covered.status)")
        // Only the first line boxed, and by hand: no search placed a box for this occurrence.
        let manual = RedactionRegion(id: UUID(), normalizedRect: pieces[0].normalizedRect, source: .manual)
        let unselected = try await Self.recheck(data, request: request, regions: [manual])
        #expect(!unselected.status.isFail, "got \(unselected.status)")
    }

    // MARK: - The pairing rule over hand-built pieces

    private static let upper = CGRect(x: 0.40, y: 0.60, width: 0.12, height: 0.02)
    private static let lower = CGRect(x: 0.10, y: 0.575, width: 0.14, height: 0.02)

    private static func piece(_ rect: CGRect, page: Int = 0, occurrence: UUID?, term: String = name) -> RegionCoverage.PlacedPiece {
        RegionCoverage.PlacedPiece(page: page, match: RegionCoverage.PageMatch(requestIndex: 0, rect: rect, term: term, occurrence: occurrence))
    }

    private static func searchBox(_ rect: CGRect, term: String = name) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .searchMatch(term: term))
    }

    @Test("Two pieces of one occurrence, the first under its search box and the second bare: one shortfall on the bare piece's page; without an occurrence, nothing (left unselected)")
    func onePieceBoxed() {
        let id = UUID()
        let result = RegionCoverage.occurrenceShortfalls(
            pieces: [Self.piece(Self.upper, occurrence: id), Self.piece(Self.lower, occurrence: id)],
            regions: [0: [Self.searchBox(Self.upper)]])
        #expect(result.shortfalls.count == 1 && result.shortfalls.first?.pageIndex == 0, "\(result.shortfalls)")
        #expect(result.settled == [id])
        // Area-weighted over the occurrence: the boxed piece is 12/26 of its area.
        let fraction = result.shortfalls.first?.coveredFraction ?? 0
        #expect(abs(fraction - 12.0 / 26.0) < 0.03, "\(fraction)")
        let none = RegionCoverage.occurrenceShortfalls(
            pieces: [Self.piece(Self.upper, occurrence: nil), Self.piece(Self.lower, occurrence: nil)],
            regions: [0: [Self.searchBox(Self.upper)]])
        #expect(none.shortfalls.isEmpty && none.settled.isEmpty)
    }

    @Test("Both pieces covered: settled, no shortfall; neither touched: not settled, so the pieces stay with the per-page rule (and its drifted-box pairing)")
    func coveredAndUntouched() {
        let id = UUID()
        let pieces = [Self.piece(Self.upper, occurrence: id), Self.piece(Self.lower, occurrence: id)]
        let both = RegionCoverage.occurrenceShortfalls(pieces: pieces, regions: [0: [Self.searchBox(Self.upper), Self.searchBox(Self.lower)]])
        #expect(both.shortfalls.isEmpty && both.settled == [id])
        let drifted = Self.searchBox(CGRect(x: 0.70, y: 0.30, width: 0.12, height: 0.02))
        let neither = RegionCoverage.occurrenceShortfalls(pieces: pieces, regions: [0: [drifted]])
        #expect(neither.shortfalls.isEmpty && neither.settled.isEmpty)
        // The per-page rule still pairs the drifted box with an untouched piece of its term.
        let perPage = RegionCoverage.pageShortfalls(page: 0, matches: pieces.map(\.match), boxes: [drifted])
        #expect(perPage.count == 1, "\(perPage)")
    }

    @Test("Three pieces, one bare: one shortfall; pieces on two pages: one shortfall on the bare piece's page")
    func threePiecesAndTwoPages() {
        let id = UUID()
        let middle = CGRect(x: 0.10, y: 0.55, width: 0.30, height: 0.02)
        let three = RegionCoverage.occurrenceShortfalls(
            pieces: [Self.piece(Self.upper, occurrence: id), Self.piece(middle, occurrence: id), Self.piece(Self.lower.offsetBy(dx: 0, dy: -0.05), occurrence: id)],
            regions: [0: [Self.searchBox(Self.upper), Self.searchBox(middle)]])
        #expect(three.shortfalls.count == 1, "\(three.shortfalls)")
        let seam = UUID()
        let pages = RegionCoverage.occurrenceShortfalls(
            pieces: [Self.piece(CGRect(x: 0.40, y: 0.05, width: 0.12, height: 0.02), page: 2, occurrence: seam),
                     Self.piece(CGRect(x: 0.10, y: 0.92, width: 0.14, height: 0.02), page: 3, occurrence: seam)],
            regions: [2: [Self.searchBox(CGRect(x: 0.40, y: 0.05, width: 0.12, height: 0.02))]])
        #expect(pages.shortfalls.map(\.pageIndex) == [3], "\(pages.shortfalls)")
    }

    @Test("A hand box never vouches for a search occurrence; a box placed for another term neither")
    func handAndOtherTermBoxes() {
        let id = UUID()
        let pieces = [Self.piece(Self.upper, occurrence: id), Self.piece(Self.lower, occurrence: id)]
        let hand = RedactionRegion(id: UUID(), normalizedRect: Self.upper, source: .manual)
        let byHand = RegionCoverage.occurrenceShortfalls(pieces: pieces, regions: [0: [hand]])
        #expect(byHand.shortfalls.isEmpty && byHand.settled.isEmpty)
        let other = RegionCoverage.occurrenceShortfalls(pieces: pieces, regions: [0: [Self.searchBox(Self.upper, term: "OTHER")]])
        #expect(other.shortfalls.isEmpty && other.settled.isEmpty)
    }

    @Test("A neighbour's box grazing the bare piece: still one shortfall; and a box over a settled piece is never read as drifted by the per-page rule")
    func grazingAndSettledPieces() {
        let id = UUID()
        let pieces = [Self.piece(Self.upper, occurrence: id), Self.piece(Self.lower, occurrence: id)]
        let neighbour = Self.searchBox(CGRect(x: 0.23, y: 0.575, width: 0.20, height: 0.02), term: "OTHER")
        let grazed = RegionCoverage.occurrenceShortfalls(pieces: pieces, regions: [0: [Self.searchBox(Self.upper), neighbour]])
        #expect(grazed.shortfalls.count == 1, "\(grazed.shortfalls)")
        // The page also carries another match of the name, left unselected. With the occurrence settled, the
        // box over its first piece touches a settled match, so it is not a drifted box vouching for that match.
        let elsewhere = RegionCoverage.PageMatch(requestIndex: 0, rect: CGRect(x: 0.10, y: 0.30, width: 0.26, height: 0.02), term: Self.name)
        let settled = RegionCoverage.pageShortfalls(page: 0, matches: [elsewhere], boxes: [Self.searchBox(Self.upper)], settled: pieces.map(\.match))
        #expect(settled.isEmpty, "\(settled)")
    }
}

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
}

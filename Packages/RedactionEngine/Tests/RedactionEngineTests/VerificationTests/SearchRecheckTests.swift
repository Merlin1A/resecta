import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The Search Re-check layer on text-layer output (packet §4.1 rows). The
// fixture IS the output: a page WITHOUT the term stands for a full apply
// (0 remaining), a page WITH it for a partial apply. Statuses are content-
// free; query texts ride only `reviewTermTexts` / `queryLines`.

@Suite("Search Re-check (text layer)")
struct SearchRecheckTests {

    private func output(_ pages: [String]) throws -> SendablePDFDocument {
        let doc = try #require(PDFDocument(data: TestFixtures.textPagesPDF(pages)))
        return SendablePDFDocument(doc)
    }

    // MARK: - Statuses

    @Test("Zero applied searches → INFO with the ruled string, never skipped")
    func zeroSearchesIsInfo() async throws {
        let result = await TestFixtures.recheck(try output(["Delia R. Hartwell"]), requests: [])
        #expect(result.status == .info(""))
        #expect(!result.status.isSkipped)
        #expect(TestFixtures.message(of: result.status) == SearchRecheck.infoMessage)
        #expect(result.shortDescription == SearchRecheck.infoMessage)
        #expect(result.name == "Search Re-check")
        #expect(result.layer == .searchRecheck)
        #expect(result.queryLines == nil)
        #expect(result.reviewTermTexts == nil)
        #expect(result.pageReferences == nil)
        // The aggregate treats the idle re-check as a note, not a skip.
        #expect(VerificationEngine().aggregateStatus([LayerResult.mock(status: .pass), result]) == .pass)
    }

    @Test("Full apply: the term is gone from the output → PASS with the layer's own copy")
    func fullApplyPasses() async throws {
        let result = await TestFixtures.recheck(
            try output(["Statement of account for the period"]),
            requests: [TestFixtures.textRequest("Delia", found: 2, applied: 2)])
        #expect(result.status == .pass)
        #expect(result.shortDescription == "Re-ran 1 search on the output — no remaining matches in the text the app can read.")
        #expect(result.detailDescription == "\(SearchRecheck.detailLead) Text was read from the output's text layer.")
        #expect(result.pageReferences == nil)
        #expect(result.reviewTermTexts == nil)
        let line = try #require(result.queryLines?.first)
        #expect(line.label == "\u{201C}Delia\u{201D}")
        #expect(line.foundCount == 2)
        #expect(line.appliedCount == 2)
        #expect(line.remainingCount == 0)
        #expect(line.route == .textLayer)
        #expect(line.optionBadges.isEmpty)
        #expect(line.perTerm == nil)
    }

    @Test("Two searches, both fully applied → PASS pluralizes")
    func twoSearchesPass() async throws {
        let result = await TestFixtures.recheck(
            try output(["nothing to see"]),
            requests: [TestFixtures.textRequest("Delia"), TestFixtures.textRequest("Hartwell")])
        #expect(result.status == .pass)
        #expect(result.shortDescription == "Re-ran 2 searches on the output — no remaining matches in the text the app can read.")
        #expect(result.queryLines?.count == 2)
    }

    @Test("Partial apply: one occurrence survives → ATTENTION, page chip, display-only term")
    func partialApplyAttention() async throws {
        let result = await TestFixtures.recheck(
            try output(["Delia R. Hartwell remains here"]),
            requests: [TestFixtures.textRequest("Delia", found: 2, applied: 1)])
        #expect(result.status == .attention(""))
        let message = try #require(TestFixtures.message(of: result.status))
        #expect(message == "Re-ran 1 search — 1 match remains on page 1")
        #expect(!message.contains("Delia"), "status messages are content-free")
        #expect(result.shortDescription == message)
        #expect(result.detailDescription == "\(SearchRecheck.detailLead) Text was read from the output's text layer. 1 match remains on page 1.")
        #expect(result.pageReferences == [0])
        #expect(result.reviewTermTexts == ["Delia"])
        let line = try #require(result.queryLines?.first)
        #expect(line.remainingCount == 1)
        #expect(line.appliedCount == 1)
        #expect(line.foundCount == 2)
    }

    @Test("Remaining matches across pages list every page ascending; only the affected query is named")
    func multiPageAttention() async throws {
        let result = await TestFixtures.recheck(
            try output(["Delia on one", "clean page", "Delia on three, Delia again"]),
            requests: [TestFixtures.textRequest("Delia"), TestFixtures.textRequest("Hartwell")])
        #expect(result.status == .attention(""))
        #expect(TestFixtures.message(of: result.status) == "Re-ran 2 searches — 3 matches remain on 2 pages: 1, 3")
        #expect(result.pageReferences == [0, 2])
        #expect(result.reviewTermTexts == ["Delia"])
        #expect(result.queryLines?.map(\.remainingCount) == [3, 0])
    }

    // MARK: - Options follow the user's search

    @Test("caseSensitive: 'Delia' misses the upper-case ACH form; the default counts both")
    func caseSensitivity() async throws {
        let out = try output(["Delia R. Hartwell · ACH DELIA HARTWELL"])
        let sensitive = await TestFixtures.recheck(
            out, requests: [TestFixtures.textRequest("Delia", options: SearchOptions(caseSensitive: true))])
        #expect(sensitive.queryLines?.first?.remainingCount == 1)
        #expect(sensitive.queryLines?.first?.optionBadges == ["case-sensitive"])
        let insensitive = await TestFixtures.recheck(out, requests: [TestFixtures.textRequest("Delia")])
        #expect(insensitive.queryLines?.first?.remainingCount == 2)
    }

    @Test("wholeWord: 'Delia' misses 'Delias'; the default counts it")
    func wholeWord() async throws {
        let out = try output(["Delia and the Delias"])
        let whole = await TestFixtures.recheck(
            out, requests: [TestFixtures.textRequest("Delia", options: SearchOptions(wholeWord: true))])
        #expect(whole.queryLines?.first?.remainingCount == 1)
        #expect(whole.queryLines?.first?.optionBadges == ["whole word"])
        let loose = await TestFixtures.recheck(out, requests: [TestFixtures.textRequest("Delia")])
        #expect(loose.queryLines?.first?.remainingCount == 2)
    }

    @Test("regex: the pattern's live count, no literal-string fallback")
    func regexCounts() async throws {
        let pattern = #"\d{3}-\d{2}-\d{4}"#
        let withSSN = try #require(PDFDocument(data: TestFixtures.documentWithPII(terms: ["Delia"])))
        let hit = await TestFixtures.recheck(
            SendablePDFDocument(withSSN), requests: [TestFixtures.regexRequest(pattern)])
        #expect(hit.status == .attention(""))
        #expect(hit.queryLines?.first?.remainingCount == 1)
        #expect(hit.queryLines?.first?.label == "\u{201C}\(pattern)\u{201D}")
        #expect(hit.reviewTermTexts == [pattern])
        let clean = await TestFixtures.recheck(
            try output(["no digit groups here 12345"]), requests: [TestFixtures.regexRequest(pattern)])
        #expect(clean.status == .pass)
        #expect(clean.queryLines?.first?.remainingCount == 0)
    }

    @Test("multiTerm OR counts both terms; AND counts only pages carrying every term")
    func multiTermConjunction() async throws {
        let out = try output(["Delia and Hartwell together", "Delia alone"])
        let or = await TestFixtures.recheck(out, requests: [TestFixtures.multiTermRequest(["Delia", "Hartwell"])])
        #expect(or.queryLines?.first?.remainingCount == 3)
        #expect(or.queryLines?.first?.label == "Delia, Hartwell")
        #expect(or.queryLines?.first?.perTerm?.map(\.remaining) == [2, 1])
        #expect(or.reviewTermTexts == ["Delia, Hartwell"])
        let and = await TestFixtures.recheck(
            out, requests: [TestFixtures.multiTermRequest(["Delia", "Hartwell"], options: SearchOptions(multiTermConjunction: true))])
        #expect(and.queryLines?.first?.remainingCount == 2)
        #expect(and.pageReferences == [0])
    }

    @Test("multiTerm label names at most three terms then +K")
    func multiTermLabel() {
        let query = AppliedSearchQuery(kind: .multiTerm(["a", "b", "c", "d", "e"]), options: SearchOptions())
        #expect(query.displayText == "a, b, c +2")
        #expect(query.displayLabel == "a, b, c +2")
        let three = AppliedSearchQuery(kind: .multiTerm(["a", "b", "c"]), options: SearchOptions())
        #expect(three.displayLabel == "a, b, c")
        #expect(query.optionBadges.isEmpty)
        let both = AppliedSearchQuery(kind: .text("x"), options: SearchOptions(caseSensitive: true, wholeWord: true))
        #expect(both.optionBadges == ["case-sensitive", "whole word"])
    }

    @Test("Ligature and fullwidth residue is located (search-path normalization parity)")
    func ligatureAndFullwidthResidue() async throws {
        let ligature = await TestFixtures.recheck(
            try output(["Main o\u{FB03}ce address"]), requests: [TestFixtures.textRequest("office")])
        #expect(ligature.queryLines?.first?.remainingCount ?? 0 >= 1, "ffi-ligature spelling must be located")
        let fullwidth = await TestFixtures.recheck(
            try output(["Main \u{FF4F}\u{FF46}\u{FF46}\u{FF49}\u{FF43}\u{FF45} address"]),
            requests: [TestFixtures.textRequest("office")])
        #expect(fullwidth.queryLines?.first?.remainingCount ?? 0 >= 1, "fullwidth spelling must be located")
    }

    // MARK: - Coverage honesty

    @Test("A page tree naming a missing kid still verifies: PDFKit repairs it and both text pages count")
    func brokenPageTreeStillVerifies() async throws {
        // PDFKit (iOS 26.4) repairs the missing kid into an openable blank
        // page, so no raw fixture reaches the searcher's `page(at:) == nil`
        // branch; the unopenable arm's copy is pinned by `foldUnopenablePage`.
        // This pins the page walk's resilience: every real page is counted.
        let doc = try #require(PDFDocument(data: TestFixtures.brokenSecondPagePDF(term: "Delia")))
        let result = await TestFixtures.recheck(SendablePDFDocument(doc), requests: [TestFixtures.textRequest("Delia")])
        #expect(result.status == .attention(""))
        #expect(result.queryLines?.first?.remainingCount == 2)
        #expect(result.pageReferences?.count == 2)
        #expect(result.pageReferences?.first == 0)
    }

    @Test("pageBound: honored only when the original run was complete; default off")
    func pageBoundOptIn() async throws {
        let out = try output(["clean", "Delia survives on page 2"])
        // Default: every page → the survivor is found.
        let full = await TestFixtures.recheck(out, requests: [TestFixtures.textRequest("Delia", pages: [0])])
        #expect(full.queryLines?.first?.remainingCount == 1)
        // Bound to page 1 only, sound record → page 2 is not read.
        let bound = await TestFixtures.recheck(out, requests: [TestFixtures.textRequest("Delia", pages: [0], pageBound: true)])
        #expect(bound.status == .pass)
        #expect(bound.queryLines?.first?.remainingCount == 0)
        // Bound requested on an incomplete original run → full re-search.
        let unsound = SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .text("Delia"), options: SearchOptions()),
                foundCount: 1, foundHitCap: true),
            appliedCount: 1, appliedPages: [0], pageBound: true)
        #expect(!unsound.pageBoundIsSound)
        #expect(!unsound.effectivePageBound)
        let recovered = await TestFixtures.recheck(out, requests: [unsound])
        #expect(recovered.queryLines?.first?.remainingCount == 1)
    }

    // MARK: - R-1: the per-page sub-document keeps the text layer

    @Test("R-1: PDFPage.dataRepresentation round-trips a page with its text layer")
    func subDocumentKeepsTextLayer() throws {
        let doc = try #require(PDFDocument(data: TestFixtures.textPagesPDF(["first page Delia", "second page Hartwell"])))
        let second = try #require(doc.page(at: 1))
        let data = try #require(second.dataRepresentation)
        let sub = try #require(PDFDocument(data: data))
        #expect(sub.pageCount == 1)
        #expect(sub.page(at: 0)?.string?.contains("Hartwell") == true)
        #expect(sub.page(at: 0)?.string?.contains("Delia") == false)
    }

    // MARK: - The fold (pure)

    private func observation(
        _ page: Int, route: PageSearchCoverage.Route?, remaining: Int = 0,
        hitCap: Bool = false, timeout: Bool = false, request: Int = 0
    ) -> SearchRecheck.PageObservation {
        SearchRecheck.PageObservation(
            pageIndex: page, route: route, regexTimedOut: timeout,
            counts: route == nil || route == .unopenable
                ? [:]
                : [request: .init(remaining: remaining, hitCap: hitCap, perTerm: [:])])
    }

    @Test("fold: OCR unavailable → WARN 'OCR did not run', never PASS")
    func foldOCRUnavailable() {
        let requests = [TestFixtures.textRequest("Delia")]
        let outcome = SearchRecheck.fold(
            requests: requests,
            observations: [observation(0, route: .textLayer), observation(1, route: .ocrUnavailable)],
            pageCount: 2)
        #expect(outcome.status == .warn(""))
        #expect(TestFixtures.message(of: outcome.status) == "Re-ran 1 search; 1 page could not be checked: 2 (OCR did not run)")
        #expect(outcome.copyOverride?.detail == "\(SearchRecheck.detailLead) Text was read from the output's text layer. 1 page could not be checked: 2 (OCR did not run).")
        #expect(outcome.pageReferences == [1])
        #expect(outcome.reviewTermTexts == nil)
    }

    @Test("fold: oversize, timeout and cap clauses; a page with two reasons lists both")
    func foldReasonClauses() {
        let requests = [TestFixtures.regexRequest("a+")]
        let outcome = SearchRecheck.fold(
            requests: requests,
            observations: [
                observation(0, route: .ocrSkippedOversize),
                observation(1, route: .ocr, timeout: true),
                observation(2, route: .textLayer, hitCap: true),
                observation(3, route: .textLayer),
            ],
            pageCount: 4)
        #expect(outcome.status == .warn(""))
        #expect(TestFixtures.message(of: outcome.status)
                == "Re-ran 1 search; 3 pages could not be checked: 1 (too large to scan for text), 2 (the pattern took too long), 3 (the re-check stopped at 1,000 matches on the page)")
        #expect(outcome.copyOverride?.detail.contains("Text was read from the text layer on 2 pages and by OCR from the rendered pages on 1.") == true)
        #expect(outcome.queryLines?.first?.route == .mixed(textPages: 2, ocrPages: 1))
    }

    @Test("fold: a page at the per-page result cap is reported beside its remaining matches")
    func foldCapBesideRemaining() {
        // No text-layer fixture can carry 1,000 resolvable matches on one page
        // (PDFKit's selection mapping stops resolving ranges past ~2,000
        // characters on iOS 26.4), so the cap arm is pinned here at the fold.
        let outcome = SearchRecheck.fold(
            requests: [TestFixtures.textRequest("x")],
            observations: [observation(0, route: .textLayer, remaining: DocumentSearcher.maxResults, hitCap: true)],
            pageCount: 1)
        #expect(outcome.status == .attention(""))
        #expect(TestFixtures.message(of: outcome.status)
                == "Re-ran 1 search — 1000 matches remain on page 1, 1 page could not be checked: 1 (the re-check stopped at 1,000 matches on the page)")
        #expect(outcome.pageReferences == [0])
        #expect(outcome.queryLines?.first?.remainingCount == DocumentSearcher.maxResults)
    }

    @Test("fold: remaining matches outrank a coverage gap; both appear in the message")
    func foldAttentionOutranksWarn() {
        let requests = [TestFixtures.textRequest("Delia"), TestFixtures.textRequest("Hartwell")]
        let outcome = SearchRecheck.fold(
            requests: requests,
            observations: [
                observation(0, route: .ocr, remaining: 2, request: 1),
                observation(1, route: .ocrUnavailable),
            ],
            pageCount: 2)
        #expect(outcome.status == .attention(""))
        #expect(TestFixtures.message(of: outcome.status)
                == "Re-ran 2 searches — 2 matches remain on page 1, 1 page could not be checked: 2 (OCR did not run)")
        #expect(outcome.reviewTermTexts == ["Hartwell"])
        #expect(outcome.pageReferences == [0])
        #expect(outcome.copyOverride?.detail == "\(SearchRecheck.detailLead) Text was read by OCR from the rendered pages. 2 matches remain on page 1. 1 page could not be checked: 2 (OCR did not run).")
    }

    @Test("fold: an unopenable page is listed without a reason clause; the other pages still count")
    func foldUnopenablePage() {
        let requests = [TestFixtures.textRequest("Delia")]
        let survivors = SearchRecheck.fold(
            requests: requests,
            observations: [
                observation(0, route: .textLayer, remaining: 1),
                observation(1, route: .unopenable),
                observation(2, route: .textLayer, remaining: 1),
            ],
            pageCount: 3)
        #expect(survivors.status == .attention(""))
        #expect(TestFixtures.message(of: survivors.status)
                == "Re-ran 1 search — 2 matches remain on 2 pages: 1, 3, 1 page could not be checked: 2")
        #expect(survivors.pageReferences == [0, 2])
        let clean = SearchRecheck.fold(
            requests: requests,
            observations: [
                observation(0, route: .textLayer),
                observation(1, route: .unopenable),
                observation(2, route: .textLayer),
            ],
            pageCount: 3)
        #expect(clean.status == .warn(""))
        #expect(TestFixtures.message(of: clean.status) == "Re-ran 1 search; 1 page could not be checked: 2")
        #expect(clean.pageReferences == [1])
        #expect(clean.copyOverride?.detail == "\(SearchRecheck.detailLead) Text was read from the output's text layer. 1 page could not be checked: 2.")
    }

    @Test("fold: nothing read at all carries no route sentence")
    func foldNoRouteSentence() {
        let outcome = SearchRecheck.fold(
            requests: [TestFixtures.textRequest("Delia")],
            observations: [observation(0, route: .unopenable)],
            pageCount: 1)
        #expect(outcome.status == .warn(""))
        #expect(outcome.copyOverride?.detail == "\(SearchRecheck.detailLead) 1 page could not be checked: 1.")
        #expect(SearchRecheck.routeSentence(textPages: 0, ocrPages: 0) == "")
    }
}

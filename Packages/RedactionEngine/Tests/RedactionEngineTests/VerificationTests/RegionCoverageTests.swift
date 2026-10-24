import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The Search Re-check's coverage check: every match an applied search or
// scan produces on the ORIGINAL page must be fully covered by the boxes
// applied over it. A box placed as 1.2.0's literal tier placed it on a page
// with an emoji, a non-BMP letter, two ligatures or a Devanagari name before
// (or at) the term leaves glyphs uncovered; the rebuilt text layer drops
// them, so every text-reading layer passed. Now the layer FAILs on that box
// and PASSes on the box the current searcher places.

@Suite("Search Re-check coverage check", .tags(.search))
struct RegionCoverageTests {

    private func region(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: x, y: y, width: w, height: h), source: .manual)
    }

    @Test("coveredFraction: whole, half, the union of two boxes, a degenerate match")
    func coveredFraction() {
        let match = CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0.02)
        #expect(RegionCoverage.coveredFraction(of: match, by: [region(0.2, 0.5, 0.2, 0.02)]) == 1)
        #expect(RegionCoverage.coveredFraction(of: match, by: [region(0.19, 0.49, 0.22, 0.04)]) == 1)
        let half = RegionCoverage.coveredFraction(of: match, by: [region(0.2, 0.5, 0.1, 0.02)])
        #expect(abs(half - 0.5) < 0.03)
        let union = RegionCoverage.coveredFraction(of: match, by: [region(0.2, 0.5, 0.1, 0.02), region(0.3, 0.5, 0.1, 0.02)])
        #expect(union == 1)
        #expect(RegionCoverage.coveredFraction(of: CGRect(x: 0.2, y: 0.5, width: 0, height: 0.02), by: [region(0, 0, 1, 1)]) == 0)
        #expect(RegionCoverage.coveredFraction(of: match, by: []) == 0)
    }

    @Test("coveredFraction samples along the run: one glyph of twenty uncovered at the end of a vertical match reads as a shortfall, as it does for the horizontal match")
    func verticalRunSampling() {
        // Twenty glyphs set vertically; the box leaves the top glyph (5 %) uncovered.
        let vertical = CGRect(x: 0.5, y: 0.3, width: 0.02, height: 0.24)
        let verticalFraction = RegionCoverage.coveredFraction(of: vertical, by: [region(0.5, 0.3, 0.02, 0.228)])
        #expect(verticalFraction < RegionCoverage.coveredThreshold, "\(verticalFraction)")
        #expect(verticalFraction > 0.9, "\(verticalFraction)")
        let horizontal = CGRect(x: 0.3, y: 0.5, width: 0.24, height: 0.02)
        let horizontalFraction = RegionCoverage.coveredFraction(of: horizontal, by: [region(0.3, 0.5, 0.228, 0.02)])
        #expect(horizontalFraction == verticalFraction, "\(horizontalFraction) vs \(verticalFraction)")
        // Fully covered either way.
        #expect(RegionCoverage.coveredFraction(of: vertical, by: [region(0.49, 0.29, 0.04, 0.26)]) == 1)
    }

    @Test("pageShortfalls: a search box drifted clear of its match is a shortfall, a manual box that touches nothing is not; a neighbour's box grazing an unselected match is not a shortfall, a box short of its own match is")
    func driftedAndNeighbouringBoxes() {
        let first = CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.02)
        let second = CGRect(x: 0.32, y: 0.50, width: 0.20, height: 0.02)
        let matches = [RegionCoverage.PageMatch(requestIndex: 0, rect: first, term: "SEED"),
                       RegionCoverage.PageMatch(requestIndex: 0, rect: second, term: "SEED")]
        func box(_ rect: CGRect, source: RedactionRegion.Source) -> RedactionRegion {
            RedactionRegion(id: UUID(), normalizedRect: rect, source: source)
        }
        let searchSource = RedactionRegion.Source.searchMatch(term: "SEED")
        // Drifted clear of both matches (two widths to the right): the first untouched match is reported.
        let drifted = box(CGRect(x: 0.60, y: 0.50, width: 0.20, height: 0.02), source: searchSource)
        let driftedShortfalls = RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [drifted])
        #expect(driftedShortfalls == [RegionCoverage.Shortfall(pageIndex: 3, requestIndex: 0, coveredFraction: 0)])
        // The same box drawn by hand: the matches were left unselected.
        #expect(RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [box(drifted.normalizedRect, source: .manual)]).isEmpty)
        // Two drifted boxes, two untouched matches: both reported; one drifted box beside one covered match: one.
        let drifted2 = box(CGRect(x: 0.60, y: 0.60, width: 0.20, height: 0.02), source: searchSource)
        #expect(RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [drifted, drifted2]).count == 2)
        // A drifted box vouches only for its own term: a box placed for another term, or a detected item of a
        // category the untouched match is not, leaves the match as unselected.
        let otherTerm = box(drifted.normalizedRect, source: .searchMatch(term: "OTHER"))
        #expect(RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [otherTerm]).isEmpty)
        let ssnItem = box(drifted.normalizedRect, source: .detectedPII(kind: .ssn))
        #expect(RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [ssnItem]).isEmpty)
        let ssnMatch = [RegionCoverage.PageMatch(requestIndex: 1, rect: first, term: PIICategory.ssn.rawValue)]
        #expect(RegionCoverage.pageShortfalls(page: 3, matches: ssnMatch, boxes: [ssnItem]).count == 1)
        let onFirst = box(first, source: searchSource)
        let oneDrift = RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [onFirst, drifted])
        #expect(oneDrift == [RegionCoverage.Shortfall(pageIndex: 3, requestIndex: 0, coveredFraction: 0)])
        // A box that covers the first match and grazes the second by a tenth: the second was left unselected.
        let grazing = box(CGRect(x: 0.10, y: 0.50, width: 0.24, height: 0.02), source: searchSource)
        #expect(RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [grazing]).isEmpty)
        // A box short of its own match (half of it) is still a shortfall, and so is one that grazes a match while covering no other.
        let half = box(CGRect(x: 0.10, y: 0.50, width: 0.10, height: 0.02), source: searchSource)
        let halfShortfalls = RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [half])
        #expect(halfShortfalls.count == 1 && halfShortfalls[0].requestIndex == 0 && abs(halfShortfalls[0].coveredFraction - 0.5) < 0.03, "\(halfShortfalls)")
        let graze = box(CGRect(x: 0.28, y: 0.50, width: 0.06, height: 0.02), source: .manual)
        #expect(RegionCoverage.pageShortfalls(page: 3, matches: matches, boxes: [graze]).count == 2)
    }

    @Test("A search box drifted clear of its match on the original page FAILS the layer; a header-only scanned page is re-run through OCR, so a box short of its OCR-placed match FAILS there too")
    func driftedBoxAndSparsePage() async throws {
        // Typed search on a text page: the box two widths to the right of "SEED".
        let data = TestFixtures.textLayerPDF(text: "SEED 123")
        let source = try #require(PDFDocument(data: data))
        let page = try #require(source.page(at: 0))
        let raw = try #require(page.string)
        let range = (raw as NSString).range(of: "SEED")
        let trueRect = try #require(DocumentSearcher().boundingRect(for: range, page: page))
        let driftedRect = trueRect.offsetBy(dx: trueRect.width * 2, dy: 0)
        let request = TestFixtures.textRequest("SEED")
        let drifted = await RegionCoverage.check(
            source: SendablePDFDocument(source), requests: [request],
            regions: [0: [RedactionRegion(id: UUID(), normalizedRect: driftedRect, source: .searchMatch(term: "SEED"))]])
        #expect(drifted.shortfalls.count == 1 && drifted.shortfalls.first?.pageIndex == 0, "\(drifted.shortfalls)")
        let manual = await RegionCoverage.check(
            source: SendablePDFDocument(source), requests: [request],
            regions: [0: [RedactionRegion(id: UUID(), normalizedRect: driftedRect, source: .manual)]])
        #expect(manual.shortfalls.isEmpty, "\(manual.shortfalls)")

        // A scanned page with a three-character header: the search placed its box by OCR; the re-run must read the page the same way.
        let scanned = try #require(PDFDocument(data: TestFixtures.sparseHeaderScannedPagePDF(header: "Hdr", body: "SEED")))
        let scannedPage = try #require(scanned.page(at: 0))
        #expect(TextLayerDetector.detectTextLayer(scannedPage) == .sparse)
        // The image sits at (50, 520, 300 × 150) on a 612 × 792 page; the word fills its left part. A box over the
        // image's right 60 % touches the word in part only.
        let shortBox = CGRect(x: (50 + 120) / 612.0, y: 520 / 792.0, width: 180 / 612.0, height: 150 / 792.0)
        let options = SearchOptions()
        let ocrRequest = TestFixtures.textRequest("SEED", options: options)
        let sparse = await RegionCoverage.check(
            source: SendablePDFDocument(scanned), requests: [ocrRequest],
            regions: [0: [RedactionRegion(id: UUID(), normalizedRect: shortBox, source: .searchMatch(term: "SEED"))]])
        #expect(!sparse.shortfalls.isEmpty, "the OCR-read match under a short box is a shortfall; got \(sparse)")
        #expect(sparse.unreadPages.isEmpty, "\(sparse)")
    }

    @Test("fold: a shortfall is the layer's FAIL, ahead of remaining matches; its message names pages only")
    func foldShortfall() {
        let request = TestFixtures.textRequest("Delia")
        let observation = RecheckObservation(
            pageIndex: 0, route: .textLayer, regexTimedOut: false,
            counts: [0: RecheckObservation.Count(remaining: 1, hitCap: false, perTerm: ["Delia": 1])])
        let outcome = SearchRecheck.fold(
            requests: [request], observations: [observation], pageCount: 1,
            shortfalls: [SearchRecheck.Shortfall(page: 0, displayText: "Delia"), SearchRecheck.Shortfall(page: 2, displayText: "Delia")])
        guard case .fail(let message) = outcome.status else { Issue.record("expected FAIL, got \(outcome.status)"); return }
        let expectedMessage = "2 matches are only partly covered by their redaction boxes on 2 pages: 1, 3"
        #expect(message == expectedMessage)
        let namesTheTerm: Bool = message.contains("Delia")
        #expect(namesTheTerm == false)
        #expect(outcome.pageReferences == [0, 2])
        #expect(outcome.reviewTermTexts == ["Delia"])
        #expect(outcome.queryLines?.count == 1)
        let clean = SearchRecheck.fold(requests: [request], observations: [observation], pageCount: 1)
        #expect(clean.status.isAttention)
    }

    /// (name, page text, term, 1.2.0's range arithmetic)
    static let probePages: [(String, String, String, String)] = [
        ("emoji before", "\u{1F464} SSN 123-45-6789", "123-45-6789", "characters"),
        ("math bold letter before", "\u{1D400} 123-45-6789", "123-45-6789", "characters"),
        ("ffi ligatures before", "\u{FB03}le \u{FB03}le 123-45-6789", "123-45-6789", "normalized"),
        // Ten or more meaningful characters, as a real page: a shorter page reads as sparse and is re-run through OCR.
        ("devanagari name", "\u{0930}\u{093E}\u{092E} 123 on file here", "\u{0930}\u{093E}\u{092E}", "characters"),
    ]

    /// 1.2.0's range for the term: Character offsets of the raw text (the
    /// no-map arm) or of the ligature-expanded text, handed to PDFKit as UTF-16.
    static func legacyRange(raw: String, term: String, arithmetic: String) -> NSRange? {
        let base = arithmetic == "normalized" ? TextNormalizer.normalize(raw) : raw
        guard let r = base.range(of: term) else { return nil }
        return NSRange(location: base.distance(from: base.startIndex, to: r.lowerBound), length: term.count)
    }

    private static func recheck(
        source: PDFDocument, output: PDFDocument, region: RedactionRegion, request: SearchRecheckRequest
    ) async -> LayerResult {
        await VerificationEngine().runLayer(
            .searchRecheck, outputDocument: SendablePDFDocument(output), sourcePageCount: 1,
            regions: [0: [region]], sensitiveTerms: [], pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction],
            appliedSearches: [request], sourceDocument: SendablePDFDocument(source))
    }

    @Test("A box placed as 1.2.0 placed it FAILS the re-check; the box the searcher places now PASSES — Text mode",
          arguments: probePages)
    func driftedBoxFailsTrueBoxPasses(name: String, text: String, term: String, arithmetic: String) async throws {
        let data = TestFixtures.textLayerPDF(text: text)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let raw = try #require(page.string)
        let trueRange = (raw as NSString).range(of: term)
        try #require(trueRange.location != NSNotFound, "\(name)")
        let legacy = try #require(Self.legacyRange(raw: raw, term: term, arithmetic: arithmetic))
        let searcher = DocumentSearcher()
        let trueRect = try #require(searcher.boundingRect(for: trueRange, page: page))
        let legacyRect = try #require(searcher.boundingRect(for: legacy, page: page))
        let request = TestFixtures.textRequest(term)

        let drifted = RedactionRegion(id: UUID(), normalizedRect: legacyRect, source: .searchMatch(term: term))
        let driftedURL = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: [0: [drifted]])
        defer { try? FileManager.default.removeItem(at: driftedURL) }
        let driftedOut = try #require(PDFDocument(url: driftedURL))
        let failed = await Self.recheck(source: doc, output: driftedOut, region: drifted, request: request)
        #expect(failed.status.isFail, "\(name): a box short of its glyphs must fail — got \(failed.status)")
        #expect(failed.shortDescription == "1 match is only partly covered by its redaction box on page 1", "\(name)")
        #expect(failed.pageReferences == [0], "\(name)")
        #expect(failed.reviewTermTexts == [term], "\(name)")

        let placed = RedactionRegion(id: UUID(), normalizedRect: trueRect, source: .searchMatch(term: term))
        let placedURL = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: [0: [placed]])
        defer { try? FileManager.default.removeItem(at: placedURL) }
        let placedOut = try #require(PDFDocument(url: placedURL))
        let passed = await Self.recheck(source: doc, output: placedOut, region: placed, request: request)
        #expect(passed.status == .pass, "\(name): the searcher's own box covers its match — got \(passed.status)")

        // Without the source the coverage check cannot run, and the layer
        // says so: the drifted output's rebuilt text layer has no trace of the
        // term, so the output half is clean — never a PASS by silence.
        let blind = await VerificationEngine().runLayer(
            .searchRecheck, outputDocument: SendablePDFDocument(driftedOut), sourcePageCount: 1,
            regions: [0: [drifted]], sensitiveTerms: [], pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction], appliedSearches: [request])
        #expect(blind.status.isWarn && blind.couldNotVerify, "\(name): got \(blind.status)")
        #expect(blind.shortDescription == "Re-ran 1 search; \(SearchRecheck.coverageNotRunClause)", "\(name)")
    }

    // MARK: - The source the check cannot read

    @Test("fold: with the coverage check not run, a clean re-run is a could-not-verify WARN, remaining matches keep ATTENTION with the clause, and unchecked pages join it")
    func foldCoverageNotRun() {
        let request = TestFixtures.textRequest("Delia")
        let clean = RecheckObservation(
            pageIndex: 0, route: .textLayer, regexTimedOut: false,
            counts: [0: RecheckObservation.Count(remaining: 0, hitCap: false, perTerm: [:])])
        let warned = SearchRecheck.fold(requests: [request], observations: [clean], pageCount: 1, coverageRan: false)
        guard case .warn(let message) = warned.status else { Issue.record("expected WARN, got \(warned.status)"); return }
        #expect(message == "Re-ran 1 search; the original pages could not be read, so the coverage check did not run")
        #expect(warned.pageReferences == nil)
        #expect(warned.queryLines?.count == 1)
        #expect(warned.copyOverride?.detail == "\(SearchRecheck.detailLead) Text was read from the output's text layer. \(SearchRecheck.coverageNotRunDetail)")
        #expect(SearchRecheck.fold(requests: [request], observations: [clean], pageCount: 1).status == .pass)

        let remaining = RecheckObservation(
            pageIndex: 0, route: .textLayer, regexTimedOut: false,
            counts: [0: RecheckObservation.Count(remaining: 1, hitCap: false, perTerm: ["Delia": 1])])
        let attention = SearchRecheck.fold(requests: [request], observations: [remaining], pageCount: 1, coverageRan: false)
        guard case .attention(let kept) = attention.status else { Issue.record("expected ATTENTION, got \(attention.status)"); return }
        #expect(kept == "Re-ran 1 search — 1 match remains on page 1; the original pages could not be read, so the coverage check did not run")
        #expect(attention.reviewTermTexts == ["Delia"])

        let unchecked = RecheckObservation(pageIndex: 1, route: .ocrUnavailable, regexTimedOut: false, counts: [:])
        let both = SearchRecheck.fold(requests: [request], observations: [clean, unchecked], pageCount: 2, coverageRan: false)
        guard case .warn(let two) = both.status else { Issue.record("expected WARN, got \(both.status)"); return }
        #expect(two == "Re-ran 1 search; 1 page could not be checked: 2 (OCR did not run); the original pages could not be read, so the coverage check did not run")
        #expect(both.pageReferences == [1])
    }

    @Test("An applied scan with no readable source is a could-not-verify WARN; the run's own sweep alone stays INFO")
    func scanOnlyCoverageNotRun() async throws {
        let output = SendablePDFDocument(try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "nothing here"))))
        let scan = AppliedSearchRecord(query: AppliedSearchQuery(kind: .piiScan(categories: [.ssn]), options: SearchOptions()), foundCount: 1)
        let applied = SearchRecheckRequest(record: scan, appliedCount: 1, appliedPages: [0])
        let blind = try await SearchRecheck().run(outputDocument: output, requests: [applied])
        guard case .warn(let message) = blind.status else { Issue.record("expected WARN, got \(blind.status)"); return }
        #expect(message == "The original pages could not be read, so the coverage check did not run")
        #expect(blind.copyOverride?.detail == SearchRecheck.coverageNotRunDetail)
        #expect(blind.queryLines == nil && blind.pageReferences == nil)
        let sweep = SearchRecheckRequest(record: scan, appliedCount: 0, appliedPages: [], origin: .sweep)
        let idle = try await SearchRecheck().run(outputDocument: output, requests: [sweep])
        #expect(idle.status.isInfo, "the sweep applied nothing: nothing to cover — got \(idle.status)")
        // A locked source counts as unreadable too.
        let locked = try #require(PDFDocument(data: try Data(contentsOf: LockedImportTests.directory.appendingPathComponent("r4-aes-128.pdf"))))
        #expect(locked.isLocked)
        let stillLocked = try await SearchRecheck().run(outputDocument: output, requests: [applied], sourceDocument: SendablePDFDocument(locked))
        #expect(stillLocked.status.isWarn, "got \(stillLocked.status)")
    }

    @Test("fold: an original page the coverage check could not read is a could-not-verify WARN that names it, joins the unchecked and not-run clauses, and rides the ATTENTION message")
    func foldCoverageUnreadPage() {
        let request = TestFixtures.textRequest("Delia")
        let clean = RecheckObservation(
            pageIndex: 0, route: .textLayer, regexTimedOut: false,
            counts: [0: RecheckObservation.Count(remaining: 0, hitCap: false, perTerm: [:])])
        let one = SearchRecheck.fold(requests: [request], observations: [clean], pageCount: 3, coverageUnreadPages: [1])
        guard case .warn(let message) = one.status else { Issue.record("expected WARN, got \(one.status)"); return }
        #expect(message == "Re-ran 1 search; the coverage check could not read original page 2")
        #expect(one.pageReferences == [1])
        #expect(one.copyOverride?.detail.contains("so no match there was compared with its boxes.") == true)
        let two = SearchRecheck.fold(requests: [request], observations: [clean], pageCount: 3, coverageUnreadPages: [1, 2])
        #expect(two.status == .warn("Re-ran 1 search; the coverage check could not read 2 original pages: 2, 3"))
        #expect(two.pageReferences == [1, 2])
        // Beside an unchecked output page and a coverage check that did not run: every clause, the pages united.
        let unchecked = RecheckObservation(pageIndex: 2, route: .ocrSkippedOversize, regexTimedOut: false, counts: [:])
        let all = SearchRecheck.fold(requests: [request], observations: [clean, unchecked], pageCount: 3,
                                     coverageRan: false, coverageUnreadPages: [1])
        #expect(all.status == .warn("Re-ran 1 search; 1 page could not be checked: 3 (too large to scan for text); \(SearchRecheck.coverageNotRunClause); the coverage check could not read original page 2"))
        #expect(all.pageReferences == [1, 2])
        // Remaining matches keep ATTENTION with the clause appended.
        let remaining = RecheckObservation(
            pageIndex: 0, route: .textLayer, regexTimedOut: false,
            counts: [0: RecheckObservation.Count(remaining: 1, hitCap: false, perTerm: ["Delia": 1])])
        let attention = SearchRecheck.fold(requests: [request], observations: [remaining], pageCount: 3, coverageUnreadPages: [1])
        #expect(attention.status == .attention("Re-ran 1 search — 1 match remains on page 1; the coverage check could not read original page 2"))
        #expect(attention.pageReferences == [0])
        // A shortfall still outranks it.
        let failed = SearchRecheck.fold(requests: [request], observations: [clean], pageCount: 3,
                                        shortfalls: [SearchRecheck.Shortfall(page: 0, displayText: "Delia")], coverageUnreadPages: [1])
        #expect(failed.status.isFail)
        // Scan-only: the same page named in the layer's WARN.
        let scanOnly = SearchRecheck.coverageNotRunOutcome(unreadPages: [1])
        #expect(scanOnly.status == .warn("The coverage check could not read original page 2"))
        #expect(scanOnly.pageReferences == [1])
    }

    @Test("An original page the searcher cannot read — a blank page over the OCR pixel caps under a box — is reported as unread, never passed; a readable page beside it is not")
    func unreadOriginalPage() async throws {
        // Page 1 readable (a text layer); page 2 a 14,000-pt blank page: no text layer, and its render is over the OCR caps.
        let readable = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "nothing to see")))
        let oversize = try #require(PDFDocument(data: TestFixtures.blankPage(width: 14_000, height: 14_000)))
        let source = PDFDocument()
        source.insert(try #require(readable.page(at: 0)), at: 0)
        source.insert(try #require(oversize.page(at: 0)), at: 1)
        try #require(source.pageCount == 2)
        let box = region(0.1, 0.1, 0.2, 0.05)
        let request = TestFixtures.textRequest("SEED", pages: [0, 1])
        let direct = await RegionCoverage.check(
            source: SendablePDFDocument(source), requests: [request], regions: [0: [box], 1: [box]])
        #expect(direct.shortfalls.isEmpty)
        #expect(direct.unreadPages == [1], "the oversize page under a box is unread; got \(direct.unreadPages)")
        // A page the request's boxes are not on is not the check's question.
        let elsewhere = await RegionCoverage.check(
            source: SendablePDFDocument(source), requests: [TestFixtures.textRequest("SEED", pages: [0])], regions: [0: [box], 1: [box]])
        #expect(elsewhere.unreadPages.isEmpty, "got \(elsewhere.unreadPages)")
        let noBoxes = await RegionCoverage.check(
            source: SendablePDFDocument(source), requests: [request], regions: [0: [box]])
        #expect(noBoxes.unreadPages.isEmpty, "got \(noBoxes.unreadPages)")
        // Through the layer: a could-not-verify WARN naming the page.
        let output = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "nothing to see")))
        let result = await VerificationEngine().runLayer(
            .searchRecheck, outputDocument: SendablePDFDocument(output), sourcePageCount: 2,
            regions: [0: [box], 1: [box]], sensitiveTerms: [], pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction],
            appliedSearches: [request], sourceDocument: SendablePDFDocument(source))
        #expect(result.status.isWarn && result.couldNotVerify, "got \(result.status)")
        #expect(result.shortDescription == "Re-ran 1 search; the coverage check could not read original page 2")
        #expect(result.pageReferences == [1])
    }

    @Test("A scan-only run whose coverage check ran clean is a PASS that says what was compared, never the idle note; a scan whose matches the re-run cannot read compared nothing — could not verify; nothing applied keeps the idle note")
    func scanOnlyCoverageRan() async throws {
        let data = TestFixtures.textLayerPDF(text: "SSN 123-45-6789 on file")
        let source = try #require(PDFDocument(data: data))
        let page = try #require(source.page(at: 0))
        let raw = try #require(page.string)
        let rect = try #require(DocumentSearcher().boundingRect(for: (raw as NSString).range(of: "123-45-6789"), page: page))
        let box = RedactionRegion(id: UUID(), normalizedRect: rect, source: .detectedPII(kind: .ssn))
        let output = SendablePDFDocument(try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "SSN on file"))))
        let scan = AppliedSearchRecord(query: AppliedSearchQuery(kind: .piiScan(categories: [.ssn]), options: SearchOptions()), foundCount: 1)
        let applied = SearchRecheckRequest(record: scan, appliedCount: 1, appliedPages: [0])
        let covered = try await SearchRecheck().run(
            outputDocument: output, requests: [applied], sourceDocument: SendablePDFDocument(source), regions: [0: [box]])
        #expect(covered.status == .pass, "got \(covered.status)")
        #expect(covered.copyOverride?.short == "No typed searches to re-run; the applied scan's 1 match was compared with its box on the original pages — it is covered.")
        #expect(covered.copyOverride?.detail.contains(SearchRecheck.coverageLead) == true)
        // The same scan on an original where the re-run reads no SSN: nothing compared.
        let blank = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "nothing here at all")))
        let nothing = try await SearchRecheck().run(
            outputDocument: output, requests: [applied], sourceDocument: SendablePDFDocument(blank), regions: [0: [box]])
        #expect(nothing.status == .warn("The re-run found none of the applied scan's matches on the original pages, so the coverage check compared nothing"), "got \(nothing.status)")
        // Through the layer: the could-not-verify flag follows the WARN.
        let layer = await VerificationEngine().runLayer(
            .searchRecheck, outputDocument: output, sourcePageCount: 1, regions: [0: [box]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction, filterDigests: [nil], perPageModes: [.searchableRedaction],
            appliedSearches: [applied], sourceDocument: SendablePDFDocument(blank))
        #expect(layer.status.isWarn && layer.couldNotVerify)
        // Nothing applied at all: the idle note stands (the aggregate reads it as nothing to check).
        let sweep = SearchRecheckRequest(record: scan, appliedCount: 0, appliedPages: [], origin: .sweep)
        let idle = try await SearchRecheck().run(outputDocument: output, requests: [sweep], sourceDocument: SendablePDFDocument(source), regions: [:])
        #expect(idle.status == .info(SearchRecheck.infoMessage))
    }

    @Test("Independence proof: a legal-prefix name boxed one character short, as the detector sized it before its fix, reads ATTENTION from the OCR Check on the Searchable output; the whole name boxed, with a legitimate neighbouring word, does not")
    func edgeResidueIndependenceProof() async throws {
        // "Mr. John␠␠Smith": the collapsed name is ten characters, the raw span eleven; the short box covers "John␠␠Smit".
        let data = TestFixtures.textLayerPDF(text: "Mr. John  Smith lives here", fontSize: 28)
        let source = try #require(PDFDocument(data: data))
        let page = try #require(source.page(at: 0))
        let raw = try #require(page.string)
        let start = (raw as NSString).range(of: "John").location
        try #require(start != NSNotFound)
        // PDFKit reads the two spaces back as one, so the short box is made one character short outright: "John Smit".
        let shortRange = NSRange(location: start, length: ("John Smith" as NSString).length - 1)
        let fullRange = NSRange(location: start, length: ("John Smith" as NSString).length)
        let searcher = DocumentSearcher()
        let shortRect = try #require(searcher.boundingRect(for: shortRange, page: page))
        let fullRect = try #require(searcher.boundingRect(for: fullRange, page: page))
        let term = SensitiveTerm(text: "John Smith")
        func ocrCheck(_ rect: CGRect) async throws -> LayerResult {
            let region = RedactionRegion(id: UUID(), normalizedRect: rect, source: .detectedPII(kind: .name))
            let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: [0: [region]])
            defer { try? FileManager.default.removeItem(at: url) }
            let output = try #require(PDFDocument(url: url))
            return await VerificationEngine().runLayer(
                .ocrCheck, outputDocument: SendablePDFDocument(output), sourcePageCount: 1,
                regions: [0: [region]], sensitiveTerms: [term], pipelineMode: .searchableRedaction,
                filterDigests: [nil], perPageModes: [.searchableRedaction])
        }
        let residue = try await ocrCheck(shortRect)
        #expect(residue.status.isAttention, "the printed 'h' beside the box must be read: got \(residue.status) — \(residue.shortDescription)")
        #expect(residue.reviewTermTexts == ["John Smith"], "\(String(describing: residue.reviewTermTexts))")
        let whole = try await ocrCheck(fullRect)
        #expect(!whole.status.isAttention && !whole.status.isFail, "'lives' beside the full box is a neighbouring word: got \(whole.status) — \(whole.shortDescription)")
    }

    /// The 128-bit password fixtures (RC4 R3, AES R4): their bytes re-emit
    /// encrypted, so a copy made without the password stays locked.
    static let lockedFixtures = ["r3-rc4-128.pdf", "r4-aes-128.pdf"]

    @Test("A 128-bit password document: a locked source is could-not-verify; unlocked, a drifted box FAILS and the placed box PASSES",
          arguments: lockedFixtures)
    func lockedSourceThenUnlocked(name: String) async throws {
        let bytes = try Data(contentsOf: LockedImportTests.directory.appendingPathComponent(name))
        let request = TestFixtures.textRequest("SEED")
        let output = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "ENCRYPTED 7731")))

        let locked = try #require(PDFDocument(data: bytes))
        try #require(locked.isLocked, "\(name) opens locked")
        let anyBox = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), source: .searchMatch(term: "SEED"))
        let blind = await Self.recheck(source: locked, output: output, region: anyBox, request: request)
        #expect(blind.status.isWarn && blind.couldNotVerify, "\(name): got \(blind.status)")
        #expect(blind.shortDescription == "Re-ran 1 search; \(SearchRecheck.coverageNotRunClause)", "\(name)")

        let unlocked = try #require(PDFDocument(data: bytes))
        try #require(unlocked.unlock(withPassword: "user"), "\(name) unlocks with the fixture password")
        let page = try #require(unlocked.page(at: 0))
        let raw = try #require(page.string)
        let range = (raw as NSString).range(of: "SEED")
        try #require(range.location != NSNotFound, "\(name) reads its text once unlocked")
        let trueRect = try #require(DocumentSearcher().boundingRect(for: range, page: page))
        let placed = RedactionRegion(id: UUID(), normalizedRect: trueRect, source: .searchMatch(term: "SEED"))
        let passed = await Self.recheck(source: unlocked, output: output, region: placed, request: request)
        #expect(passed.status == .pass, "\(name): the placed box covers its match — got \(passed.status)")
        let driftedRect = trueRect.offsetBy(dx: trueRect.width * 0.6, dy: 0)
        let drifted = RedactionRegion(id: UUID(), normalizedRect: driftedRect, source: .searchMatch(term: "SEED"))
        let failed = await Self.recheck(source: unlocked, output: output, region: drifted, request: request)
        #expect(failed.status.isFail, "\(name): a box drifted off its match must fail — got \(failed.status)")
        #expect(failed.reviewTermTexts == ["SEED"], "\(name)")
    }

    @Test("Regex mode: the drifted box on the ligature page FAILS the re-check through the whole report; the placed box passes it")
    func regexDriftedBoxThroughReport() async throws {
        let text = "\u{FB03}le \u{FB03}le 123-45-6789"
        let data = TestFixtures.textLayerPDF(text: text)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let raw = try #require(page.string)
        let searcher = DocumentSearcher()
        let trueRect = try #require(searcher.boundingRect(for: (raw as NSString).range(of: "123-45-6789"), page: page))
        let legacy = try #require(Self.legacyRange(raw: raw, term: "123-45-6789", arithmetic: "normalized"))
        let legacyRect = try #require(searcher.boundingRect(for: legacy, page: page))
        let request = TestFixtures.regexRequest("\\d{3}-\\d{2}-\\d{4}")
        for (rect, expectFail) in [(legacyRect, true), (trueRect, false)] {
            let region = RedactionRegion(id: UUID(), normalizedRect: rect, source: .searchMatch(term: "\\d{3}-\\d{2}-\\d{4}"))
            let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: [0: [region]])
            defer { try? FileManager.default.removeItem(at: url) }
            let out = try #require(PDFDocument(url: url))
            let report = try await VerificationOrchestrator().run(
                outputDocument: SendablePDFDocument(out), sourcePageCount: 1, regions: [0: [region]],
                sensitiveTerms: [SensitiveTerm(text: "123-45-6789")], pipelineMode: .searchableRedaction,
                filterDigests: [nil], perPageModes: [.searchableRedaction], perPageFallbackReasons: [nil],
                appliedSearches: [request], sourceDocument: SendablePDFDocument(doc),
                provisionLayerDocuments: { _ in nil }, events: { _ in })
            let recheck = try #require(report.layers.first { $0.layer == .searchRecheck })
            let ocr = try #require(report.layers.first { $0.layer == .ocrCheck })
            print("coverage probe regex drifted=\(expectFail): re-check=\(recheck.status) · OCR Check=\(ocr.status) · \(ocr.shortDescription)")
            #expect(recheck.status.isFail == expectFail)
            if expectFail {
                #expect(report.overallStatus.isFail)
            } else {
                #expect(!ocr.status.isAttention && !ocr.status.isFail, "the placed box leaves no fragment beside it")
            }
        }
    }
}

@Suite("OCR Check — a term fragment beside a box")
struct Layer2FragmentBesideRegionTests {

    private let box = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.50, y: 0.40, width: 0.10, height: 0.03), source: .manual)
    private let term = SensitiveTerm(text: "123-45-6789")

    @Test("A fill-demoted word box that reaches past the box's edge has its line read for the whole term: ATTENTION naming it; fill tokens on the same box stay the note; an edge sliver stays the note")
    func straddleBoxLineIsReadForTheTerm() {
        let fill = VerificationEngine.BoxFillSample(fillFraction: 1, contrastFraction: 0, maxDeviation: 0)
        func straddle(_ text: String, x: CGFloat, width: CGFloat) -> VerificationEngine.OCRHit {
            VerificationEngine.OCRHit(box: CGRect(x: x, y: 0.405, width: width, height: 0.02), wordBoxes: [], text: text, confidence: 0.9, boxFill: [fill])
        }
        // 70 % inside the box (in-region, fill-demoted), 30 % past its right edge, reading the term.
        let term70 = straddle("123-45-6789", x: 0.53, width: 0.10)
        #expect(VerificationEngine.boxLiesInRegion(term70.box, of: [box]))
        #expect(VerificationEngine.classifyPageOCR(hits: [term70], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermOutsideRegions)
        #expect(VerificationEngine.outsideRegionTermTexts(hits: [term70], pageRegions: [box], sensitiveTerms: [term]) == ["123-45-6789"])
        // The same geometry reading fill tokens: the fill note, as before.
        #expect(VerificationEngine.classifyPageOCR(hits: [straddle("III", x: 0.53, width: 0.10)], pageRegions: [box], sensitiveTerms: [term]) == .fillArtifactInRegion)
        // A 5 % sliver past the edge (the hallucination box's rounding): the fill note.
        let sliver = straddle("123-45-6789", x: 0.51, width: 0.0947)
        #expect(VerificationEngine.outsideFraction(of: sliver.box, regions: [box]) < VerificationEngine.straddleOutsideFraction)
        #expect(VerificationEngine.classifyPageOCR(hits: [sliver], pageRegions: [box], sensitiveTerms: [term]) == .fillArtifactInRegion)
    }

    private func hit(_ text: String, x: CGFloat, width: CGFloat) -> VerificationEngine.OCRHit {
        VerificationEngine.OCRHit(box: CGRect(x: x, y: 0.40, width: width, height: 0.03), wordBoxes: [], text: text, confidence: 0.9)
    }

    @Test("A line ending with the start of the term right before the box reads as a fragment beside it; so does one beginning with its end right after the box")
    func fragmentAtEitherEdge() {
        let before = VerificationEngine.classifyPageOCR(hits: [hit("ffile ffile 123-", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term])
        #expect(before == .sensitiveTermFragmentBesideRegion)
        let after = VerificationEngine.classifyPageOCR(hits: [hit("6789 on file", x: 0.61, width: 0.15)], pageRegions: [box], sensitiveTerms: [term])
        #expect(after == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.fragmentTermTexts(hits: [hit("ffile ffile 123-", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == ["123-45-6789"])
    }

    @Test("Not a fragment: a neighbouring word that is not the term's edge, a fragment far from any box, a line that merely ends in two characters of the term, and the whole term (the outside-term arm)")
    func notAFragment() {
        let delia = SensitiveTerm(text: "Delia")
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("Delaware", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [delia]) == .textOutsideRegionsOnly)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("ffile ffile 123-", x: 0.05, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .textOutsideRegionsOnly)
        // A short residue counts only as the whole word beside the box: "SSN12" ends in "12" but is one word.
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN12", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .textOutsideRegionsOnly)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("Robo", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [SensitiveTerm(text: "Bob")]) == .textOutsideRegionsOnly)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 123-45-6789", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermOutsideRegions)
    }

    @Test("A residue of one or two characters is a fragment when it is the whole word beside the box; a three-character term is checked the same way; the comparison ignores spaces, hyphens, soft hyphens and zero-width marks")
    func shortResiduesAndSeparators() {
        // Two characters of the term as the word right before the box.
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 12", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermFragmentBesideRegion)
        // One character of the term's end as the word right after the box.
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("9 on file", x: 0.61, width: 0.15)], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermFragmentBesideRegion)
        // A three-character term: its two-character start and one-character end, whole words beside the box.
        let bob = SensitiveTerm(text: "Bob")
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("see Bo", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [bob]) == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("b here", x: 0.61, width: 0.15)], pageRegions: [box], sensitiveTerms: [bob]) == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.fragmentTermTexts(hits: [hit("see Bo", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [bob]) == ["Bob"])
        // Separators: the OCR line's spacing and hyphens need not match the term's.
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 123 45-", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 12345", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 123\u{00AD}45\u{200B}", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermFragmentBesideRegion)
        let spaced = SensitiveTerm(text: "123 45 6789")
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 123-45-", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [spaced]) == .sensitiveTermFragmentBesideRegion)
        // Still never the whole term (that is the outside-term arm), and never a residue away from any box.
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 12", x: 0.05, width: 0.10)], pageRegions: [box], sensitiveTerms: [term]) == .textOutsideRegionsOnly)
    }

    @Test("The fragment page folds to ATTENTION with the term texts, below the whole-term arm and above the in-region WARN")
    func foldOrder() {
        #expect(VerificationEngine.pageBucket(for: .sensitiveTermFragmentBesideRegion, effectiveMode: .searchableRedaction) == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.pageBucket(for: .sensitiveTermFragmentBesideRegion, effectiveMode: .secureRasterization) == .sensitiveTermFragmentBesideRegion)
        let (status, pages, terms, cnv, _, fragment) = VerificationEngine.foldLayer2PageOutcomes(
            [(2, .sensitiveTermFragmentBesideRegion), (1, .textInRegionSearchable)],
            pipelineMode: .searchableRedaction, documentHasRegions: true, reviewTermsByPage: [2: ["123-45-6789"]])
        #expect(status.isAttention)
        #expect(pages == [1] && terms == ["123-45-6789"] && cnv == false)
        #expect(fragment, "the fragment arm carries the flag the results row reads")
        let (whole, _, _, _, _, wholeFlag) = VerificationEngine.foldLayer2PageOutcomes(
            [(2, .sensitiveTermFragmentBesideRegion), (1, .sensitiveTermOutsideRegions)],
            pipelineMode: .searchableRedaction, documentHasRegions: true)
        if case .attention(let message) = whole { #expect(message.hasPrefix("Text matching your redactions")) } else { Issue.record("\(whole)") }
        #expect(!wholeFlag)
    }

    @Test("On one page the fragment outranks the fill-artifact note, pairs with in-region text by the page's mode, and yields to a whole occurrence")
    func classifierOrder() {
        let fragment = hit("ffile ffile 123-", x: 0.30, width: 0.19)
        let fillSample = VerificationEngine.BoxFillSample(fillFraction: 1, contrastFraction: 0, maxDeviation: 0)
        let artifact = VerificationEngine.OCRHit(
            box: CGRect(x: 0.52, y: 0.405, width: 0.05, height: 0.02), wordBoxes: [], text: "III", confidence: 0.9, boxFill: [fillSample])
        #expect(VerificationEngine.classifyPageOCR(hits: [artifact], pageRegions: [box], sensitiveTerms: [term]) == .fillArtifactInRegion)
        #expect(VerificationEngine.classifyPageOCR(hits: [artifact, fragment], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermFragmentBesideRegion)
        let inRegionText = VerificationEngine.OCRHit(
            box: CGRect(x: 0.52, y: 0.405, width: 0.05, height: 0.02), wordBoxes: [], text: "plain", confidence: 0.9)
        #expect(VerificationEngine.classifyPageOCR(hits: [inRegionText], pageRegions: [box], sensitiveTerms: [term]) == .textInRegion)
        let paired = VerificationEngine.classifyPageOCR(hits: [inRegionText, fragment], pageRegions: [box], sensitiveTerms: [term])
        #expect(paired == .textInRegionAndSensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.pageBucket(for: paired, effectiveMode: .searchableRedaction) == .sensitiveTermFragmentBesideRegion)
        #expect(VerificationEngine.pageBucket(for: paired, effectiveMode: .secureRasterization) == .textInRegionSecureRaster)
        let whole = hit("SSN 123-45-6789", x: 0.05, width: 0.19)
        #expect(VerificationEngine.classifyPageOCR(hits: [whole, fragment], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermOutsideRegions)
        // A whole occurrence beside a fill artifact reports the term, never the note: the aggregate counts a note as a
        // pass, so the note masking the term read as a PASS on an output where the term was still readable.
        let both = VerificationEngine.classifyPageOCR(hits: [artifact, whole], pageRegions: [box], sensitiveTerms: [term])
        #expect(both == .sensitiveTermOutsideRegions)
        #expect(VerificationEngine.classifyPageOCR(hits: [artifact, whole, fragment], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermOutsideRegions)
        // The page with both findings folds to ATTENTION on both page modes, with the term text for the results row.
        for mode in [PipelineMode.searchableRedaction, .secureRasterization] {
            let bucket = VerificationEngine.pageBucket(for: both, effectiveMode: mode)
            #expect(bucket == .sensitiveTermOutsideRegions, "\(mode)")
            let folded = VerificationEngine.foldLayer2PageOutcomes(
                [(page: 1, bucket: bucket)], pipelineMode: mode, documentHasRegions: true, reviewTermsByPage: [1: [term.text]])
            #expect(folded.0.isAttention, "\(mode): got \(folded.0)")
            #expect(folded.2 == [term.text], "\(mode)")
            #expect(VerificationEngine.foldLayer2PageOutcomes(
                [(page: 1, bucket: .fillArtifactInRegion)], pipelineMode: mode, documentHasRegions: true).0.isInfo, "\(mode): the note alone stays INFO")
        }
    }
}

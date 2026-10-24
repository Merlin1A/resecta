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
        ("devanagari name", "\u{0930}\u{093E}\u{092E} 123", "\u{0930}\u{093E}\u{092E}", "characters"),
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

    @Test("Not a fragment: a neighbouring word that is not the term's edge, a fragment far from any box, a fragment shorter than three characters, and the whole term (the outside-term arm)")
    func notAFragment() {
        let delia = SensitiveTerm(text: "Delia")
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("Delaware", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [delia]) == .textOutsideRegionsOnly)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("ffile ffile 123-", x: 0.05, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .textOutsideRegionsOnly)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 12", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .textOutsideRegionsOnly)
        #expect(VerificationEngine.classifyPageOCR(hits: [hit("SSN 123-45-6789", x: 0.30, width: 0.19)], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermOutsideRegions)
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
        // The fill note keeps its place ahead of the whole-term arm (as before this check existed), never ahead of the fragment.
        #expect(VerificationEngine.classifyPageOCR(hits: [artifact, whole], pageRegions: [box], sensitiveTerms: [term]) == .fillArtifactInRegion)
        #expect(VerificationEngine.classifyPageOCR(hits: [artifact, whole, fragment], pageRegions: [box], sensitiveTerms: [term]) == .sensitiveTermFragmentBesideRegion)
    }
}

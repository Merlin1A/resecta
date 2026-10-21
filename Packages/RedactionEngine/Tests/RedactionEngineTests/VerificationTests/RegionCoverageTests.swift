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

    private func region(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, vertices: [CGPoint]? = nil) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: x, y: y, width: w, height: h), source: .manual, vertices: vertices)
    }

    @Test("coveredFraction: whole, half, the union of two boxes, a polygon's notch, a degenerate match")
    func coveredFraction() {
        let match = CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0.02)
        #expect(RegionCoverage.coveredFraction(of: match, by: [region(0.2, 0.5, 0.2, 0.02)]) == 1)
        #expect(RegionCoverage.coveredFraction(of: match, by: [region(0.19, 0.49, 0.22, 0.04)]) == 1)
        let half = RegionCoverage.coveredFraction(of: match, by: [region(0.2, 0.5, 0.1, 0.02)])
        #expect(abs(half - 0.5) < 0.03)
        let union = RegionCoverage.coveredFraction(of: match, by: [region(0.2, 0.5, 0.1, 0.02), region(0.3, 0.5, 0.1, 0.02)])
        #expect(union == 1)
        // An L-shaped polygon whose bounding box is the match: the notch (the right half's top) is uncovered.
        let l = [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.4, y: 0.51), CGPoint(x: 0.3, y: 0.51), CGPoint(x: 0.3, y: 0.52), CGPoint(x: 0.2, y: 0.52)]
        let notched = RegionCoverage.coveredFraction(of: match, by: [region(0.2, 0.5, 0.2, 0.02, vertices: l)])
        #expect(notched > 0.7 && notched < 0.8, "\(notched)")
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

        // Without the source the coverage check does not run: the drifted
        // output reads as before (the term is gone from the rebuilt text layer).
        let blind = await VerificationEngine().runLayer(
            .searchRecheck, outputDocument: SendablePDFDocument(driftedOut), sourcePageCount: 1,
            regions: [0: [drifted]], sensitiveTerms: [], pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction], appliedSearches: [request])
        #expect(blind.status == .pass, "\(name)")
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
        let (status, pages, terms, cnv, _) = VerificationEngine.foldLayer2PageOutcomes(
            [(2, .sensitiveTermFragmentBesideRegion), (1, .textInRegionSearchable)],
            pipelineMode: .searchableRedaction, documentHasRegions: true, reviewTermsByPage: [2: ["123-45-6789"]])
        #expect(status.isAttention)
        #expect(pages == [1] && terms == ["123-45-6789"] && cnv == false)
        let (whole, _, _, _, _) = VerificationEngine.foldLayer2PageOutcomes(
            [(2, .sensitiveTermFragmentBesideRegion), (1, .sensitiveTermOutsideRegions)],
            pipelineMode: .searchableRedaction, documentHasRegions: true)
        if case .attention(let message) = whole { #expect(message.hasPrefix("Text matching your redactions")) } else { Issue.record("\(whole)") }
    }
}

import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// End-to-end pins for the Search Re-check through the app's own seams, in
// process (the `VerificationPageCountIntegrityTests` verify-only shape):
// a REAL search-origin apply stamps the applied-search record on the audit
// (PR-B's capture), the coordinator derives the requests at run entry from
// the present-region join, the verify-only path feeds them to the engine
// layer, and the report's last layer reads PASS / ATTENTION / INFO with
// real counts. Text-layer fixtures only — deterministic, no Vision — set
// in Courier, the monospace family the Searchable Redaction font layer
// accepts, so the searchable-mode report is honest end to end (no FAIL
// from the fixture itself). In Secure Rasterization a text layer on the
// output is exactly what Layer 1 fails, so the raster leg pins the
// schedule and the re-check's counts, not the overall verdict.

@Suite("Search Re-check pipeline (in-process verify-only)")
@MainActor
struct SearchRecheckPipelineTests {

    /// A word the source pages carry and the redacted output must not.
    private static let term = "wrenfield"

    // MARK: - Fixtures

    /// Multi-page PDF with a real, selectable text line per page, set in
    /// Courier (an accepted monospace family for the Searchable Redaction
    /// font layer; the reconstructor's own family).
    private func textPagesPDFData(_ pageTexts: [String]) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let font = UIFont(name: "Courier", size: 18) ?? UIFont(name: "Menlo-Regular", size: 18)!
        return renderer.pdfData { ctx in
            for text in pageTexts {
                ctx.beginPage()
                (text as NSString).draw(
                    at: CGPoint(x: 72, y: 72),
                    withAttributes: [
                        .font: font,
                        .foregroundColor: UIColor.black,
                    ])
            }
        }
    }

    /// The redacted output the harness verifies, drawn as the pipeline
    /// leaves a Searchable page: each source line with the term's glyphs
    /// blanked (Courier is monospace, so every other glyph keeps its place)
    /// and a black box painted at the page's applied region. `leftover`
    /// draws the term again on a second line, outside every box: an
    /// occurrence the applied search did not cover.
    private func redactedOutputPDFData(
        sourceLines: [String], boxes: [CGRect?], leftoverOnPage: Int?
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let font = UIFont(name: "Courier", size: 18) ?? UIFont(name: "Menlo-Regular", size: 18)!
        let blank = String(repeating: " ", count: Self.term.count)
        return renderer.pdfData { ctx in
            for (index, line) in sourceLines.enumerated() {
                ctx.beginPage()
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
                (line.replacingOccurrences(of: Self.term, with: blank) as NSString)
                    .draw(at: CGPoint(x: 72, y: 72), withAttributes: attributes)
                if leftoverOnPage == index {
                    ("Also \(Self.term) here" as NSString).draw(at: CGPoint(x: 72, y: 300), withAttributes: attributes)
                }
                if index < boxes.count, let box = boxes[index] {
                    // Normalized bottom-left → the renderer's top-left points.
                    UIColor.black.setFill()
                    UIRectFill(CGRect(x: box.minX * pageRect.width, y: (1 - box.maxY) * pageRect.height,
                                      width: box.width * pageRect.width, height: box.height * pageRect.height))
                }
            }
        }
    }

    private struct Harness {
        let coordinator: PipelineCoordinator
        let outputURL: URL
        var documentState: DocumentState { coordinator.documentState }
        var redactionState: RedactionState { coordinator.redactionState }
        func removeOutput() { try? FileManager.default.removeItem(at: outputURL) }
    }

    private enum HarnessError: Error { case applyRefused, notVerified }

    /// Source = two text pages carrying the term. When `applyTerm`, the
    /// regions + audit come from a REAL search-origin apply of a typed
    /// text search for the term (one result per page, at the term's rect)
    /// and the output on disk is that redaction (`redactedOutputPDFData`),
    /// with the term once more on page `leftoverOnPage` outside every box;
    /// otherwise one manual region stands in and the output is the two
    /// lines without the term.
    private func makeHarness(
        mode: PipelineMode,
        applyTerm: Bool = true,
        leftoverOnPage: Int? = nil
    ) async throws -> Harness {
        let coordinator = makeCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState
        let sourceLines = [
            "Account holder \(Self.term) page one",
            "Balance for \(Self.term) page two",
        ]
        let sourceData = textPagesPDFData(sourceLines)
        documentState.sourceDocument = PDFDocument(data: sourceData)
        try #require(documentState.pageCount == 2)

        if applyTerm {
            // Each result at the term's own rect on its source page, as the
            // search places it: the coverage check compares the applied box
            // with the match the re-run reads on the original page.
            let source = try #require(documentState.sourceDocument)
            let searcher = DocumentSearcher()
            func termRect(_ pageIndex: Int) throws -> CGRect {
                let page = try #require(source.page(at: pageIndex))
                let range = ((page.string ?? "") as NSString).range(of: Self.term)
                try #require(range.location != NSNotFound, "page \(pageIndex + 1) carries the term")
                return try #require(searcher.boundingRect(for: range, page: page))
            }
            let search = SearchState()
            search.searchModeType = .text
            search.queryText = Self.term
            search.results = [
                SearchResult(
                    pageIndex: 0,
                    normalizedRect: try termRect(0),
                    matchedText: Self.term, contextSnippet: "…\(Self.term)…",
                    source: .textLayer, term: Self.term, isSelected: true),
                SearchResult(
                    pageIndex: 1,
                    normalizedRect: try termRect(1),
                    matchedText: Self.term, contextSnippet: "…\(Self.term)…",
                    source: .textLayer, term: Self.term, isSelected: true),
            ]
            redactionState.activeSearch = search
            let outcome = await redactionState.applyFindings(.selectedSearchResults, undoManager: nil)
            guard outcome?.applied == 2 else { throw HarnessError.applyRefused }
            // The sheet dismisses after the apply; the stamp survives on the audit.
            redactionState.activeSearch = nil
        } else {
            redactionState.regions[0] = [RedactionRegion.mock()]
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv_recheck_\(UUID().uuidString).pdf")
        let outputData = applyTerm
            ? redactedOutputPDFData(
                sourceLines: sourceLines,
                boxes: (0..<sourceLines.count).map { redactionState.regions[$0]?.first?.normalizedRect },
                leftoverOnPage: leftoverOnPage)
            : textPagesPDFData(["Account holder page one", "Balance for page two"])
        try outputData.write(to: outputURL)
        // After the apply (a region mutation nils the output URL).
        redactionState.outputURL = outputURL
        documentState.lastUsedPipelineMode = mode
        documentState.phase = .verified(report: .skipped)
        return Harness(coordinator: coordinator, outputURL: outputURL)
    }

    /// Record the run inputs the way the coordinator does when
    /// `processDocument` returns — the retained set the verify-only path
    /// prefers.
    private func recordRunInputs(_ h: Harness, mode: PipelineMode) {
        h.redactionState.recordLastRunInputs(.fixture(
            perPageModes: Array(repeating: mode, count: h.documentState.pageCount),
            sensitiveTerms: h.coordinator.collectSensitiveTerms(),
            appliedSearches: h.coordinator.collectAppliedSearches()))
    }

    private func runVerifyOnly(_ h: Harness) async throws -> VerificationReport {
        h.coordinator.runVerifyOnly()
        await h.documentState.activePipelineTask?.value
        guard case .verified(let report) = h.documentState.phase else {
            Issue.record("Expected .verified after verify-only; phase = \(h.documentState.phaseKind)")
            throw HarnessError.notVerified
        }
        return report
    }

    /// The Search Re-check row by identity: the two post-sequential checks
    /// close the schedule (the re-check, then the Detection Sweep), so the
    /// re-check is no longer the last row.
    private func recheckRow(_ report: VerificationReport) throws -> LayerResult {
        try #require(report.layers.first { $0.layer == .searchRecheck })
    }

    private var expectedRequest: SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .text(Self.term), options: SearchOptions()),
                foundCount: 2),
            appliedCount: 2,
            appliedPages: [0, 1])
    }

    // MARK: - PASS

    @Test("PASS end to end in Searchable: twelve layers, the re-check then the sweep last, 2 found · 2 redacted · 0 remaining")
    func passSearchable() async throws {
        let h = try await makeHarness(mode: .searchableRedaction)
        defer { h.removeOutput() }
        #expect(h.coordinator.collectAppliedSearches() == [expectedRequest])
        recordRunInputs(h, mode: .searchableRedaction)
        #expect(h.redactionState.lastRunInputs?.appliedSearches == [expectedRequest])

        let report = try await runVerifyOnly(h)

        #expect(report.layers.count == 12)
        #expect(report.layers.last?.layer == .detectionSweep)
        #expect(report.layers.dropLast().last?.layer == .searchRecheck)
        let last = try recheckRow(report)
        #expect(last.name == "Search Re-check")
        #expect(last.status == .pass)
        #expect(last.shortDescription
                == "Re-ran 1 search on the output — no remaining matches in the text the app can read.")
        #expect(last.detailDescription.hasPrefix(
            "Search Re-check re-ran each applied search on the output through the search engine."))
        #expect(last.detailDescription.contains("Text was read from the output's text layer."))
        #expect(last.reviewTermTexts == nil)
        #expect(last.pageReferences == nil)
        #expect(last.queryLines == [
            SearchRecheckQueryLine(
                label: "\u{201C}\(Self.term)\u{201D}", foundCount: 2, foundHitCap: false,
                appliedCount: 2, remainingCount: 0, route: .textLayer),
        ])
        #expect(LayerResultRow.queryLineTexts(layer: last)
                == ["\u{201C}\(Self.term)\u{201D} · 2 found · 2 redacted · 0 remaining"])
        #expect(!report.layers.contains { $0.layer == .searchRecheck && $0.status.isSkipped })
        // Fixture honesty under the searchable rules: nothing FAILs; the
        // aggregate is at most the skip-induced WARN of the digest-less
        // verify-only path (Layers 7 / 9), never a verdict the fixture forged.
        #expect(!report.layers.contains { $0.status.isFail },
                "the Courier text fixture satisfies every searchable-mode layer")
        #expect(!report.overallStatus.isFail && !report.overallStatus.isAttention)
    }

    @Test("Secure Raster schedule: seven layers, the re-check then the sweep last, with the same counts (text-layer fixture; Layer 1 reports the fixture's text, not this test's subject)")
    func passRaster() async throws {
        let h = try await makeHarness(mode: .secureRasterization)
        defer { h.removeOutput() }
        recordRunInputs(h, mode: .secureRasterization)

        let report = try await runVerifyOnly(h)

        #expect(report.layers.count == 7)
        #expect(report.layers.last?.layer == .detectionSweep)
        let last = try recheckRow(report)
        #expect(last.status == .pass)
        #expect(last.queryLines?.count == 1)
        #expect(last.queryLines?.first?.foundCount == 2)
        #expect(last.queryLines?.first?.appliedCount == 2)
        #expect(last.queryLines?.first?.remainingCount == 0)
        #expect(!report.layers.contains { $0.status.isSkipped },
                "the raster verify-only path has no sandwich layers to skip")
    }

    // MARK: - ATTENTION

    @Test("ATTENTION end to end: one leftover occurrence → the row names the query, the masthead names it once")
    func attentionEndToEnd() async throws {
        let h = try await makeHarness(mode: .searchableRedaction, leftoverOnPage: 1)
        defer { h.removeOutput() }
        recordRunInputs(h, mode: .searchableRedaction)

        let report = try await runVerifyOnly(h)

        let last = try recheckRow(report)
        #expect(last.layer == .searchRecheck)
        #expect(last.status.isAttention)
        if case .attention(let message) = last.status {
            #expect(message == "Re-ran 1 search — 1 match remains on page 2")
            #expect(!message.contains(Self.term), "status messages stay content-free")
        }
        #expect(last.reviewTermTexts == [Self.term], "the BARE query text — the row quotes it itself")
        #expect(last.pageReferences == [1])
        #expect(last.queryLines?.first?.remainingCount == 1)
        #expect(VerificationRowModel(layer: last, perPageModes: []).caption
                == "Your search \u{201C}\(Self.term)\u{201D} still has 1 match on\u{00A0}page\u{00A0}2.")
        #expect(LayerResultRow.queryLineTexts(layer: last)
                == ["\u{201C}\(Self.term)\u{201D} · 2 found · 2 redacted · 1 remaining"])

        // Layer 3 (Binary String Search) reads the same leftover from the
        // sensitive-term set — the accepted two-decoder cross-check — and
        // Layer 2 (OCR Check) reads it off the rendered page outside every
        // region; the masthead still names the text ONCE (deduped across
        // layers) and the details line counts every attention row.
        let layer3 = try #require(report.layers.first { $0.layer == .binaryStringSearch })
        #expect(layer3.status.isAttention, "Layer 3 flags the same leftover")
        let layer2 = try #require(report.layers.first { $0.layer == .ocrCheck })
        #expect(layer2.status.isAttention, "Layer 2 flags the same leftover outside every region; got \(layer2.status)")
        #expect(layer2.reviewTermTexts == [Self.term])
        #expect(layer2.pageReferences == [1])
        let attentionLayers = report.layers.filter { $0.status.isAttention }.compactMap(\.layer)
        #expect(attentionLayers == [.ocrCheck, .binaryStringSearch, .operatorReExtraction, .searchRecheck],
                "got \(attentionLayers)")
        #expect(report.overallStatus.isAttention)
        #expect(VerificationResultsView.reviewTermTexts(report: report) == [Self.term])
        #expect(VerificationResultsView.mastheadSubtitle(report: report)
                == "Keep\u{00A0}Editing, then use text\u{00A0}search to redact \u{201C}\(Self.term)\u{201D}.")
        #expect(VerificationResultsView.detailsSummaryText(for: report).contains("4\u{00A0}need review"),
                "got \(VerificationResultsView.detailsSummaryText(for: report))")
    }

    // MARK: - INFO

    @Test("Zero applied searches → the re-check is a not-applicable row that had nothing to check")
    func zeroSearchesIsNotApplicable() async throws {
        let h = try await makeHarness(mode: .secureRasterization, applyTerm: false)
        defer { h.removeOutput() }
        #expect(h.coordinator.collectAppliedSearches().isEmpty)
        recordRunInputs(h, mode: .secureRasterization)
        #expect(h.redactionState.lastRunInputs?.appliedSearches == [])

        let report = try await runVerifyOnly(h)

        let last = try recheckRow(report)
        #expect(last.layer == .searchRecheck)
        #expect(last.status.isNotApplicable)
        #expect(last.shortDescription == SearchRecheck.infoMessage)
        #expect(last.queryLines == nil)
        #expect(LayerResultRow.queryLineTexts(layer: last).isEmpty)
        #expect(!report.layers.contains { $0.status.isSkipped }, ".notApplicable never .skipped")

        // The Details summary counts only the passes and names the idle
        // re-check as a check that had nothing to check.
        let summary = VerificationResultsView.detailsSummaryText(for: report)
        let total = report.layers.count
        let passed = report.layers.filter { $0.status == .pass }.count
        let notApplicableCount = report.layers.filter(\.status.isNotApplicable).count
        #expect(notApplicableCount >= 1)
        #expect(VerificationRowModel(layer: last, perPageModes: report.perPageModes).outcome == .nothingToCheck)
        #expect(summary.contains("\u{00A0}had nothing to check"), "\(summary)")
        #expect(summary.hasPrefix("\(passed) of \(total) checks passed"), "\(summary)")
    }

    // MARK: - Resume path

    @Test("Verify-only with no retained inputs re-derives the same requests from the live audit")
    func resumeRefeedEquality() async throws {
        let h = try await makeHarness(mode: .searchableRedaction)
        defer { h.removeOutput() }
        // No `recordLastRunInputs`: the resumed-session posture.
        #expect(h.redactionState.lastRunInputs?.appliedSearches == nil)
        let derived = h.coordinator.collectAppliedSearches()
        #expect(derived == [expectedRequest])
        #expect(h.coordinator.collectAppliedSearches() == derived, "the derivation is stable")

        let report = try await runVerifyOnly(h)

        let last = try recheckRow(report)
        #expect(last.status == .pass, "the `?? collectAppliedSearches()` fallback fed the layer")
        #expect(last.queryLines?.first?.appliedCount == 2)
        #expect(last.queryLines?.first?.foundCount == 2)

        // Recording retains exactly the derived set; clearing the output
        // drops it with the other run inputs.
        recordRunInputs(h, mode: .searchableRedaction)
        #expect(h.redactionState.lastRunInputs?.appliedSearches == derived)
        h.redactionState.clearOutput()
        #expect(h.redactionState.lastRunInputs?.appliedSearches == nil)
        #expect(h.redactionState.lastRunInputs?.sensitiveTerms == nil)
    }

    // MARK: - Cancellation

    @Test("Cancel race with an applied search never yields .verified + .pass with a skipped re-check")
    func cancelRaceWithAppliedSearch() async throws {
        let h = try await makeHarness(mode: .searchableRedaction)
        defer { h.removeOutput() }
        recordRunInputs(h, mode: .searchableRedaction)
        let retained = h.redactionState.lastRunInputs?.appliedSearches

        var rng = SeededLCG(seed: 0x5EA7_C4EC)
        var violations = 0
        var recheckSkippedUnderPass = 0
        for _ in 0..<80 {
            h.documentState.phase = .verified(report: .skipped)
            h.redactionState.outputURL = h.outputURL
            h.coordinator.runVerifyOnly()
            let task = h.documentState.activePipelineTask
            let jitterMillis = rng.next() % 50
            if jitterMillis > 0 {
                try? await Task.sleep(nanoseconds: jitterMillis * 1_000_000)
            }
            h.documentState.cancelActivePipeline(redactionState: h.redactionState)
            await task?.value

            if case .verified(let report) = h.documentState.phase {
                let hasSkipped = report.layers.contains { $0.status.isSkipped }
                let isPass = report.overallStatus == .pass
                if isPass && hasSkipped { violations += 1 }
                if isPass, report.layers.contains(where: { $0.layer == .searchRecheck && $0.status.isSkipped }) {
                    recheckSkippedUnderPass += 1
                }
            }
        }
        #expect(violations == 0, "a .verified .pass verdict must never coexist with a skipped layer")
        #expect(recheckSkippedUnderPass == 0, "a skipped re-check can never hide under PASS")
        // Cancellation leaves the retained inputs alone (the output survives
        // a cancel-from-verifying).
        #expect(h.redactionState.lastRunInputs?.appliedSearches == retained)
    }

    /// Numerical-Recipes LCG; fixed seed → reproducible jitter.
    private struct SeededLCG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }
}

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
    /// text search for the term (one result per page); otherwise one
    /// manual region stands in. Output on disk = `outputPageTexts`.
    private func makeHarness(
        outputPageTexts: [String],
        mode: PipelineMode,
        applyTerm: Bool = true
    ) async throws -> Harness {
        let coordinator = makeCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState
        let sourceData = textPagesPDFData([
            "Account holder \(Self.term) page one",
            "Balance for \(Self.term) page two",
        ])
        documentState.sourceDocument = PDFDocument(data: sourceData)
        try #require(documentState.pageCount == 2)

        if applyTerm {
            let search = SearchState()
            search.searchModeType = .text
            search.queryText = Self.term
            search.results = [
                SearchResult(
                    pageIndex: 0,
                    normalizedRect: CGRect(x: 0.25, y: 0.08, width: 0.15, height: 0.03),
                    matchedText: Self.term, contextSnippet: "…\(Self.term)…",
                    source: .textLayer, term: Self.term, isSelected: true),
                SearchResult(
                    pageIndex: 1,
                    normalizedRect: CGRect(x: 0.22, y: 0.08, width: 0.15, height: 0.03),
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
        try textPagesPDFData(outputPageTexts).write(to: outputURL)
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
        h.redactionState.recordLastRunInputs(
            perPageModes: Array(repeating: mode, count: h.documentState.pageCount),
            perPageFallbackReasons: Array(repeating: nil, count: h.documentState.pageCount),
            sensitiveTerms: h.coordinator.collectSensitiveTerms(),
            appliedSearches: h.coordinator.collectAppliedSearches())
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

    private var expectedRequest: SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .text(Self.term), options: SearchOptions()),
                foundCount: 2),
            appliedCount: 2,
            appliedPages: [0, 1])
    }

    // MARK: - PASS

    @Test("PASS end to end in Searchable: eleven layers, the re-check last, found 2 · applied 2 · 0 remain")
    func passSearchable() async throws {
        let h = try await makeHarness(
            outputPageTexts: ["Account holder page one", "Balance for page two"],
            mode: .searchableRedaction)
        defer { h.removeOutput() }
        #expect(h.coordinator.collectAppliedSearches() == [expectedRequest])
        recordRunInputs(h, mode: .searchableRedaction)
        #expect(h.redactionState.lastRunAppliedSearches == [expectedRequest])

        let report = try await runVerifyOnly(h)

        #expect(report.layers.count == 11)
        let last = try #require(report.layers.last)
        #expect(last.layer == .searchRecheck)
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
                == ["\u{201C}\(Self.term)\u{201D} · found 2 · applied 2 · 0 remain"])
        #expect(!report.layers.contains { $0.layer == .searchRecheck && $0.status.isSkipped })
        // Fixture honesty under the searchable rules: nothing FAILs; the
        // aggregate is at most the skip-induced WARN of the digest-less
        // verify-only path (Layers 7 / 9), never a verdict the fixture forged.
        #expect(!report.layers.contains { $0.status.isFail },
                "the Courier text fixture satisfies every searchable-mode layer")
        #expect(!report.overallStatus.isFail && !report.overallStatus.isAttention)
    }

    @Test("Secure Raster schedule: six layers, the re-check last with the same counts (text-layer fixture; Layer 1 reports the fixture's text, not this test's subject)")
    func passRaster() async throws {
        let h = try await makeHarness(
            outputPageTexts: ["Account holder page one", "Balance for page two"],
            mode: .secureRasterization)
        defer { h.removeOutput() }
        recordRunInputs(h, mode: .secureRasterization)

        let report = try await runVerifyOnly(h)

        #expect(report.layers.count == 6)
        let last = try #require(report.layers.last)
        #expect(last.layer == .searchRecheck)
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
        let h = try await makeHarness(
            outputPageTexts: ["Account holder page one", "Balance for \(Self.term) page two"],
            mode: .searchableRedaction)
        defer { h.removeOutput() }
        recordRunInputs(h, mode: .searchableRedaction)

        let report = try await runVerifyOnly(h)

        let last = try #require(report.layers.last)
        #expect(last.layer == .searchRecheck)
        #expect(last.status.isAttention)
        if case .attention(let message) = last.status {
            #expect(message == "Re-ran 1 search — 1 match remains on page 2")
            #expect(!message.contains(Self.term), "status messages stay content-free")
        }
        #expect(last.reviewTermTexts == [Self.term], "the BARE query text — the row quotes it itself")
        #expect(last.pageReferences == [1])
        #expect(last.queryLines?.first?.remainingCount == 1)
        #expect(LayerResultRow.rowSubtitleText(layer: last)
                == LayerResultRow.reviewRowText(termTexts: [Self.term], pages: [1]))
        #expect(LayerResultRow.queryLineTexts(layer: last)
                == ["\u{201C}\(Self.term)\u{201D} · found 2 · applied 2 · 1 remain"])

        // Layer 3 (Binary String Search) reads the same leftover from the
        // sensitive-term set — the accepted two-decoder cross-check — and
        // the masthead still names the text ONCE (deduped across layers).
        let layer3 = try #require(report.layers.first { $0.layer == .binaryStringSearch })
        #expect(layer3.status.isAttention, "Layer 3 flags the same leftover")
        #expect(report.overallStatus.isAttention)
        #expect(VerificationResultsView.reviewTermTexts(report: report) == [Self.term])
        #expect(VerificationResultsView.mastheadSubtitle(report: report)
                == "Unredacted text remains: '\(Self.term)'")
        #expect(VerificationResultsView.detailsSummaryText(for: report).contains("need review"))
    }

    // MARK: - INFO

    @Test("Zero applied searches → the re-check is an informational note counted as passed")
    func zeroSearchesIsInfo() async throws {
        let h = try await makeHarness(
            outputPageTexts: ["Account holder page one", "Balance for page two"],
            mode: .secureRasterization, applyTerm: false)
        defer { h.removeOutput() }
        #expect(h.coordinator.collectAppliedSearches().isEmpty)
        recordRunInputs(h, mode: .secureRasterization)
        #expect(h.redactionState.lastRunAppliedSearches == [])

        let report = try await runVerifyOnly(h)

        let last = try #require(report.layers.last)
        #expect(last.layer == .searchRecheck)
        #expect(last.status.isInfo)
        #expect(last.shortDescription == SearchRecheck.infoMessage)
        #expect(last.queryLines == nil)
        #expect(LayerResultRow.queryLineTexts(layer: last).isEmpty)
        #expect(!report.layers.contains { $0.status.isSkipped }, ".info never .skipped")

        // The Details summary counts INFO rows as passed and names them.
        let summary = VerificationResultsView.detailsSummaryText(for: report)
        let total = report.layers.count
        let passed = report.layers.filter { $0.status == .pass || $0.status.isInfo }.count
        let infoCount = report.layers.filter(\.status.isInfo).count
        #expect(infoCount >= 1)
        #expect(summary.contains("\(infoCount) informational note"))
        if report.overallStatus.isWarn {
            #expect(summary.hasPrefix("\(total) of \(total) checks completed"))
        } else {
            #expect(summary.hasPrefix("\(passed) of \(total) checks passed"))
        }
    }

    // MARK: - Resume path

    @Test("Verify-only with no retained inputs re-derives the same requests from the live audit")
    func resumeRefeedEquality() async throws {
        let h = try await makeHarness(
            outputPageTexts: ["Account holder page one", "Balance for page two"],
            mode: .searchableRedaction)
        defer { h.removeOutput() }
        // No `recordLastRunInputs`: the resumed-session posture.
        #expect(h.redactionState.lastRunAppliedSearches == nil)
        let derived = h.coordinator.collectAppliedSearches()
        #expect(derived == [expectedRequest])
        #expect(h.coordinator.collectAppliedSearches() == derived, "the derivation is stable")

        let report = try await runVerifyOnly(h)

        let last = try #require(report.layers.last)
        #expect(last.status == .pass, "the `?? collectAppliedSearches()` fallback fed the layer")
        #expect(last.queryLines?.first?.appliedCount == 2)
        #expect(last.queryLines?.first?.foundCount == 2)

        // Recording retains exactly the derived set; clearing the output
        // drops it with the other run inputs.
        recordRunInputs(h, mode: .searchableRedaction)
        #expect(h.redactionState.lastRunAppliedSearches == derived)
        h.redactionState.clearOutput()
        #expect(h.redactionState.lastRunAppliedSearches == nil)
        #expect(h.redactionState.lastRunSensitiveTerms == nil)
    }

    // MARK: - Cancellation

    @Test("Cancel race with an applied search never yields .verified + .pass with a skipped re-check")
    func cancelRaceWithAppliedSearch() async throws {
        let h = try await makeHarness(
            outputPageTexts: ["Account holder page one", "Balance for page two"],
            mode: .searchableRedaction)
        defer { h.removeOutput() }
        recordRunInputs(h, mode: .searchableRedaction)
        let retained = h.redactionState.lastRunAppliedSearches

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
        #expect(h.redactionState.lastRunAppliedSearches == retained)
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

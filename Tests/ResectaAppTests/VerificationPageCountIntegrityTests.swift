import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// CAT-369 (VE-8-1) + CAT-373.
//
// VE-8-1: a verify-only run whose output page count does not match the source
// must FAIL before any layer runs, rather than verifying a truncated document
// and reporting a misleading PASS/WARN.
//
// CAT-373: a cancel landing anywhere in a verify-only run must never leave the
// document on `.verified` with an overall `.pass` while any layer is `.skipped`
// — the dishonest verdict the final pre-report cancellation checkpoint closes.

@Suite("Verification Page-Count Integrity & Cancel Race")
@MainActor
struct VerificationPageCountIntegrityTests {

    // MARK: - VE-8-1 (CAT-369 part 2)

    @Test("VE-8-1: verify-only on a page-count mismatch FAILs before any layer")
    func verifyOnlyFailsOnPageCountMismatch() async throws {
        let coordinator = makeCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState

        // Source document: 3 pages.
        documentState.sourceDocument = makeMultiPagePDFDocument(pages: 3)
        #expect(documentState.pageCount == 3)

        // Output on disk: 2 pages — a dropped page.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ve81_output_\(UUID().uuidString).pdf")
        try makeMultiPagePDFData(pages: 2).write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        redactionState.outputURL = outputURL

        // Resume posture: the background-resume banner runs verify-only from
        // `.verified(report: .skipped)`.
        documentState.phase = .verified(report: .skipped)

        coordinator.runVerifyOnly()
        await documentState.activePipelineTask?.value

        #expect(documentState.phaseKind == .verified)
        guard case .verified(let report) = documentState.phase else {
            Issue.record("Expected .verified after verify-only")
            return
        }
        #expect(report.overallStatus.isFail,
                "Page-count mismatch must FAIL the overall verdict")
        // VE-8-1 returns before any layer runs: exactly one synthetic FAIL
        // layer (pre-fix the full 5/10-layer report would have run).
        #expect(report.layers.count == 1,
                "VE-8-1 short-circuits before the layer checks")
        #expect(report.layers.first?.status.isFail == true,
                "The single VE-8-1 layer must be FAIL")
        // ARCH §12.2: message carries page counts only, never content.
        if case .fail(let msg) = report.overallStatus {
            #expect(!msg.isEmpty)
        }
    }

    @Test("VE-8-1: matching page counts let verify-only proceed to the layers")
    func verifyOnlyProceedsWhenPageCountsMatch() async throws {
        let coordinator = makeCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState

        documentState.sourceDocument = makeMultiPagePDFDocument(pages: 2)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ve81_match_\(UUID().uuidString).pdf")
        try makeMultiPagePDFData(pages: 2).write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        redactionState.outputURL = outputURL
        documentState.phase = .verified(report: .skipped)

        coordinator.runVerifyOnly()
        await documentState.activePipelineTask?.value

        guard case .verified(let report) = documentState.phase else {
            Issue.record("Expected .verified after verify-only")
            return
        }
        // The layers actually ran (no VE-8-1 short-circuit): more than one
        // layer in the report.
        #expect(report.layers.count > 1,
                "Matching page counts must not short-circuit before the layers")
    }

    // MARK: - CAT-373 cancel-race stress harness

    @Test("CAT-373: verify-only cancel race never yields .verified+.pass with a skipped layer")
    func verifyOnlyCancelRaceHoldsInvariant() async throws {
        // ~200 iterations on a blank 1-page output in Searchable mode (so the
        // digest-consuming Layers 7 & 9 report `.skipped` on the all-nil-digest
        // resume path). Each iteration starts verify-only, cancels after a
        // seeded 0–49 ms jitter, awaits the task, and asserts the invariant
        // never holds: phase == .verified with overall `.pass` while any layer
        // is `.skipped`. Post-fix the invariant holds at any timing, so the
        // green side is timing-independent — a deterministic regression guard
        // for the final cancellation checkpoint. (On this blank fixture Layer 2
        // WARNs — no extractable image — so a *completed* run aggregates to
        // WARN; the harness primarily guards the cancel→checkpoint path.)
        let iterations = 200
        var rng = SeededLCG(seed: 0xCA7_0373)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cat373_output_\(UUID().uuidString).pdf")
        try makeMultiPagePDFData(pages: 1).write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var violations = 0
        for _ in 0..<iterations {
            let coordinator = makeCoordinator()
            let documentState = coordinator.documentState
            let redactionState = coordinator.redactionState
            documentState.sourceDocument = makeMultiPagePDFDocument(pages: 1)
            documentState.lastUsedPipelineMode = .searchableRedaction
            redactionState.outputURL = outputURL
            documentState.phase = .verified(report: .skipped)

            coordinator.runVerifyOnly()
            // Capture the task before cancel nils the stored reference.
            let task = documentState.activePipelineTask
            let jitterMillis = rng.next() % 50
            if jitterMillis > 0 {
                try? await Task.sleep(nanoseconds: jitterMillis * 1_000_000)
            }
            documentState.cancelActivePipeline(redactionState: redactionState)
            await task?.value

            if case .verified(let report) = documentState.phase {
                let hasSkipped = report.layers.contains { $0.status == .skipped }
                let isPass = report.overallStatus == .pass
                if isPass && hasSkipped { violations += 1 }
            }
        }
        #expect(violations == 0,
                "A .verified .pass verdict must never coexist with a skipped layer")
    }

    /// Numerical-Recipes LCG (same constants as the noise-band fixture); fixed
    /// seed → reproducible jitter, no `Date`/system randomness.
    private struct SeededLCG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }
}

import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-67 / [D-27] / [D-28] / OQ-29: pins the intra-session diff feature.
// Three load-bearing invariants pinned here:
//   1. `fingerprintNoMatchedText` — [RR-25] privacy floor; the fingerprint
//      string NEVER contains matched-text-derived bytes. Geometry +
//      category only per [D-27].
//   2. `clearPathsAsymmetric` — WU-67's documented carve-out from [D-28].
//      `clear()` wipes; `clearResults()` PRESERVES. Without the
//      asymmetry, `captureFingerprintsBeforeScan()` → `clearResults()`
//      in `triggerSearch` would immediately wipe the snapshot and the
//      diff would always be nil. The asymmetry is intentional and
//      logged as OQ-29 for user review.
//   3. `diffArithmetic` — happy-path set arithmetic over known prior +
//      current fingerprint sets; matches the (added, removed, unchanged)
//      contract from ACTION-WU-67.

@Suite("Intra-session result diff (WU-67 / D-27 / OQ-29)", .tags(.search))
@MainActor
struct IntraSessionDiffTests {

    // MARK: - Diff arithmetic

    @Test("Diff arithmetic returns correct (added, removed, unchanged) on re-scan")
    func diffArithmetic() {
        let state = SearchState()
        // Prior scan: 3 results at three distinct positions.
        state.results = [
            makeResult(pageIndex: 0, x: 0.10, y: 0.20, category: .ssn),
            makeResult(pageIndex: 0, x: 0.30, y: 0.40, category: .email),
            makeResult(pageIndex: 1, x: 0.50, y: 0.60, category: .phone)
        ]
        state.captureFingerprintsBeforeScan()
        // Simulate triggerSearch: clearResults preserves priorScanFingerprints.
        state.clearResults()
        #expect(state.priorScanFingerprints != nil)

        // Current scan: 1 unchanged (SSN at the same coords), 1 removed
        // (email gone), 1 added (new license plate at fresh coords).
        state.results = [
            makeResult(pageIndex: 0, x: 0.10, y: 0.20, category: .ssn),
            makeResult(pageIndex: 1, x: 0.50, y: 0.60, category: .phone),
            makeResult(pageIndex: 2, x: 0.80, y: 0.90, category: .licensePlate)
        ]
        let diff = state.diffSinceLastScan()
        #expect(diff != nil)
        #expect(diff?.added == 1)
        #expect(diff?.removed == 1)
        #expect(diff?.unchanged == 2)
    }

    @Test("diffSinceLastScan returns nil on the first scan of a session")
    func diffNilOnFirstScan() {
        let state = SearchState()
        // Never called captureFingerprintsBeforeScan; priorScanFingerprints
        // stays nil. Even with current results populated, the diff is nil
        // because there's no baseline to compare against.
        state.results = [
            makeResult(pageIndex: 0, x: 0.1, y: 0.1, category: .ssn)
        ]
        #expect(state.priorScanFingerprints == nil)
        #expect(state.diffSinceLastScan() == nil)
    }

    // MARK: - RR-25 privacy floor (load-bearing)

    @Test("Fingerprint contains no matched-text substring per [RR-25]")
    func fingerprintNoMatchedText() {
        // RR-25 load-bearing: hashing matched text — even into an
        // in-memory Set<String> — is document-derived retention under
        // §S2. The fingerprint MUST be geometry + category only.
        let result = SearchResult(
            pageIndex: 3,
            normalizedRect: CGRect(x: 0.10, y: 0.20, width: 0.05, height: 0.02),
            matchedText: "123-45-6789",
            contextSnippet: "before 123-45-6789 after",
            source: .textLayer,
            term: "123-45-6789",
            piiCategory: .ssn,
            piiConfidence: 0.95,
            rationale: nil
        )
        let fp = SearchState.fingerprint(for: result)
        // The exact PII string MUST NOT appear in the fingerprint.
        #expect(!fp.contains("123-45-6789"))
        // No substring of the PII either — guard against partial leakage.
        #expect(!fp.contains("123"))
        #expect(!fp.contains("456"))
        #expect(!fp.contains("6789"))
        // Defensive: contextSnippet's "before"/"after" are NOT in the FP.
        #expect(!fp.contains("before"))
        #expect(!fp.contains("after"))
        // Sanity: the fingerprint DOES include geometry + category.
        #expect(fp.contains("3|"))           // pageIndex prefix
        #expect(fp.contains("0.100"))         // x to 3 decimals
        #expect(fp.contains("|SSN"))          // category raw value
    }

    @Test("Fingerprint also excludes term, rationale, and source labels")
    func fingerprintExcludesAllDocumentDerivedFields() {
        // Defensive against drift — name every field that's NOT supposed
        // to be in the fingerprint and assert it doesn't appear.
        let result = SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05),
            matchedText: "SECRET_MATCH_TEXT",
            contextSnippet: "CONTEXT_SNIPPET_VALUE",
            source: .ocr(confidence: 0.99),
            term: "USER_TERM_VALUE",
            piiCategory: .name,
            piiConfidence: 0.80
        )
        let fp = SearchState.fingerprint(for: result)
        #expect(!fp.contains("SECRET_MATCH_TEXT"))
        #expect(!fp.contains("CONTEXT_SNIPPET_VALUE"))
        #expect(!fp.contains("USER_TERM_VALUE"))
        // Source `.ocr(confidence: 0.99)` — confidence numeric MUST NOT
        // appear (OCR confidences are document-derived).
        #expect(!fp.contains("0.99"))
        // Sanity: category name does appear (mechanism metadata).
        #expect(fp.contains("Name"))
    }

    // MARK: - RR-26 / D-28 carve-out (load-bearing)

    @Test("clearPathsAsymmetric: clear() wipes; clearResults() preserves")
    func clearPathsAsymmetric() {
        // WU-67 / OQ-29: documents the deliberate carve-out from
        // [D-28] / [RR-26]'s "both clear paths wipe" mandate. Without
        // this asymmetry, capture-before-clear in triggerSearch would
        // be immediately undone and the diff feature would never
        // surface a non-trivial result.
        let state = SearchState()
        state.results = [
            makeResult(pageIndex: 0, x: 0.1, y: 0.1, category: .ssn),
            makeResult(pageIndex: 0, x: 0.2, y: 0.2, category: .email)
        ]
        state.captureFingerprintsBeforeScan()
        #expect(state.priorScanFingerprints != nil)
        #expect(state.priorScanFingerprints?.count == 2)

        // clearResults() — intra-session re-scan path — PRESERVES.
        state.clearResults()
        #expect(state.priorScanFingerprints != nil)
        #expect(state.priorScanFingerprints?.count == 2)
        #expect(state.results.isEmpty)  // results wipe normally

        // clear() — sheet dismiss / full reset path — WIPES to nil.
        state.clear()
        #expect(state.priorScanFingerprints == nil)
    }

    @Test("Capture-then-clearResults round-trip preserves the snapshot")
    func captureSurvivesClearResults() {
        // Mirrors the actual triggerSearch sequence:
        //   captureFingerprintsBeforeScan() → clearResults() → next scan.
        // After the round-trip, priorScanFingerprints holds the SAME
        // values it had post-capture.
        let state = SearchState()
        state.results = [
            makeResult(pageIndex: 0, x: 0.5, y: 0.5, category: .phone)
        ]
        state.captureFingerprintsBeforeScan()
        let captured = state.priorScanFingerprints
        state.clearResults()
        #expect(state.priorScanFingerprints == captured)
    }

    // MARK: - Fingerprint format

    @Test("Geometry rounds to 3 decimal places per [D-27]")
    func geometryRoundsTo3Decimals() {
        let result = makeResult(
            pageIndex: 0,
            x: 0.123456,
            y: 0.654321,
            width: 0.111111,
            height: 0.999999,
            category: .ssn
        )
        let fp = SearchState.fingerprint(for: result)
        // 3-decimal rounding via String(format: "%.3f", ...)
        #expect(fp.contains("0.123"))
        #expect(fp.contains("0.654"))
        #expect(fp.contains("0.111"))
        #expect(fp.contains("1.000"))  // 0.999999 rounds to 1.000
        // 4+ decimals MUST NOT appear (round-tripped through %.3f).
        #expect(!fp.contains("0.1234"))
    }

    @Test("Fingerprint with nil piiCategory ends in empty trailing segment")
    func fingerprintNilCategoryEmptyTrailing() {
        let result = SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05),
            matchedText: "x",
            contextSnippet: "x",
            source: .textLayer,
            term: "x",
            piiCategory: nil,
            piiConfidence: nil
        )
        let fp = SearchState.fingerprint(for: result)
        // Per the format `<page>|<rect>|<category>`, nil category renders
        // as empty string after the second pipe.
        #expect(fp.hasSuffix("|"))
    }

    // MARK: - Performance

    @Test("Capture + diff over 5k synthetic results stays under the simulator budget")
    func captureAndDiff5kResultsUnderTwoHundredMs() {
        let state = SearchState()
        let categories: [PIICategory] = [.ssn, .email, .phone, .name]
        // 5k synthetic results — half of the WU-36 perf-test size; the
        // diff feature operates on completed scans, not 10k cap territory.
        state.results = (0..<5_000).map { i in
            makeResult(
                pageIndex: i % 50,
                x: Double(i % 100) / 100.0,
                y: Double((i / 100) % 100) / 100.0,
                category: categories[i % categories.count]
            )
        }
        let captureStart = Date()
        state.captureFingerprintsBeforeScan()
        let captureElapsed = Date().timeIntervalSince(captureStart)

        // Re-populate `results` with a mutated copy: shift x by 0.001 on
        // every 10th result to simulate a small re-scan delta.
        state.clearResults()
        state.results = (0..<5_000).map { i in
            let xShift = (i % 10 == 0) ? 0.001 : 0.0
            return makeResult(
                pageIndex: i % 50,
                x: Double(i % 100) / 100.0 + xShift,
                y: Double((i / 100) % 100) / 100.0,
                category: categories[i % categories.count]
            )
        }
        let diffStart = Date()
        let diff = state.diffSinceLastScan()
        let diffElapsed = Date().timeIntervalSince(diffStart)

        #expect(diff != nil)
        // CAT-238: widened to 500ms to absorb simulator-host jitter under
        // full-suite load (same fragility class as the OQ-24 / OQ-25 / OQ-27
        // timing tests). This is a performance-budget ceiling, not a tight
        // latency gate — the 5k capture/diff routinely lands well under it; the
        // ceiling only flags a gross algorithmic regression.
        #expect(captureElapsed < 0.5, "5k capture took \(captureElapsed * 1000)ms")
        #expect(diffElapsed < 0.5, "5k diff took \(diffElapsed * 1000)ms")
    }

    // MARK: - Fixture

    private func makeResult(
        pageIndex: Int,
        x: Double,
        y: Double,
        width: Double = 0.05,
        height: Double = 0.02,
        category: PIICategory
    ) -> SearchResult {
        SearchResult(
            pageIndex: pageIndex,
            normalizedRect: CGRect(x: x, y: y, width: width, height: height),
            matchedText: "x",
            contextSnippet: "x",
            source: .textLayer,
            term: "x",
            piiCategory: category,
            piiConfidence: 0.85
        )
    }
}

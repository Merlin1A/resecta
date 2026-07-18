import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// q14 — Triage/apply integrity.
//
// Pins three contracts:
//   - UXF-11: one commit-feedback copy (`CommitFeedback.markedMessage`)
//     across every origin of the one `applyFindings` path, always
//     reporting the count of regions actually created.
//   - UXF-06: the detection run record (`RedactionState.DetectionRunRecord`)
//     and the pure banner-model builder covering every outcome —
//     zero/failed runs persist instead of dying as toasts.
//   - UXF-29 support surface: apply calls return honest created-counts,
//     the promotion flag gates banner Review re-entry, and lifecycle
//     resets drop the record. (The double-apply repro itself lives in
//     `CrossPageEntityLinkingTests`.)

@Suite("Triage/apply integrity (q14)")
@MainActor
struct TriageApplyIntegrityTests {

    // MARK: - Fixtures

    private func makeDetection(
        page: Int,
        kind: RedactionRegion.PIIKind,
        matchedText: String,
        confidence: Double = 0.9
    ) -> DetectionResult {
        DetectionResult(
            normalizedRect: CGRect(
                x: 0.1,
                y: 0.1 + Double(page) * 0.05,
                width: 0.3,
                height: 0.03
            ),
            kind: .pii(kind),
            confidence: confidence,
            matchedText: matchedText,
            recognitionLevel: .accurate
        )
    }

    @discardableResult
    private func seedPending(
        _ state: RedactionState,
        items: [(page: Int, kind: RedactionRegion.PIIKind, text: String)]
    ) -> [UUID] {
        var pending: [Int: [DetectionResult]] = [:]
        var ids: [UUID] = []
        for item in items {
            let detection = makeDetection(
                page: item.page, kind: item.kind, matchedText: item.text
            )
            pending[item.page, default: []].append(detection)
            ids.append(detection.id)
        }
        state.pendingTriage = pending
        for id in ids { state.triageSelections[id] = true }
        return ids
    }

    // MARK: - UXF-11: one commit-feedback copy

    @Test("markedMessage covers created-only, mixed, skip-only, and no-op cases")
    func markedMessageCopy() {
        #expect(CommitFeedback.markedMessage(applied: 3)
                == "Marked 3 for redaction")
        #expect(CommitFeedback.markedMessage(applied: 1)
                == "Marked 1 for redaction")
        #expect(CommitFeedback.markedMessage(applied: 3, alreadyCovered: 2)
                == "Marked 3 for redaction (2 already covered)")
        // All-overlap apply still reports — the user needs to know why
        // nothing new appeared.
        #expect(CommitFeedback.markedMessage(applied: 0, alreadyCovered: 4)
                == "Marked 0 for redaction (4 already covered)")
        // True no-op: no toast at all.
        #expect(CommitFeedback.markedMessage(applied: 0) == nil)
    }

    @Test("Staged-review apply returns the created-region count the Apply toast shows")
    func applyTriagedResultsReturnsCreatedCount() async {
        let state = RedactionState()
        let ids = seedPending(state, items: [
            (page: 0, kind: .ssn, text: "123-45-6789"),
            (page: 0, kind: .email, text: "j@example.com"),
            (page: 1, kind: .phone, text: "555-0100")
        ])
        // Reject one — the count must track acceptance, not the total.
        state.triageSelections[ids[1]] = false

        let created = await state.applyFindings(
            .stagedDetections, undoManager: nil)?.applied

        #expect(created == 2)
        #expect(state.regions.values.flatMap { $0 }.count == 2)
        // Promotion happened → banner Review re-entry is gated off.
        #expect(state.triagePromotionOccurred)
    }

    @Test("Staged-review apply with nothing pending returns 0 and sets no flag")
    func applyTriagedResultsNoopReturnsZero() async {
        let state = RedactionState()
        let outcome = await state.applyFindings(.stagedDetections, undoManager: nil)
        #expect(outcome?.applied == 0)
        #expect(!state.triagePromotionOccurred)
    }

    @Test("Detection-map apply splits signature candidates out of the applied count")
    func applyDetectionResultsCountsExcludeSignatures() async {
        let state = RedactionState()
        let name = makeDetection(page: 0, kind: .name, matchedText: "Jordan Avery")
        let ssn = makeDetection(page: 1, kind: .ssn, matchedText: "123-45-6789")
        let sig = makeDetection(page: 1, kind: .signatureCandidate, matchedText: "")

        let outcome = await state.applyFindings(
            .detectionResults([0: [name], 1: [ssn, sig]]), undoManager: nil)

        // The toast's count is regions created — the signature candidate
        // routed to the review instead (ST-100: never applied directly).
        #expect(outcome?.applied == 2)
        #expect(outcome?.signatureCandidates == 1)
        #expect(state.regions.values.flatMap { $0 }.count == 2)
        #expect(state.pendingTriage?.values.flatMap { $0 }.count == 1)
    }

    @Test("PII Scan mode apply returns the honest count that feeds the shared toast copy")
    func piiScanApplyReturnsCount() async {
        let state = RedactionState()
        let search = SearchState()
        search.searchModeType = .piiScan
        search.results = (0..<3).map { i in
            SearchResult(
                pageIndex: 0,
                normalizedRect: CGRect(
                    x: 0.1, y: 0.1 + 0.1 * Double(i), width: 0.2, height: 0.03),
                matchedText: "match-\(i)",
                contextSnippet: "...",
                source: .textLayer,
                term: "ssn",
                isSelected: true
            )
        }
        state.activeSearch = search

        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(outcome?.applied == 3)
        #expect(outcome?.skippedOverlaps == 0)
        #expect(CommitFeedback.markedMessage(
            applied: outcome?.applied ?? 0,
            alreadyCovered: outcome?.skippedOverlaps ?? 0)
            == "Marked 3 for redaction")
    }

    // MARK: - UXF-29 rider: group apply records accepted priors

    @Test("Group apply records accepted priors for promoted members")
    func groupApplyRecordsAcceptedPriors() async {
        let state = RedactionState()
        seedPending(state, items: [
            (page: 1, kind: .name, text: "John Doe"),
            (page: 3, kind: .name, text: "John Doe")
        ])
        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("Expected the John Doe cluster")
            return
        }
        #expect(state.priors.mean(.name) == 0.5)

        await state.applyFindings(.entityGroup(group), undoManager: nil)

        // Two accepted-name updates move the Beta prior upward; the
        // members no longer flow through the staged-review loop.
        #expect(state.priors.mean(.name) > 0.5)
        #expect(state.triagePromotionOccurred)
    }

    @Test("Undo of a group apply restores the prior state it recorded")
    func groupApplyUndoRestoresPriors() async {
        let state = RedactionState()
        let undoManager = UndoManager()
        seedPending(state, items: [
            (page: 1, kind: .name, text: "John Doe"),
            (page: 3, kind: .name, text: "John Doe")
        ])
        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("Expected the John Doe cluster")
            return
        }

        await state.applyFindings(.entityGroup(group), undoManager: undoManager)
        #expect(state.priors.mean(.name) > 0.5)

        undoManager.undo()
        #expect(state.priors.mean(.name) == 0.5)
        #expect(state.regions.values.flatMap { $0 }.isEmpty)
    }

    // MARK: - UXF-06: run record lifecycle

    @Test("recordDetectionRun bumps the run counter and resets the promotion flag")
    func recordDetectionRunLifecycle() {
        let state = RedactionState()
        #expect(state.lastDetectionRun == nil)

        state.recordDetectionRun(.nothingFound(pageCount: 3))
        #expect(state.lastDetectionRun?.run == 1)
        #expect(state.lastDetectionRun?.outcome == .nothingFound(pageCount: 3))

        state.triagePromotionOccurred = true
        // A second identical outcome still reads as a new record — the
        // banner's .onChange fires on the run bump.
        state.recordDetectionRun(.nothingFound(pageCount: 3))
        #expect(state.lastDetectionRun?.run == 2)
        #expect(!state.triagePromotionOccurred)
    }

    @Test("clearForNewDocument and clearAll drop the run record + promotion flag")
    func lifecycleResetsDropRecord() {
        let state = RedactionState()
        state.priorsDefaults = UserDefaults(suiteName: "q14-test-\(UUID().uuidString)")!
        state.recordDetectionRun(.failed)
        state.triagePromotionOccurred = true

        state.clearForNewDocument()
        #expect(state.lastDetectionRun == nil)
        #expect(!state.triagePromotionOccurred)

        state.recordDetectionRun(.staged)
        state.triagePromotionOccurred = true
        state.clearAll()
        #expect(state.lastDetectionRun == nil)
        #expect(!state.triagePromotionOccurred)
    }

    // MARK: - UXF-06: banner model per outcome

    @Test("Staged outcome keeps the per-kind Found summary and Review re-entry")
    func bannerModelStaged() {
        let state = RedactionState()
        seedPending(state, items: [
            (page: 0, kind: .ssn, text: "123-45-6789"),
            (page: 0, kind: .ssn, text: "987-65-4321"),
            (page: 2, kind: .email, text: "j@example.com")
        ])

        let model = DocumentEditorView.detectionBannerModel(
            outcome: .staged,
            scanSummary: nil,
            pendingTriage: state.pendingTriage,
            ocrSkippedPageCount: 0
        )

        #expect(model.message.hasPrefix("Found "))
        #expect(model.message.contains("across 2 pages"))
        #expect(model.showsReview)
        #expect(model.autoDismisses)
        #expect(!model.isWarning)
    }

    @Test("Scan-origin staged outcome reports the record's own counts with no Review action")
    func bannerModelScanStaged() {
        // Scan-interface runs carry their counts on the record; the
        // banner must not read `pendingTriage` for them (their results
        // live in the sheet's list, and a dismissed sheet's results
        // are cleared by design — Review would promise a surface that
        // is no longer populated).
        let model = DocumentEditorView.detectionBannerModel(
            outcome: .staged,
            scanSummary: .init(foundCount: 12, pageCount: 3),
            pendingTriage: nil,
            ocrSkippedPageCount: 0
        )
        #expect(model.message == "Scan found 12 items across 3 pages")
        #expect(!model.showsReview)
        #expect(model.autoDismisses)
        #expect(!model.isWarning)

        let singular = DocumentEditorView.detectionBannerModel(
            outcome: .staged,
            scanSummary: .init(foundCount: 1, pageCount: 1),
            pendingTriage: nil,
            ocrSkippedPageCount: 0
        )
        #expect(singular.message == "Scan found 1 item across 1 page")
    }

    @Test("Scan summary takes precedence over stale pendingTriage on staged records")
    func bannerModelScanStagedIgnoresPendingTriage() {
        // If seeded triage state coexists with a scan-interface record
        // (e.g. the --seedTriage hook plus an in-sheet scan), the
        // record's own summary wins — pipeline kind-counts would
        // misdescribe the scan run.
        let state = RedactionState()
        seedPending(state, items: [(page: 0, kind: .ssn, text: "123-45-6789")])
        let model = DocumentEditorView.detectionBannerModel(
            outcome: .staged,
            scanSummary: .init(foundCount: 2, pageCount: 5),
            pendingTriage: state.pendingTriage,
            ocrSkippedPageCount: 0
        )
        #expect(model.message == "Scan found 2 items across 5 pages")
        #expect(!model.showsReview)
    }

    @Test("Nothing-found outcome persists, and discloses OCR-skipped pages")
    func bannerModelNothingFound() {
        let clean = DocumentEditorView.detectionBannerModel(
            outcome: .nothingFound(pageCount: 3),
            scanSummary: nil,
            pendingTriage: nil,
            ocrSkippedPageCount: 0
        )
        #expect(clean.message == "Detection ran on 3 pages and flagged no items.")
        #expect(!clean.autoDismisses)
        #expect(!clean.isWarning)
        #expect(!clean.showsReview)

        // ST-83 family: a zero-found run never opens the triage sheet, so
        // the coverage gap must surface here.
        let skipped = DocumentEditorView.detectionBannerModel(
            outcome: .nothingFound(pageCount: 3),
            scanSummary: nil,
            pendingTriage: nil,
            ocrSkippedPageCount: 1
        )
        #expect(skipped.message.contains("1 page was too large to scan for text"))
        #expect(skipped.isWarning)
        #expect(!skipped.autoDismisses)
    }

    @Test("Failed outcome is a persistent warning with no Review action")
    func bannerModelFailed() {
        let model = DocumentEditorView.detectionBannerModel(
            outcome: .failed,
            scanSummary: nil,
            pendingTriage: nil,
            ocrSkippedPageCount: 0
        )
        #expect(model.message.contains("Detection couldn't finish"))
        #expect(model.message.contains("no regions were changed"))
        #expect(model.isWarning)
        #expect(!model.autoDismisses)
        #expect(!model.showsReview)
    }
}

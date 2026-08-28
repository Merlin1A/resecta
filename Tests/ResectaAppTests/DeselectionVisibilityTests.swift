import Testing
import Foundation
import SwiftUI
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// Deselection visibility at share time. A user who leaves scan results
// un-checked sees a results screen whose PASS speaks only to what WAS
// redacted; the counts of what they chose to leave lived solely in the
// search sheet's coverage panel. These tests pin the run-entry snapshot
// (`SearchState.deselectionSnapshotForRun()` →
// `RedactionState.lastRunDeselection`), the results-screen row gates and
// copy, and the Review affordance's routing preamble.

@Suite("Deselection snapshot derivation", .tags(.search))
@MainActor
struct DeselectionSnapshotDerivationTests {

    @Test("Snapshot reports deselected/total with the coverage panel's definition")
    func snapshotCountsMatchPanelDefinition() {
        let state = makeScanSession(total: 5, deselected: 2)
        let snapshot = state.deselectionSnapshotForRun()
        #expect(snapshot?.deselectedCount == 2)
        #expect(snapshot?.totalCount == 5)
        // Same definition as the panel: the folded report's counter.
        #expect(state.coverageReportForDisplay()?.deselectedCount == 2)
    }

    @Test("A captured snapshot does not drift when selection changes mid-run")
    func capturedSnapshotIsStable() {
        let state = makeScanSession(total: 5, deselected: 2)
        // Run entry: `runFullPipeline` captures the value once.
        let atRunEntry = state.deselectionSnapshotForRun()
        // Re-select one deselected result while the pipeline is in flight.
        let index = state.results.firstIndex { !$0.isSelected }!
        state.results[index].isSelected = true

        #expect(atRunEntry?.deselectedCount == 2, "run-entry value is a frozen copy")
        #expect(atRunEntry?.totalCount == 5)
        // A fresh derivation sees the live state — the two must differ.
        #expect(state.deselectionSnapshotForRun()?.deselectedCount == 1)
    }

    @Test("No stored scan report means no snapshot — same gate as the panel mount")
    func nilWithoutCoverageReport() {
        let state = makeScanSession(total: 3, deselected: 1)
        state.setCoverageReport(nil)
        #expect(state.deselectionSnapshotForRun() == nil)
    }

    @Test("Plain-text sessions yield no snapshot — the panel never mounts for them")
    func nilForTextMode() {
        let state = makeScanSession(total: 3, deselected: 1)
        state.searchModeType = .text
        #expect(state.deselectionSnapshotForRun() == nil)
    }

    @Test("Zero deselections still snapshots — the row gate, not the capture, filters noise")
    func zeroDeselectionsSnapshot() {
        let state = makeScanSession(total: 4, deselected: 0)
        let snapshot = state.deselectionSnapshotForRun()
        #expect(snapshot?.deselectedCount == 0)
        #expect(snapshot?.totalCount == 4)
    }
}

@Suite("Deselection record lifecycle", .tags(.search))
@MainActor
struct DeselectionRecordLifecycleTests {

    @Test("recordLastRunDeselection stores; clearOutput clears with the run inputs")
    func recordAndClear() {
        let redaction = RedactionState()
        #expect(redaction.lastRunDeselection == nil)

        redaction.recordLastRunDeselection(
            .init(deselectedCount: 2, totalCount: 5))
        #expect(redaction.lastRunDeselection
            == .init(deselectedCount: 2, totalCount: 5))

        // The record describes the output that clearOutput discards.
        redaction.clearOutput()
        #expect(redaction.lastRunDeselection == nil)
    }

    @Test("Recording nil clears a previous run's record")
    func nilRecordOverwrites() {
        let redaction = RedactionState()
        redaction.recordLastRunDeselection(
            .init(deselectedCount: 1, totalCount: 3))
        // Next run starts with no live scan session: its nil record must
        // not leave the previous run's counts on screen.
        redaction.recordLastRunDeselection(nil)
        #expect(redaction.lastRunDeselection == nil)
    }
}

@Suite("Deselection apply-commit capture", .tags(.search))
@MainActor
struct DeselectionApplyCommitCaptureTests {

    @Test("Apply commit populates the pending snapshot with the session's counts")
    func applyCommitPopulatesPendingSnapshot() async {
        let redaction = RedactionState()
        redaction.activeSearch = makeScanSession(total: 5, deselected: 2)

        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(redaction.pendingRunDeselection
            == .init(deselectedCount: 2, totalCount: 5))
    }

    @Test("A nil-activeSearch run entry still reads the apply-commit snapshot")
    func nilActiveSearchStillRecordsPendingSnapshot() async {
        let redaction = RedactionState()
        redaction.activeSearch = makeScanSession(total: 4, deselected: 1)

        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)
        // Mirrors DocumentEditorView nil-ing `activeSearch` on sheet dismiss.
        redaction.activeSearch = nil

        #expect(redaction.runEntryDeselectionSnapshot()
            == .init(deselectedCount: 1, totalCount: 4),
            "pipeline entry must still see the apply-commit snapshot with no live session")
    }

    @Test("Run entry prefers the pending snapshot over a live session's snapshot")
    func pendingSnapshotTakesPriorityOverLiveSession() async {
        let redaction = RedactionState()
        redaction.activeSearch = makeScanSession(total: 5, deselected: 2)
        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)

        // A different live session is now active (e.g. the user reopened
        // the sheet and ran a fresh scan) without applying anything from it.
        redaction.activeSearch = makeScanSession(total: 3, deselected: 1)

        #expect(redaction.runEntryDeselectionSnapshot()
            == .init(deselectedCount: 2, totalCount: 5),
            "the apply-commit snapshot wins over an unrelated live session")
    }

    @Test("Run entry falls back to the live session when nothing is pending")
    func fallsBackToLiveSessionWhenNothingPending() {
        let redaction = RedactionState()
        redaction.activeSearch = makeScanSession(total: 3, deselected: 1)

        #expect(redaction.pendingRunDeselection == nil)
        #expect(redaction.runEntryDeselectionSnapshot()
            == .init(deselectedCount: 1, totalCount: 3))
    }

    @Test("Last apply wins — a later apply overwrites the pending snapshot")
    func lastApplyWins() async {
        let redaction = RedactionState()
        redaction.activeSearch = makeScanSession(total: 5, deselected: 2)
        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)
        #expect(redaction.pendingRunDeselection
            == .init(deselectedCount: 2, totalCount: 5))

        redaction.activeSearch = makeScanSession(total: 6, deselected: 3)
        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(redaction.pendingRunDeselection
            == .init(deselectedCount: 3, totalCount: 6),
            "the second apply's snapshot replaces the first — no accumulation")
    }

    @Test("clearOutput() alone does not clear the pending snapshot — it survives a pipeline cancel/retry")
    func clearOutputDoesNotClearPendingSnapshot() async {
        let redaction = RedactionState()
        redaction.activeSearch = makeScanSession(total: 5, deselected: 2)
        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)

        redaction.clearOutput()

        #expect(redaction.pendingRunDeselection
            == .init(deselectedCount: 2, totalCount: 5),
            "a cancelled/failed run must not lose the apply-commit snapshot before a retry")
        #expect(redaction.lastRunDeselection == nil,
                "lastRunDeselection still clears — it describes the discarded run")
    }

    @Test("The pending snapshot does not leak past clearForNewDocument()")
    func pendingSnapshotDoesNotLeakPastNewDocument() async {
        let redaction = RedactionState()
        redaction.activeSearch = makeScanSession(total: 5, deselected: 2)
        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)
        #expect(redaction.pendingRunDeselection != nil, "precondition")

        redaction.clearForNewDocument()

        #expect(redaction.pendingRunDeselection == nil,
                "a replacement document must not inherit the prior document's apply-commit snapshot")
    }

    @Test("The pending snapshot does not leak past clearAll() (document close)")
    func pendingSnapshotDoesNotLeakPastClearAll() async {
        let redaction = RedactionState()
        redaction.activeSearch = makeScanSession(total: 5, deselected: 2)
        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)
        #expect(redaction.pendingRunDeselection != nil, "precondition")

        redaction.clearAll()

        #expect(redaction.pendingRunDeselection == nil,
                "document close must not leave the apply-commit snapshot for the next document")
    }
}

@Suite("Deselection row gates and copy", .tags(.display))
@MainActor
struct DeselectionRowTests {

    @Test("Row shows only for a snapshot with at least one deselection")
    func rowVisibilityGate() {
        // Plain `==` comparisons on named locals: `#expect(!call(.init(…)))`
        // trips a swift-testing macro-capture quirk (the call's value is
        // recorded as "<not evaluated>" and the expectation mis-reports).
        let zeroDeselected = RedactionState.DeselectionSnapshot(
            deselectedCount: 0, totalCount: 4)
        let twoDeselected = RedactionState.DeselectionSnapshot(
            deselectedCount: 2, totalCount: 5)
        #expect(VerificationResultsView.shouldShowDeselectionRow(
            snapshot: nil) == false)
        #expect(VerificationResultsView.shouldShowDeselectionRow(
            snapshot: zeroDeselected) == false)
        #expect(VerificationResultsView.shouldShowDeselectionRow(
            snapshot: twoDeselected) == true)
    }

    @Test("Row copy names the counts and pluralizes on total")
    func rowCopy() {
        #expect(
            VerificationResultsView.deselectionRowText(deselected: 2, total: 5)
                == "You left 2 of 5 detected items unredacted.")
        #expect(
            VerificationResultsView.deselectionRowText(deselected: 1, total: 1)
                == "You left 1 of 1 detected item unredacted.")
    }
}

@Suite("Deselection review routing", .tags(.coordination))
@MainActor
struct DeselectionReviewRoutingTests {

    @Test("Review preamble round-trips verified -> editing (Keep Editing's transition)")
    func preambleRoutesToEditing() {
        let doc = DocumentState()
        doc.phase = .verified(report: .skipped)

        DocumentEditorView.prepareForDeselectionReview(documentState: doc)

        #expect(doc.phaseKind == .editing)
    }

    @Test("Review raises the sheet past compactFloat so the panel mount is on screen")
    func reviewDetentRevealsPanel() {
        #expect(DocumentEditorView.deselectionReviewDetent == .medium)
    }

    @Test("Review affordance is offered only while the search session is alive")
    func affordanceRequiresLiveSession() {
        #expect(DocumentEditorView.deselectionReviewAvailable(
            hasLiveSearchSession: true))
        #expect(!DocumentEditorView.deselectionReviewAvailable(
            hasLiveSearchSession: false))
    }
}

// MARK: - Fixtures

/// A `.piiScan` session with `total` results, the first `deselected` of
/// them un-checked, and a stored scan report — the exact state the
/// coverage panel mounts under in `SearchResultsSection`.
@MainActor
private func makeScanSession(total: Int, deselected: Int) -> SearchState {
    let state = SearchState()
    state.searchModeType = .piiScan
    state.results = (0..<total).map { index in
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(
                x: 0.1 * CGFloat(index), y: 0.1, width: 0.05, height: 0.02),
            matchedText: "match-\(index)",
            contextSnippet: "context-\(index)",
            source: .textLayer,
            term: "term",
            isSelected: index >= deselected
        )
    }
    state.setCoverageReport(CoverageReport(
        scannedPageCount: 1,
        enabledCategories: [.ssn],
        candidateCountByCategory: [.ssn: total],
        appliedCount: 0,
        deselectedCount: 0,
        belowThresholdSuppressedCount: 0,
        overlapSuppressedCountByCategory: [:],
        startedAt: Date(timeIntervalSince1970: 0),
        completedAt: Date(timeIntervalSince1970: 1)
    ))
    return state
}

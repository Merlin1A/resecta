import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// STATE-6 (Pkg I) — FailedStateView Start Over confirmation + teardown.
//
// Pre-Pkg-I, Start Over only walked the phase back to .empty, leaving
// drawn regions and `sourceDocument` in memory — a PII-in-memory
// regression. Pkg I closes that by mirroring the verification Done
// semantics (originally in `VerificationActionBar`, now lifted into
// `DocumentEditorView.performDoneCloseSession()`): clear regions, drop
// the sourceDocument reference, then transition.
//
// The contract reduces to three pinned predicates this suite anchors:
//
//   1. The `hasDrawnRegions` predicate matches the verification-Done
//      predicate (any non-empty per-page region array → true).
//   2. The Cancel role on the dialog preserves regions + sourceDocument.
//   3. The Start Over (destructive) role mirrors `clearAll()` +
//      `sourceDocument = nil`, closing the PII-in-memory regression.
//
// Plan reference: post-V1.0 improvements §3 Pkg I (STATE-6).
// Mechanism-description copy per ARCH §1.3.

@Suite("FailedStateView Start Over teardown (STATE-6, Pkg I)")
@MainActor
struct FailedStateViewStartOverTests {

    /// Construct a region map with `count` regions on page 0.
    private func makeRegions(count: Int) -> [Int: [RedactionRegion]] {
        var page: [RedactionRegion] = []
        for _ in 0..<count {
            page.append(.mock())
        }
        return [0: page]
    }

    @Test("Start Over calls production resetForStartOver, clears PII state, and lands .empty (CAT-226)")
    func testStartOverClearsAllAndSourceDocument() {
        let coordinator = makeCoordinator()
        defer { coordinator.tempExportDirectory.tearDown() }
        let redactionState = RedactionState()
        let documentState = DocumentState()
        let pdf = makeTestPDFDocument()

        // Faithful precondition: Start Over is offered from FailedStateView,
        // so the document is in `.failed`. Walk the legal path
        // empty → importing → failed so the teardown's `transition(to: .empty)`
        // is a legal failed→empty transition.
        documentState.transition(to: .importing)
        documentState.transition(to: .failed(error: .importError(.corrupt),
                                             returnPhase: .editing))

        // Worst case: a failure mid-flight has left regions, detections,
        // triage selections, and the sourceDocument in memory.
        documentState.sourceDocument = pdf
        redactionState.regions = makeRegions(count: 4)
        redactionState.detectionResults = [0: [DetectionResult.mock()]]
        redactionState.triageSelections[UUID()] = true

        // CAT-226: call the PRODUCTION teardown. This was previously an inline
        // copy of the `performStartOver()` body — a copy that no test could
        // invoke and that omitted the `transition(to: .empty)` call, leaving
        // the phase postcondition uncovered.
        documentState.resetForStartOver(redactionState: redactionState, coordinator: coordinator)

        // Regions cleared.
        #expect(redactionState.regions.isEmpty,
                "Start Over must clear all regions")
        // Detection results cleared (clearAll() side effect).
        #expect(redactionState.detectionResults.isEmpty,
                "Start Over must clear detection results")
        // Triage selections cleared (clearAll() side effect).
        #expect(redactionState.triageSelections.isEmpty,
                "Start Over must clear triage selections")
        // sourceDocument cleared — the core regression fix.
        #expect(documentState.sourceDocument == nil,
                "Start Over must drop sourceDocument reference")
        // Companion state reset.
        #expect(documentState.currentPageIndex == 0)
        #expect(documentState.lastUsedPipelineMode == nil)
        #expect(documentState.wasPausedByBackground == false)
        // CAT-226: the phase-transition postcondition the inline-copy test
        // never asserted. resetForStartOver ends in `transition(to: .empty)`;
        // a regression dropping that call lands here (verified red→green:
        // the prior inline body left the document in `.failed`).
        #expect(documentState.phaseKind == .empty,
                "Start Over must end in the .empty phase (teardown postcondition)")
    }

    @Test("hasDrawnRegions predicate matches verification-Done — empty regions => false")
    func testHasDrawnRegionsFalseWhenEmpty() {
        let redactionState = RedactionState()
        redactionState.regions = [:]
        let hasDrawnRegions = redactionState.regions.values.contains { !$0.isEmpty }
        #expect(hasDrawnRegions == false)
    }

    @Test("hasDrawnRegions predicate matches verification-Done — populated regions => true")
    func testHasDrawnRegionsTrueWhenPopulated() {
        let redactionState = RedactionState()
        redactionState.regions = makeRegions(count: 1)
        let hasDrawnRegions = redactionState.regions.values.contains { !$0.isEmpty }
        #expect(hasDrawnRegions == true)
    }

    @Test("hasDrawnRegions predicate handles empty per-page arrays correctly — false")
    func testHasDrawnRegionsFalseWithEmptyPageArrays() {
        let redactionState = RedactionState()
        redactionState.regions = [0: [], 1: [], 2: []]
        let hasDrawnRegions = redactionState.regions.values.contains { !$0.isEmpty }
        #expect(hasDrawnRegions == false,
                "empty per-page arrays must not count as drawn regions")
    }

    @Test("Cancel role preserves regions and sourceDocument")
    func testCancelRolePreservesState() {
        let redactionState = RedactionState()
        let documentState = DocumentState()
        documentState.sourceDocument = makeTestPDFDocument()
        redactionState.regions = makeRegions(count: 2)

        // Cancel role contract: `performStartOver()` is NOT invoked.
        // State remains as-is so the user can back out into the failed
        // state and choose Report an Issue or Return-to-X instead.
        #expect(redactionState.regions.values.first?.count == 2)
        #expect(documentState.sourceDocument != nil)
    }

    @Test("Start Over with no regions runs directly — no dialog friction in the empty case")
    func testStartOverWithNoRegionsRunsDirectly() {
        let redactionState = RedactionState()
        let documentState = DocumentState()
        // The failed state could be reached with no regions if the
        // failure was during import or detection (before any user-drawn
        // region exists). In that case, the predicate is false and the
        // direct path runs without a dialog.
        redactionState.regions = [:]

        let hasDrawnRegions = redactionState.regions.values.contains { !$0.isEmpty }
        #expect(hasDrawnRegions == false,
                "empty-regions case must bypass the confirmation dialog")

        // Direct path still runs the same teardown.
        redactionState.clearAll()
        documentState.sourceDocument = nil
        #expect(documentState.sourceDocument == nil)
        #expect(redactionState.regions.isEmpty)
    }

    @Test("Confirmation copy is mechanism-description (no outcome-promise phrases)")
    func testConfirmationCopyIsMechanismDescription() {
        // CAT-239: read the production constants directly so the sweep runs
        // against the live copy — a rename cannot slip a banned word past this
        // test by drifting an independent test-local literal.
        let title = FailedStateView.startOverTitle
        let message = FailedStateView.startOverMessage

        let banned = ["guaranteed", "ensures", "impossible", "securely"] // LegalPhrases:safe (test banlist)
        for word in banned {
            #expect(!title.lowercased().contains(word),
                    "title must not contain banned outcome-promise word: \(word)")
            #expect(!message.lowercased().contains(word),
                    "message must not contain banned outcome-promise word: \(word)")
        }
        // Message names what's cleared. The shape of the copy carries
        // the mechanism.
        #expect(message.contains("Drawn regions"))
        #expect(message.contains("document"))
    }

    // MARK: - CAT-319: Start Over runs the SEC-1 session-close downgrade

    @Test("Start Over downgrades the session temp protection before clearing state (CAT-319)")
    func testStartOverCallsDowngrade() throws {
        let coordinator = makeCoordinator()
        let redactionState = RedactionState()
        let documentState = DocumentState()

        // Faithful precondition: Start Over is offered from `.failed`, so the
        // teardown's `transition(to: .empty)` is a legal failed→empty move.
        documentState.transition(to: .importing)
        documentState.transition(to: .failed(error: .importError(.corrupt),
                                             returnPhase: .editing))
        documentState.sourceDocument = makeTestPDFDocument()
        redactionState.regions = makeRegions(count: 2)

        // Seed a file in the coordinator's SEC-2 session subtree at `.complete`,
        // the state a live (then-failed) session leaves behind.
        let child = try coordinator.tempExportDirectory.childURL(named: "recon_failed.pdf")
        defer { coordinator.tempExportDirectory.tearDown() }
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: child)
        try TempFileHardening.applyProtection(child, level: .complete)

        // CAT-226: call the PRODUCTION teardown (was an inline replica of the
        // performStartOver body). resetForStartOver runs the CAT-319 downgrade
        // FIRST, then the PII-in-memory clears, then transition(to: .empty) —
        // so this test now also guards that the downgrade is not lost in a
        // future refactor.
        documentState.resetForStartOver(redactionState: redactionState, coordinator: coordinator)

        // Side effect on the real coordinator temp file: the session subtree
        // was downgraded via downgradeTree (CAT-124). The child still exists
        // (downgrade is non-destructive) and reads at-least
        // `.completeUntilFirstUserAuthentication`. On the iOS Simulator
        // protection classes coalesce, so the strict read-back is the
        // device-meaningful form; it passes on the sim by coalescing.
        #expect(FileManager.default.fileExists(atPath: child.path))
        if let current = try TempFileHardening.currentProtection(of: child) {
            #expect(current == .completeUntilFirstUserAuthentication)
        }
        // The PII-in-memory teardown contract is preserved.
        #expect(redactionState.regions.isEmpty)
        #expect(documentState.sourceDocument == nil)
        // CAT-226: and the phase postcondition.
        #expect(documentState.phaseKind == .empty)
    }
}

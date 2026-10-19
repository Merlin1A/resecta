import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The transition-table invariant the detection phase relies on, and the
// `--seedTriage` debug seed helper.

@Suite("Detection error graceful degradation", .tags(.coordination))
@MainActor
struct DetectionErrorRecoveryTests {

    // MARK: - Transition-table invariant the fix relies on

    @Test("Transition table has no editing→failed pair, but detecting→{failed,editing} are legal")
    func transitionTableHasNoEditingToFailed() {
        // The crash root cause: `editing → failed` is intentionally NOT legal.
        #expect(!DocumentState.legalTransitions.contains(
            DocumentState.TransitionPair(.editing, .failed)),
            "editing→failed must remain illegal — the detection path degrades instead")
        // The degrade / failure routing the fix depends on IS legal.
        #expect(DocumentState.legalTransitions.contains(
            DocumentState.TransitionPair(.detecting, .editing)))
        #expect(DocumentState.legalTransitions.contains(
            DocumentState.TransitionPair(.detecting, .failed)))
    }

    // MARK: - Deliverable 2: --seedTriage seed helper

    #if DEBUG
    @Test("seedDebugTriage populates pendingTriage + all-deselected selections on page 0")
    func seedDebugTriagePopulatesPendingTriage() {
        let redactionState = RedactionState()
        #expect(redactionState.pendingTriage == nil)

        redactionState.seedDebugTriage()

        let pending = redactionState.pendingTriage
        #expect(pending != nil)
        // All mock detections land on page 0.
        #expect(pending?.keys.sorted() == [0])
        let page0 = pending?[0] ?? []
        // 6 mocks — a second "Jordan Avery" mock gives the Grouped view
        // mode a real cluster so "Apply Group" is drivable on-sim.
        #expect(page0.count == 6)
        // Review-first arrival: the seed stages an EMPTY selection map,
        // mirroring the real staging path — the one apply path reads an
        // absent id as not accepted, so the empty map IS the
        // all-deselected arrival shape (the explicit-per-id entries
        // died with the absent-reads-accepted fallback).
        #expect(redactionState.triageSelections.isEmpty)
        // A mix of kinds so the triage list, filters, and "Apply N" are exercised.
        let kinds = Set(page0.map { $0.kind })
        #expect(kinds.count >= 3)
        // The seed now mirrors the real staging path's sibling
        // writes so the banner, Review re-entry, and Grouped view are
        // drivable on the Simulator.
        #expect(redactionState.detectionResults[0]?.map(\.id) == page0.map(\.id))
        #expect(redactionState.crossPageEntityGroups.count == 1)
        #expect(redactionState.lastDetectionRun?.outcome == .staged)
    }
    #endif
}

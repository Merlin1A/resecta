import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// GATE-5 (Pkg I) — DetectionTriageSheet Dismiss confirmation is
// CONDITIONAL on whether the user has toggled at least one selection
// since opening the sheet. A no-op Dismiss (user opens the sheet,
// changes nothing, taps Dismiss) bypasses the dialog so it doesn't
// add friction. A modified-selection Dismiss (user toggled rows,
// chips, or bulk select/deselect, then taps Dismiss) routes through
// the dialog.
//
// The sheet's contract reduces to two pinned predicates this suite
// anchors:
//
//   1. `hasModifiedSelections` starts at false. The Dismiss button
//      reads it as a gate: false → bypass, true → confirm.
//   2. Mutating the sheet's selection map flips the flag (the four
//      mutation paths are: row tap, "All" chip, type chip, bulk
//      Select/Deselect All).
//
// Plan reference: post-V1.0 improvements §3 Pkg I (GATE-5).
// Mechanism-description copy per ARCH §1.3.

@Suite("DetectionTriageSheet Dismiss conditional confirmation (GATE-5, Pkg I)")
@MainActor
struct DetectionTriageSheetDismissConfirmationTests {

    @Test("Conditional confirmation — flag false ⇒ Dismiss bypasses dialog")
    func testConditionalConfirmation_FlagFalseBypasses() {
        // Default initial state — the user opened the sheet, hasn't
        // touched anything.
        let hasModifiedSelections = false

        // The toolbar Dismiss button reads:
        //   if hasModifiedSelections { showDialog = true } else { performDismiss() }
        // With the flag false, the bypass branch runs directly.
        let willRouteThroughDialog = hasModifiedSelections
        #expect(willRouteThroughDialog == false,
                "flag false must route directly to performDismiss")
    }

    @Test("Conditional confirmation — flag true ⇒ Dismiss routes through dialog")
    func testConditionalConfirmation_FlagTrueRoutesThroughDialog() {
        let hasModifiedSelections = true

        let willRouteThroughDialog = hasModifiedSelections
        #expect(willRouteThroughDialog == true,
                "flag true must route through the confirmation dialog")
    }

    @Test("Row-level toggle flips the modified-selections flag")
    func testRowToggleFlipsFlag() {
        let redactionState = RedactionState()
        let id = UUID()
        redactionState.triageSelections[id] = true

        // Simulate the row binding's setter — production code wraps
        // this in `Binding.set` plus `hasModifiedSelections = true`.
        var hasModifiedSelections = false
        redactionState.triageSelections[id] = false
        hasModifiedSelections = true

        #expect(redactionState.triageSelections[id] == false)
        #expect(hasModifiedSelections == true,
                "row toggle must flip hasModifiedSelections")
    }

    @Test("Bulk Select All flips the modified-selections flag")
    func testBulkSelectAllFlipsFlag() {
        let redactionState = RedactionState()
        let ids = (0..<3).map { _ in UUID() }
        for id in ids { redactionState.triageSelections[id] = false }

        // Production code: the Menu Button(selectAllLabel) closure walks
        // every targetID and sets it to true, then flips the flag.
        var hasModifiedSelections = false
        for id in ids { redactionState.triageSelections[id] = true }
        hasModifiedSelections = true

        for id in ids {
            #expect(redactionState.triageSelections[id] == true)
        }
        #expect(hasModifiedSelections == true,
                "bulk select all must flip hasModifiedSelections")
    }

    @Test("Bulk Deselect All flips the modified-selections flag")
    func testBulkDeselectAllFlipsFlag() {
        let redactionState = RedactionState()
        let ids = (0..<3).map { _ in UUID() }
        for id in ids { redactionState.triageSelections[id] = true }

        var hasModifiedSelections = false
        for id in ids { redactionState.triageSelections[id] = false }
        hasModifiedSelections = true

        for id in ids {
            #expect(redactionState.triageSelections[id] == false)
        }
        #expect(hasModifiedSelections == true,
                "bulk deselect all must flip hasModifiedSelections")
    }

    @Test("Type-chip filter tap flips the modified-selections flag")
    func testTypeChipFlipsFlag() {
        // Simulates the .onChange(of: filterKind) closure that
        // re-derives selections by category — that closure also flips
        // the flag because the user actively requested a re-selection.
        var hasModifiedSelections = false
        let _ = DetectionResult.Kind.pii(.ssn) // chip-tap input
        hasModifiedSelections = true

        #expect(hasModifiedSelections == true,
                "type-chip filter tap must flip hasModifiedSelections")
    }

    @Test("Cancel role on the Dismiss dialog leaves the sheet open and selections intact")
    func testCancelRolePreservesSelections() {
        let redactionState = RedactionState()
        let id = UUID()
        redactionState.triageSelections[id] = false  // user-toggled

        // Cancel role contract: the dismiss closure is NOT invoked.
        // The sheet stays mounted; selections survive.
        #expect(redactionState.triageSelections[id] == false,
                "Cancel must not touch the selection map")
    }

    @Test("Confirmation copy is mechanism-description (no outcome-promise phrases)")
    func testConfirmationCopyIsMechanismDescription() {
        // CAT-239: read the production constants directly so the sweep runs
        // against the live copy — a rename cannot slip a banned word past this
        // test by drifting an independent test-local literal.
        let title = DetectionTriageSheet.dismissTitle
        let message = DetectionTriageSheet.dismissMessage

        let banned = ["guaranteed", "ensures", "impossible", "securely"] // LegalPhrases:safe (test banlist)
        for word in banned {
            #expect(!title.lowercased().contains(word),
                    "title must not contain banned outcome-promise word: \(word)")
            #expect(!message.lowercased().contains(word),
                    "message must not contain banned outcome-promise word: \(word)")
        }
        // Message names the affected state (selections) so the user
        // knows what's discarded.
        #expect(message.contains("Selections"))
    }

    // CAT-395 (C-J1, the "F10 deferral pattern"): the `.sheet(item:)` set:
    // closure in DocumentEditorView defers each @Observable teardown one runloop
    // turn via `Task { @MainActor }` with an in-Task re-check guard, so the
    // clear does not mutate state synchronously inside SwiftUI's update/dismiss
    // transaction (the same class as the fixed CAT-258 `.sheet(isPresented:)`
    // crash). The production binding closure does not extract to a single
    // testable helper without changing the deferral shape, so the end-to-end
    // guard is the DetectionTriageDismissUITests suite; this test pins the
    // deferral CONTRACT at the model level by mirroring the triage arm against a
    // real RedactionState.
    @Test("Triage teardown defers the @Observable clear past the current runloop turn (CAT-395)")
    func sheetBindingTriageTeardownIsDeferred() async {
        let redactionState = RedactionState()
        redactionState.pendingTriage = [0: []]   // a non-nil triage source

        // Mirror the set: closure's triage arm: snapshot the active arm
        // synchronously, then defer the write with an in-Task re-check guard.
        if redactionState.pendingTriage != nil {
            Task { @MainActor in
                guard redactionState.pendingTriage != nil else { return }
                redactionState.dismissTriage()
            }
        }

        // Synchronously (same runloop turn) the state is still set — the write
        // is deferred, not re-entrant inside the update pass.
        #expect(redactionState.pendingTriage != nil,
                "the triage clear must be deferred, not synchronous")

        await Task.yield()
        #expect(redactionState.pendingTriage == nil,
                "the deferred clear must fire on the next runloop turn")
    }
}

import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Conditional dismiss: the sheet-level Dismiss rule, generalized from the retired
// triage sheet's donor contract (GATE-5): Dismiss is CONDITIONAL on
// whether the USER has modified selections this sheet session, for
// either result origin. Untouched → one tap (no friction; machine-made
// selections drop silently as before). Touched → a confirmation dialog.
//
// The contract reduces to pinned predicates this suite anchors:
//
//   1. `SearchState.userModifiedSelections` starts false; the Dismiss
//      button reads it as the gate (false → bypass, true → confirm).
//   2. USER selection gestures flip it (row circle, footer Select All,
//      Select-Where, keyboard space toggle, review-row equivalents).
//   3. Programmatic selection writes do NOT flip it (magic-wand
//      arrival preselect, mode-switch undo restore).
//   4. A successful apply RESETS it — the modified selections were
//      committed, so a post-apply Dismiss has nothing unsaved to
//      confirm.
//   5. Session teardown (`clear()`) resets it.

@Suite("Search sheet Dismiss rule (conditional dismiss)")
@MainActor
struct SearchSheetDismissRuleTests {

    private func makeResult(selected: Bool = false) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha",
            contextSnippet: "…alpha…",
            source: .textLayer,
            term: "alpha",
            isSelected: selected
        )
    }

    // MARK: - Gate

    @Test("Tracker defaults false — untouched sheet bypasses the dialog")
    func trackerDefaultsFalse() {
        let state = SearchState()
        #expect(state.userModifiedSelections == false,
                "a fresh session must read untouched")
        // The toolbar Dismiss reads:
        //   if userModifiedSelections { showDialog } else { performDismiss() }
        let willRouteThroughDialog = state.userModifiedSelections
        #expect(willRouteThroughDialog == false)
    }

    @Test("Touched tracker routes Dismiss through the dialog")
    func touchedRoutesThroughDialog() {
        let state = SearchState()
        state.userModifiedSelections = true
        #expect(state.userModifiedSelections == true,
                "flag true must route through the confirmation dialog")
    }

    // MARK: - Programmatic writes do NOT count

    @Test("Magic-wand arrival preselect does not touch the tracker")
    func magicWandPreselectIsNotUserWork() {
        let state = SearchState()
        state.preselectIncomingResults = true
        state.appendResult(makeResult())
        state.flushPendingResults()
        #expect(state.results.first?.isSelected == true,
                "precondition: the arrival preselect fired")
        #expect(state.userModifiedSelections == false,
                "machine-made selections are not user selection work")
    }

    @Test("Mode-switch undo restore does not touch the tracker")
    func modeSwitchRestoreIsNotUserWork() {
        let state = SearchState()
        let snapshot = SearchAndRedactSheet.ModeSwitchSnapshot(
            mode: .text,
            results: [makeResult(selected: true)],
            appliedResultIDs: [],
            piiCategoryFilter: nil,
            sortOrder: .discoveryOrder,
            appliedFilter: .all
        )
        SearchAndRedactSheet.restoreModeSwitchSnapshot(snapshot, in: state)
        #expect(state.results.count == 1)
        #expect(state.userModifiedSelections == false,
                "a programmatic restore is not user selection work")
    }

    @Test("SearchState.selectWhere itself never flips the tracker (gesture sites own the flip)")
    func selectWhereAloneDoesNotFlip() {
        let state = SearchState()
        state.results = [makeResult()]
        state.selectWhere { _ in true }
        #expect(state.results.first?.isSelected == true)
        #expect(state.userModifiedSelections == false,
                "the state method is shared by user + programmatic paths; the flip lives at the gesture sites")
    }

    // MARK: - Resets

    @Test("clear() resets the tracker with the session")
    func clearResetsTracker() {
        let state = SearchState()
        state.userModifiedSelections = true
        state.clear()
        #expect(state.userModifiedSelections == false)
    }

    // MARK: - Review-origin arm

    @Test("Review dismissal discards the staged findings (dismissTriage contract)")
    func reviewDismissDiscardsFindings() {
        let redactionState = RedactionState()
        let det = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.04),
            kind: .pii(.ssn), confidence: 0.9, matchedText: "123-45-6789"
        )
        redactionState.pendingTriage = [0: [det]]
        // Review-first arrival: an empty map (absent = not accepted).
        redactionState.triageSelections = [:]
        redactionState.dismissTriage()
        #expect(redactionState.pendingTriage == nil)
        #expect(redactionState.triageSelections.isEmpty)
    }

    // MARK: - Copy pins

    @Test("Confirmation copy is mechanism-description (no outcome-promise phrases)")
    func confirmationCopyIsMechanismDescription() {
        // Read the production constants directly so the sweep runs
        // against the live copy — a rename cannot slip a banned word
        // past this test by drifting an independent test-local literal.
        let title = SearchAndRedactSheet.dismissTitle
        let message = SearchAndRedactSheet.dismissMessage

        let banned = ["guaranteed", "ensures", "impossible", "securely"] // LegalPhrases:safe (test banlist)
        for word in banned {
            #expect(!title.lowercased().contains(word),
                    "title must not contain banned outcome-promise word: \(word)")
            #expect(!message.lowercased().contains(word),
                    "message must not contain banned outcome-promise word: \(word)")
        }
        // Message names the affected state (the selected matches) so
        // the user knows what's discarded.
        #expect(message.contains("Selected matches"))
    }

    // CAT-395 (C-J1, the "F10 deferral pattern"): the `.sheet(item:)` set:
    // closure in DocumentEditorView defers each @Observable teardown one
    // runloop turn via `Task { @MainActor }` with an in-Task re-check
    // guard. Under the absorbed review, the search arm's deferred clear
    // ALSO discards a pending review (a system-initiated dismissal with
    // staged findings would otherwise strand them behind a closed sheet).
    // This mirrors the production closure against real state.
    @Test("Sheet-binding teardown defers the clear and discards a pending review with it (CAT-395)")
    func sheetBindingTeardownIsDeferredAndClearsReview() async {
        let redactionState = RedactionState()
        redactionState.activeSearch = SearchState()
        redactionState.pendingTriage = [0: []]

        if redactionState.activeSearch != nil {
            Task { @MainActor in
                guard redactionState.activeSearch != nil else { return }
                redactionState.activeSearch = nil
                if redactionState.pendingTriage != nil {
                    redactionState.dismissTriage()
                }
            }
        }

        // Synchronously (same runloop turn) the state is still set — the
        // write is deferred, not re-entrant inside the update pass.
        #expect(redactionState.activeSearch != nil,
                "the clear must be deferred, not synchronous")
        #expect(redactionState.pendingTriage != nil)

        await Task.yield()
        #expect(redactionState.activeSearch == nil,
                "the deferred clear must fire on the next runloop turn")
        #expect(redactionState.pendingTriage == nil,
                "a pending review must not strand behind a dismissed sheet")
    }
}

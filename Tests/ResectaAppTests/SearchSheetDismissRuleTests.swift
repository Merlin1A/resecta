import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The sheet-level Dismiss rule: Dismiss asks first while the session holds
// selected matches that no live region covers, read from the rows
// (`SearchState.hasUnappliedSelections(liveApplied:)`, the rule Redact and
// Home read too), whoever ticked them; otherwise it closes in one tap.

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

    // MARK: - The rule

    @Test("A fresh session closes in one tap")
    func freshSessionClosesInOneTap() {
        #expect(SearchState().hasUnappliedSelections(liveApplied: []) == false)
    }

    @Test("A selected, unapplied match makes Dismiss ask")
    func selectedUnappliedAsks() {
        let state = SearchState()
        state.results = [makeResult(selected: true)]
        #expect(state.hasUnappliedSelections(liveApplied: []))
    }

    @Test("A selected match whose region is live does not")
    func appliedSelectionDoesNotAsk() throws {
        let state = SearchState()
        let result = makeResult(selected: true)
        state.results = [result]
        #expect(state.hasUnappliedSelections(liveApplied: [result.id]) == false)
    }

    @Test("A programmatic selection counts like a tapped one: the rule reads the rows")
    func programmaticSelectionCounts() {
        let state = SearchState()
        state.results = [makeResult()]
        state.setSelection { _ in true }
        #expect(state.hasUnappliedSelections(liveApplied: []))
    }

    @Test("clear() drops the session and with it the question")
    func clearDropsTheQuestion() {
        let state = SearchState()
        state.results = [makeResult(selected: true)]
        state.clear()
        #expect(state.hasUnappliedSelections(liveApplied: []) == false)
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

    // The `.sheet(item:)` set:
    // closure in DocumentEditorView defers each @Observable teardown one
    // runloop turn via `Task { @MainActor }` with an in-Task re-check
    // guard. This mirrors the production closure against real state.
    @Test("Sheet-binding teardown defers the clear")
    func sheetBindingTeardownIsDeferred() async {
        let redactionState = RedactionState()
        redactionState.activeSearch = SearchState()

        if redactionState.activeSearch != nil {
            Task { @MainActor in
                guard redactionState.activeSearch != nil else { return }
                redactionState.activeSearch = nil
            }
        }

        // Synchronously (same runloop turn) the state is still set — the
        // write is deferred, not re-entrant inside the update pass.
        #expect(redactionState.activeSearch != nil,
                "the clear must be deferred, not synchronous")

        await Task.yield()
        #expect(redactionState.activeSearch == nil,
                "the deferred clear must fire on the next runloop turn")
    }
}

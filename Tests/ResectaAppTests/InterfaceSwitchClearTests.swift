import Testing
import Foundation
@testable import ResectaApp

// Interface-switch clear semantics: switching interfaces clears the
// other side's unapplied results through the mode-switch undo-toast
// contract (pinned in ModeSwitchToastTests — the interface switcher
// writes modes, so the same handler serves both). What this file pins
// is the closure of the two transitions that still dropped results
// SILENTLY:
//
//   1. Saved-search recall over a live results set — the programmatic
//      transition deliberately skips the mode-switch toast, and the
//      recall's own trigger then cleared the session with no signal.
//      The recall notice names the drop (no restore affordance — the
//      user explicitly chose a new search).
//   2. The review-arrival re-target — staged detections arriving while
//      the sheet sits on Search re-target it to Scan. Routing that
//      through the user-transition path offered an undo toast whose
//      restore buried the pending review behind its parked entry
//      points; the arrival now owns the transition programmatically
//      and names the drop with a plain notice instead.
//
// Keep-results-across-switch stays DECLINED (PB-17): both closures
// name the drop; neither preserves the cleared session.

@Suite("Interface-switch clear notices (silent transitions closed)")
@MainActor
struct InterfaceSwitchClearTests {

    // MARK: - 1. Recall notice

    @Test("Recall notice names the dropped unapplied count; silent when nothing unapplied is lost")
    func recallNoticeCopy() {
        #expect(SearchAndRedactSheet.recallClearedMessage(unappliedCount: 0) == nil,
                "a recall over an empty or fully-applied session stays toast-free")
        #expect(SearchAndRedactSheet.recallClearedMessage(unappliedCount: 1)
                == "Recall cleared 1 unapplied match.")
        #expect(SearchAndRedactSheet.recallClearedMessage(unappliedCount: 3)
                == "Recall cleared 3 unapplied matches.")
    }

    // MARK: - 2. Review-arrival notice

    @Test("Review-arrival notice names the dropped unapplied count; silent when nothing unapplied is lost")
    func reviewArrivalNoticeCopy() {
        #expect(DocumentEditorView.reviewArrivalClearedMessage(unappliedCount: 0) == nil)
        #expect(DocumentEditorView.reviewArrivalClearedMessage(unappliedCount: 1)
                == "Detection review opened — 1 unapplied match cleared.")
        #expect(DocumentEditorView.reviewArrivalClearedMessage(unappliedCount: 2)
                == "Detection review opened — 2 unapplied matches cleared.")
    }

    @Test("The notices carry no banned outcome-promise vocabulary")
    func noticesPassCopyBar() {
        let samples = [
            SearchAndRedactSheet.recallClearedMessage(unappliedCount: 2),
            DocumentEditorView.reviewArrivalClearedMessage(unappliedCount: 2),
        ].compactMap { $0 }
        #expect(samples.count == 2)
        for message in samples {
            let lowered = message.lowercased()
            for term in LegalPhrases.bannedTerms {
                #expect(!lowered.contains(term),
                        "clear notices are mechanism description, not promises: '\(term)'")
            }
        }
    }
}

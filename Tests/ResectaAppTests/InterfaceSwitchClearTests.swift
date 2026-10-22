import Testing
import Foundation
@testable import ResectaApp

// Interface-crossing clear semantics: crossing interfaces clears the
// other side's unapplied results through the mode-switch undo-toast
// contract (pinned in ModeSwitchToastTests — interface identity
// derives from the mode, so the same handler serves both). What this
// file pins is the closure of the transition that still dropped
// results SILENTLY: saved-search recall over a live results set — the
// programmatic transition deliberately skips the mode-switch toast, and
// the recall's own trigger then cleared the session with no signal.
// The recall notice names the drop (no restore affordance — the user
// explicitly chose a new search).
//
// Keep-results-across-switch stays DECLINED: the closure names the
// drop; it does not preserve the cleared session.

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

    // MARK: - 2. The copy bar

    @Test("The notices carry no banned outcome-promise vocabulary")
    func noticesPassCopyBar() {
        let samples = [
            SearchAndRedactSheet.recallClearedMessage(unappliedCount: 2),
        ].compactMap { $0 }
        #expect(samples.count == 1)
        for message in samples {
            let lowered = message.lowercased()
            for term in LegalPhrases.bannedTerms {
                #expect(!lowered.contains(term),
                        "clear notices are mechanism description, not promises: '\(term)'")
            }
        }
    }
}

import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
import RedactionEngine

// The Redact rule (the button, ⇧⌘R and the run funnel read it): a live
// search session holding selections the user has not applied, no effective
// region, or the pipeline-start predicate false refuses Redact — the first
// two with a hint. `DocumentState.redactRefusal(with:)` is its one home.

@Suite("Redact gate", .tags(.search))
@MainActor
struct RedactGateTests {

    private func states(effective: Bool = true) -> (DocumentState, RedactionState) {
        let documentState = DocumentState()
        documentState.phase = .editing
        let redactionState = RedactionState()
        let size: CGFloat = effective ? 0.2 : 0.0005
        redactionState.regions[0] = [RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: size, height: size), source: .manual)]
        return (documentState, redactionState)
    }

    @Test("No live session, or an untouched one, does not refuse Redact")
    func untouchedSessionDoesNotBlock() {
        let (documentState, redactionState) = states()
        #expect(documentState.redactRefusal(with: redactionState) == nil)
        redactionState.activeSearch = SearchState(defaults: makeScratchDefaults().0)
        #expect(documentState.redactRefusal(with: redactionState) == nil)
    }

    @Test("Selections the user touched, or an auto-selected set never reviewed, refuse Redact")
    func pendingSelectionsBlock() {
        let (documentState, redactionState) = states()
        let touched = SearchState(defaults: makeScratchDefaults().0)
        touched.userModifiedSelections = true
        redactionState.activeSearch = touched
        #expect(documentState.redactRefusal(with: redactionState) == .selectedMatches)
        let preselected = SearchState(defaults: makeScratchDefaults().0)
        preselected.hasUnreviewedPreselection = true
        redactionState.activeSearch = preselected
        #expect(documentState.redactRefusal(with: redactionState) == .selectedMatches)
    }

    @Test("Every gate refuses alone")
    func everyGateRefusesAlone() {
        let (noRegions, noRegionsState) = states(effective: false)
        #expect(noRegions.redactRefusal(with: noRegionsState) == .noRegions)
        let (busy, busyState) = states()
        busy.phase = .empty
        #expect(busy.redactRefusal(with: busyState) == .busy)
    }

    @Test("The hint names the selected matches first, then the missing regions, else nothing")
    func hint() {
        let (documentState, redactionState) = states(effective: false)
        let touched = SearchState(defaults: makeScratchDefaults().0)
        touched.userModifiedSelections = true
        redactionState.activeSearch = touched
        #expect(documentState.redactRefusal(with: redactionState)?.hint
                == "Apply or clear the selected matches first")
        redactionState.activeSearch = nil
        #expect(documentState.redactRefusal(with: redactionState)?.hint
                == "Draw regions or apply Scan or Search results first")
        #expect(DocumentState.RedactRefusal.busy.hint == "")
    }
}

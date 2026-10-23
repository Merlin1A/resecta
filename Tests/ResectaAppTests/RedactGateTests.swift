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

    @Test("A selected result no region covers, or an auto-selected set never reviewed, refuses Redact; a touched session with nothing selected does not")
    func pendingSelectionsBlock() {
        let (documentState, redactionState) = states()
        let touched = SearchState(defaults: makeScratchDefaults().0)
        redactionState.activeSearch = touched
        #expect(documentState.redactRefusal(with: redactionState) == nil, "touched, nothing selected: nothing to apply")
        touched.results = [SearchResult(
            pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha", contextSnippet: "…alpha…", source: .textLayer, term: "alpha", isSelected: true)]
        #expect(documentState.redactRefusal(with: redactionState) == .selectedMatches, "a selected row no region covers")
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
        touched.results = [SearchResult(
            pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha", contextSnippet: "…alpha…", source: .textLayer, term: "alpha", isSelected: true)]
        redactionState.activeSearch = touched
        #expect(documentState.redactRefusal(with: redactionState)?.hint
                == "Apply or clear the selected matches first")
        redactionState.activeSearch = nil
        #expect(documentState.redactRefusal(with: redactionState)?.hint
                == "Draw regions or apply Scan or Search results first")
        #expect(DocumentState.RedactRefusal.busy.hint == "")
    }
}

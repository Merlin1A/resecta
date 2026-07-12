import Testing
@testable import ResectaApp

// D06-F1 — the pure decision behind the Search & Redact sheet's
// `regionVersion` onChange handler. Exercised directly so the apply-vs-undo/redo
// disambiguation is pinned without driving the SwiftUI render cycle.
//
// Contract: the apply path bumps `regionVersion` in the same MainActor tick as
// it unions the applied result IDs into the sheet, then records that bumped
// value as `lastAppliedSearchRegionVersion`. The handler must keep markers when
// the incoming bump equals that recorded value (the apply's own bump), and drop
// them on any other (larger) bump — a real undo/redo — when markers are present.
@Suite("SearchAndRedactSheet applied-marker decision (D06-F1)", .tags(.search))
@MainActor
struct SearchAndRedactSheetAppliedMarkerTests {

    @Test("Apply's own bump keeps the just-applied markers")
    func applyBumpKeepsMarkers() {
        // newVersion equals the version the apply recorded → do not clear.
        #expect(
            SearchAndRedactSheet.shouldClearAppliedMarkers(
                newVersion: 7,
                lastAppliedVersion: 7,
                isEmpty: false
            ) == false
        )
    }

    @Test("A real undo/redo bump clears stale markers")
    func undoRedoBumpClearsMarkers() {
        // newVersion moved past the apply-recorded version (N+1) and markers
        // are present → clear.
        #expect(
            SearchAndRedactSheet.shouldClearAppliedMarkers(
                newVersion: 8,
                lastAppliedVersion: 7,
                isEmpty: false
            ) == true
        )
    }

    @Test("An empty marker set is never cleared (nothing to drop)")
    func emptyMarkerSetNeverClears() {
        // A real undo/redo bump with no markers short-circuits to false.
        #expect(
            SearchAndRedactSheet.shouldClearAppliedMarkers(
                newVersion: 8,
                lastAppliedVersion: 7,
                isEmpty: true
            ) == false
        )
        // The apply bump with an empty set is likewise false.
        #expect(
            SearchAndRedactSheet.shouldClearAppliedMarkers(
                newVersion: 7,
                lastAppliedVersion: 7,
                isEmpty: true
            ) == false
        )
    }
}

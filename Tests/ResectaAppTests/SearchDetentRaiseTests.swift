import Testing
import SwiftUI
@testable import ResectaApp

// q18 / UXF-05 (ts2-04): pin the results-arrival detent-raise
// predicate. Results arriving while the sheet sits at the medium
// detent raise it to large (the fixed chrome above the list otherwise
// buries the first row at the footer); compactFloat (ST-105
// canvas-visible state) and large are never touched, and result-set
// churn without an empty → non-empty transition never re-fires the
// raise. The end-to-end behavior is driven by
// `SearchDetentLayoutUITests.testMediumDetent_firstResultRowTapSelectsRow`.

@Suite("Results-arrival detent raise (q18 / UXF-05)")
struct SearchDetentRaiseTests {
    @Test("Results arriving at medium raise the detent")
    func arrivalAtMediumRaises() {
        #expect(SearchAndRedactSheet.shouldRaiseDetentForArrivedResults(
            wasEmpty: true, isEmpty: false, currentDetent: .medium
        ) == true)
    }

    @Test("Results arriving at compactFloat do NOT raise (ST-105 canvas stays visible)")
    func arrivalAtCompactStays() {
        #expect(SearchAndRedactSheet.shouldRaiseDetentForArrivedResults(
            wasEmpty: true, isEmpty: false, currentDetent: .compactFloat
        ) == false)
    }

    @Test("Results arriving at large are a no-op")
    func arrivalAtLargeStays() {
        #expect(SearchAndRedactSheet.shouldRaiseDetentForArrivedResults(
            wasEmpty: true, isEmpty: false, currentDetent: .large
        ) == false)
    }

    @Test("Result churn without the empty → non-empty transition never re-fires")
    func churnDoesNotRefire() {
        #expect(SearchAndRedactSheet.shouldRaiseDetentForArrivedResults(
            wasEmpty: false, isEmpty: false, currentDetent: .medium
        ) == false)
    }

    @Test("Results clearing never raises")
    func clearingDoesNotRaise() {
        #expect(SearchAndRedactSheet.shouldRaiseDetentForArrivedResults(
            wasEmpty: false, isEmpty: true, currentDetent: .medium
        ) == false)
    }
}

import Testing
import Foundation
@testable import ResectaApp

// F-5 / F-10 — `SearchModal` is the Identifiable enum driving the
// consolidated `.sheet(item:)` on `SearchAndRedactSheet`. SwiftUI's
// `.sheet(item:)` keys presentation on the value's `id`: switching
// from one case to another (different `id`) triggers a single dismiss
// + present cycle; re-setting the same value (same `id`) is a no-op.
// These tests pin the identity contract so future enum changes can't
// silently regress the dismiss-and-present semantics that replaced
// the prior multi-modifier stack.

@Suite("SearchModal — presentation identity (F-5, F-10)", .tags(.search))
struct SearchModalPresentationTests {

    @Test("Distinct cases have distinct ids — switching forces dismiss + present")
    func distinctCasesHaveDistinctIDs() {
        let modals: [SearchModal] = [
            .rationale(ReverseRationaleRequest(snippet: "x", fullContext: "x", doctype: nil)),
            .rowRationale(rowID: UUID()),
            .savedSearches
        ]
        let ids = modals.map(\.id)
        #expect(Set(ids).count == ids.count,
                "Every case must produce a distinct id so .sheet(item:) sees the transition as dismiss + present")
    }

    @Test("Row-rationale identity tracks the rowID")
    func rowRationaleIdentityTracksRowID() {
        let rowA = UUID()
        let rowB = UUID()
        let modalA1: SearchModal = .rowRationale(rowID: rowA)
        let modalA2: SearchModal = .rowRationale(rowID: rowA)
        let modalB: SearchModal = .rowRationale(rowID: rowB)

        #expect(modalA1.id == modalA2.id,
                "Two rowRationale modals for the same rowID should share an id")
        #expect(modalA1.id != modalB.id,
                "rowRationale for different rowIDs must have different ids")
    }

    @Test("Rationale-request identity tracks the request's id")
    func rationaleRequestIdentityTracksRequest() {
        let requestA = ReverseRationaleRequest(snippet: "a", fullContext: "ctx", doctype: nil)
        let requestB = ReverseRationaleRequest(snippet: "b", fullContext: "ctx", doctype: nil)
        let modalA: SearchModal = .rationale(requestA)
        let modalB: SearchModal = .rationale(requestB)
        #expect(modalA.id != modalB.id,
                "Two distinct ReverseRationaleRequests should yield different modal ids")
    }

    @Test("Singleton cases have stable ids across instances")
    func singletonCasesAreStable() {
        let a: SearchModal = .savedSearches
        let b: SearchModal = .savedSearches
        #expect(a.id == b.id)
    }
}

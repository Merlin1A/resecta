import Testing
@testable import ResectaApp

// The mode-switch table: what the hub's single `.onChange(of: searchModeType)`
// handler does per transition, as a value. The cases are the handler as it
// stood before it started reading the table — a characterisation, green on
// either side of that change.

@Suite("Mode-switch plan", .tags(.search))
@MainActor
struct ModeSwitchPlanTests {

    typealias Step = SearchAndRedactSheet.ModeSwitchPlan.Step

    /// Every ordered pair of distinct modes. `nonisolated`: consumed by
    /// `@Test(arguments:)`, which the macro hoists into a nonisolated
    /// peer (the `MarkdownContentGuardTests.legalDocs` precedent).
    nonisolated static let transitions: [(SearchModeType, SearchModeType)] = SearchModeType.allCases.flatMap { from in
        SearchModeType.allCases.filter { $0 != from }.map { (from, $0) }
    }

    @Test("A user-initiated switch cancels, clears, resets the filters, toasts, resets the flag and drops the preview — every transition",
          arguments: transitions)
    func userInitiatedSwitch(from: SearchModeType, to: SearchModeType) {
        let plan = SearchAndRedactSheet.modeSwitchPlan(from: from, to: to, programmatic: false)
        #expect(plan.steps == [
            .cancelSearchWithoutAwait, .clearResults, .resetFilters, .enqueueUndoToast,
            .resetProgrammaticFlag, .clearLivePreview,
        ])
        #expect(plan.previousMode == from)
    }

    @Test("A programmatic switch to a Search-side mode preserves the session and reschedules the preview",
          arguments: [SearchModeType.text, .regex, .multiTerm])
    func programmaticSwitchToSearchMode(to: SearchModeType) {
        for from in SearchModeType.allCases where from != to {
            let plan = SearchAndRedactSheet.modeSwitchPlan(from: from, to: to, programmatic: true)
            #expect(plan.steps == [.resetProgrammaticFlag, .clearLivePreview, .scheduleLivePreview])
            #expect(plan.previousMode == from)
        }
    }

    @Test("A programmatic switch to Scan preserves the session and schedules no preview")
    func programmaticSwitchToScan() {
        for from in [SearchModeType.text, .regex, .multiTerm] {
            let plan = SearchAndRedactSheet.modeSwitchPlan(from: from, to: .piiScan, programmatic: true)
            #expect(plan.steps == [.resetProgrammaticFlag, .clearLivePreview])
        }
    }

    @Test("The clear never runs without the cancel before it and the toast after it")
    func clearTravelsWithCancelAndToast() {
        for (from, to) in Self.transitions {
            for programmatic in [false, true] {
                let steps = SearchAndRedactSheet.modeSwitchPlan(from: from, to: to, programmatic: programmatic).steps
                let clears = steps.contains(.clearResults)
                #expect(clears == steps.contains(.cancelSearchWithoutAwait))
                #expect(clears == steps.contains(.enqueueUndoToast))
                if clears {
                    #expect(steps.firstIndex(of: .cancelSearchWithoutAwait)! < steps.firstIndex(of: .clearResults)!)
                    #expect(steps.firstIndex(of: .clearResults)! < steps.firstIndex(of: .enqueueUndoToast)!)
                }
                #expect(steps.last == (programmatic && to != .piiScan ? .scheduleLivePreview : .clearLivePreview))
            }
        }
    }
}

import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The applied-search record a run's results are applied with names the
// options the run started with, not whatever the option toggles read when
// Apply is tapped: the Search Re-check re-runs the query as it ran.
@Suite("Applied record — the run's options", .tags(.search))
@MainActor
struct AppliedRecordRunOptionsTests {

    @Test("A toggle changed after the run does not change the applied record's options")
    func recordKeepsTheRunsOptions() throws {
        let state = SearchState(defaults: makeScratchDefaults().0)
        state.searchModeType = .text
        state.queryText = "Jane"
        state.options.caseSensitive = false
        _ = state.beginRun()
        state.options.caseSensitive = true

        let record = try #require(state.appliedSearchRecord())
        #expect(record.query.options.caseSensitive == false)
    }
}

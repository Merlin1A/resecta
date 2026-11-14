import Testing
import RedactionEngine
@testable import ResectaApp

// Pins what Return in the Search field starts. Return on the search
// whose results are listed or arriving starts nothing; Return on any
// other search with something to search for runs it. The end-to-end
// behavior is driven by `SearchTypingFocusUITests`
// (`testReturn_onTheListedSearch_*`, `testReturn_onAShortQuery_runsIt`).

@Suite("Return in the Search field")
@MainActor
struct SearchReturnRuleTests {
    private func shape(
        _ mode: SearchModeType = .text,
        _ query: String = "Amount",
        terms: [String] = [],
        options: SearchOptions = SearchOptions()
    ) -> SearchRunShape {
        SearchRunShape(mode: mode, query: query, terms: terms, options: options)
    }

    private func starts(
        _ current: SearchRunShape,
        last: SearchRunShape?,
        searching: Bool = false,
        completed: Bool = false,
        atCap: Bool = false
    ) -> Bool {
        SearchState.returnStartsRun(
            current: current, lastRun: last, isSearching: searching,
            hasCompletedRun: completed, stoppedAtCap: atCap)
    }

    // MARK: The listed or arriving search

    @Test("The search whose run finished starts nothing", arguments: [SearchModeType.text, .regex])
    func finishedRunOfTheSameSearch(mode: SearchModeType) {
        #expect(starts(shape(mode), last: shape(mode), completed: true) == false)
    }

    @Test("The search whose run is still going starts nothing", arguments: [SearchModeType.text, .regex])
    func runningRunOfTheSameSearch(mode: SearchModeType) {
        #expect(starts(shape(mode), last: shape(mode), searching: true) == false)
    }

    @Test("The search whose run stopped at the result cap starts nothing", arguments: [SearchModeType.text, .regex])
    func cappedRunOfTheSameSearch(mode: SearchModeType) {
        #expect(starts(shape(mode), last: shape(mode), atCap: true) == false)
        // The cap says nothing about another search.
        #expect(starts(shape(mode, "Am"), last: shape(mode), atCap: true) == true)
    }

    @Test("Multi-term with its staged terms listed starts nothing")
    func multiTermSameTerms() {
        let listed = shape(.multiTerm, "", terms: ["Hartwell", "4827"])
        #expect(starts(listed, last: listed, completed: true) == false)
        #expect(starts(listed, last: listed, searching: true) == false)
    }

    // MARK: Any other search

    @Test("No run yet: Return runs the query")
    func noRunYet() {
        #expect(starts(shape(.text, "Am"), last: nil) == true)
    }

    @Test("The same search, neither finished nor running, runs again")
    func sameSearchCancelledOrCleared() {
        #expect(starts(shape(), last: shape()) == true)
    }

    @Test("A changed query runs, a trailing space included")
    func changedQuery() {
        #expect(starts(shape(.text, "Am"), last: shape(.text, "Amo"), completed: true) == true)
        #expect(starts(shape(.text, "Amo "), last: shape(.text, "Amo"), completed: true) == true)
        #expect(starts(shape(.text, "amo"), last: shape(.text, "Amo"), completed: true) == true)
    }

    @Test("The same text as another kind of search runs")
    func changedKind() {
        #expect(starts(shape(.regex, "Amo"), last: shape(.text, "Amo"), completed: true) == true)
        #expect(starts(shape(.text, "Amo"), last: shape(.regex, "Amo"), searching: true) == true)
    }

    @Test("A changed option runs")
    func changedOption() {
        var caseSensitive = SearchOptions()
        caseSensitive.caseSensitive = true
        #expect(starts(shape(options: caseSensitive), last: shape(), completed: true) == true)
        var allTerms = SearchOptions()
        allTerms.multiTermConjunction = true
        #expect(starts(
            shape(.multiTerm, "", terms: ["a", "b"], options: allTerms),
            last: shape(.multiTerm, "", terms: ["a", "b"]), completed: true) == true)
    }

    @Test("Changed terms run, a changed order included")
    func changedTerms() {
        let last = shape(.multiTerm, "", terms: ["Hartwell", "4827"])
        #expect(starts(shape(.multiTerm, "", terms: ["Hartwell"]), last: last, completed: true) == true)
        #expect(starts(shape(.multiTerm, "", terms: ["4827", "Hartwell"]), last: last, completed: true) == true)
    }

    // MARK: Nothing to search for

    @Test("An empty or whitespace-only query never runs", arguments: ["", " ", " \n\t "])
    func nothingTyped(query: String) {
        for mode in [SearchModeType.text, .regex] {
            #expect(starts(shape(mode, query), last: nil) == false)
            #expect(starts(shape(mode, query), last: shape(mode, "Amo"), completed: true) == false)
        }
    }

    @Test("Multi-term with no staged term never runs")
    func noTerms() {
        #expect(starts(shape(.multiTerm, "", terms: []), last: nil) == false)
        #expect(starts(shape(.multiTerm, "", terms: []), last: shape(.multiTerm, "", terms: ["a"]), completed: true) == false)
    }

    @Test("Scan has no field and starts nothing from the rule")
    func scan() {
        #expect(starts(shape(.piiScan, ""), last: nil) == false)
    }

    // MARK: What the session reports

    @Test("The shape holds the query for Text and Regex and the terms for Multi-term, nothing else")
    func currentShape() {
        let state = SearchState()
        state.queryText = "Amo"
        state.searchTerms = ["left over"]
        state.searchModeType = .text
        #expect(state.currentRunShape == shape(.text, "Amo", options: state.options))
        state.searchModeType = .regex
        #expect(state.currentRunShape == shape(.regex, "Amo", options: state.options))
        // In Multi-term the field holds a term still being typed.
        state.searchModeType = .multiTerm
        state.queryText = "half a te"
        #expect(state.currentRunShape == shape(.multiTerm, "", terms: ["left over"], options: state.options))
    }

    @Test("A recorded, finished run turns Return off; a result clear turns it back on")
    func sessionFollowsTheRun() {
        let state = SearchState()
        state.searchModeType = .text
        state.queryText = "Amo"
        #expect(state.returnStartsRun == true)
        state.lastRunShape = state.currentRunShape
        state.hasCompletedRunSinceClear = true
        #expect(state.returnStartsRun == false)
        state.queryText = "Am"
        #expect(state.returnStartsRun == true)
        state.queryText = "Amo"
        #expect(state.returnStartsRun == false)
        state.clearResults()
        #expect(state.returnStartsRun == true)
        // A run that stops at the cap ends as a cancelled one: listed, not completed.
        state.resultsAtCap = true
        #expect(state.returnStartsRun == false)
        state.clearResults()
        #expect(state.returnStartsRun == true)
    }
}

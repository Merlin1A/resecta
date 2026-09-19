import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// Fixed-layout regex error callout.
//
// The toolbar's regex validation surface previously rendered via an
// `if let regexError` conditional that toggled the entire HStack into
// and out of layout, which reflowed the search field and chip row
// above it whenever the engine flipped `regexError` between nil and a
// string. This replaces that with an always-allocated, fixed-height
// container in regex mode whose contents fade via `.opacity`. The two
// pure-function contracts on `SearchToolbarSection` pin the layout
// floor and the visibility predicate so the no-reflow invariant is
// testable without a SwiftUI host.

@Suite("Regex error callout", .tags(.search))
@MainActor
struct RegexErrorCalloutTests {

    @Test("Callout reserves a fixed minimum height so toolbar doesn't reflow")
    func calloutReservesFixedHeight() {
        // The 40pt floor seats two `.caption` lines + the leading
        // icon (the reason shares its row with the "Search as Text"
        // action and wraps rather than truncating); pin the literal so
        // a future tweak surfaces as a deliberate test rename rather
        // than silent layout drift.
        #expect(SearchToolbarSection.regexErrorCalloutMinHeight == 40)
    }

    @Test("Visibility predicate matches the engine's nil/non-nil state")
    func shouldShowMatchesEngineState() {
        #expect(SearchToolbarSection.regexErrorCalloutShouldShow(error: nil) == false)
        #expect(SearchToolbarSection.regexErrorCalloutShouldShow(error: "") == false)
        #expect(SearchToolbarSection.regexErrorCalloutShouldShow(error: "Invalid regular expression") == true)
    }

    @Test("Whitespace-only error strings count as empty so a trailing newline doesn't flicker the surface")
    func whitespaceOnlyErrorIsHidden() {
        #expect(SearchToolbarSection.regexErrorCalloutShouldShow(error: "   ") == false)
        #expect(SearchToolbarSection.regexErrorCalloutShouldShow(error: "\n") == false)
        #expect(SearchToolbarSection.regexErrorCalloutShouldShow(error: " \n\t ") == false)
    }

    @Test("Real engine error strings drive the callout into the visible branch")
    func realisticEngineErrorsAreVisible() {
        // The regex engine's NSError descriptions feed `regexError`
        // verbatim; the predicate must accept the shape the engine
        // actually emits without trimming meaningful content.
        #expect(SearchToolbarSection.regexErrorCalloutShouldShow(
            error: "Invalid regular expression: unbalanced parenthesis"
        ) == true)
        #expect(SearchToolbarSection.regexErrorCalloutShouldShow(
            error: "Invalid regular expression"
        ) == true)
    }
}

// MARK: - The "Search as Text" action

@Suite("Regex error callout — search as text", .tags(.search))
@MainActor
struct RegexErrorCalloutSearchAsTextTests {

    @Test("The action reads like its sibling control: title-cased, one verb phrase")
    func actionLabel() {
        #expect(SearchToolbarSection.regexErrorSearchAsTextLabel == "Search as Text")
    }

    @Test("Switching to a text search keeps the query, flags the transition programmatic, and changes only the mode")
    func switchToTextSearchKeepsQuery() {
        let state = SearchState()
        state.searchModeType = .regex
        state.queryText = "4111(\\s?\\d{4}){3}"
        state.regexError = "Pattern contains nested quantifiers and has not been accepted."
        SearchToolbarSection.switchToTextSearch(state)
        #expect(state.searchModeType == .text)
        #expect(state.queryText == "4111(\\s?\\d{4}){3}")
        #expect(state.isProgrammaticModeChange == true)
        // The standing error is the trigger's to clear at its kickoff
        // (`clearResults()`), not the switch's.
        #expect(state.regexError != nil)
    }
}

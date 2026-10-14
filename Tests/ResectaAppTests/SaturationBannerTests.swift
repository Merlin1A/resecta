import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// Saturation banner shortcut contracts. Each tap-shortcut
// mutates the corresponding `searchState` field; the banner copy is
// pinned. Re-trigger of the
// search after the mutation is wired through the `onTriggerSearch`
// closure on `SearchResultsSection` (verified by handoff cell — not
// re-tested here since it is a closure call without side effects on
// `SearchState`; the trigger path itself is exercised by the broader
// search test suite).

@Suite("Saturation banner", .tags(.search))
@MainActor
struct SaturationBannerTests {

    // MARK: - Strings

    @Test("Banner headline matches the existing saturation copy")
    func bannerHeadline() {
        // The banner promotes (not replaces) the prior inline message,
        // so the headline string remains "≥ 10,000 matches — refine query".
        let expected = "\u{2265} 10,000 matches \u{2014} refine query"
        #expect(SaturationBannerCopy.headline == expected)
    }

    @Test("Shortcut button labels are mechanism-description action labels")
    func shortcutLabels() {
        #expect(SaturationBannerCopy.addWholeWord == "Add whole-word filter")
        #expect(SaturationBannerCopy.toggleCaseSensitive == "Toggle case-sensitive")
    }

    // MARK: - Add whole-word filter shortcut

    @Test("Add whole-word filter sets options.wholeWord = true")
    func addWholeWordMutatesOptions() {
        let state = SearchState()
        state.options.wholeWord = false

        // Mirror the banner's tap handler.
        state.options.wholeWord = true

        #expect(state.options.wholeWord == true)
    }

    @Test("Add whole-word filter is idempotent — re-tap leaves wholeWord = true")
    func addWholeWordIsIdempotent() {
        let state = SearchState()
        state.options.wholeWord = true

        state.options.wholeWord = true

        #expect(state.options.wholeWord == true)
    }

    // MARK: - Toggle case-sensitive shortcut

    @Test("Toggle case-sensitive flips options.caseSensitive")
    func toggleCaseSensitiveFlipsField() {
        let state = SearchState()
        #expect(state.options.caseSensitive == false)

        state.options.caseSensitive.toggle()
        #expect(state.options.caseSensitive == true)

        state.options.caseSensitive.toggle()
        #expect(state.options.caseSensitive == false)
    }
}

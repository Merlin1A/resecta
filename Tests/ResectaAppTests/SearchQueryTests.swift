import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The query a run searches for, built from a bare session: no sheet and
// no environment objects. The run (`SearchRun.buildSearchMode()`) and the
// sheet's `buildSearchMode()` both build it through `SearchQuery`.

@MainActor
@Suite("Search query: built from the session alone")
struct SearchQueryTests {

    private func session(_ type: SearchModeType) -> SearchState {
        let search = SearchState()
        var options = SearchOptions()
        options.caseSensitive = true
        options.wholeWord = true
        search.options = options
        search.searchModeType = type
        return search
    }

    @Test("Text and regex carry the field's text and the session's options")
    func textAndRegex() {
        let text = session(.text)
        text.queryText = "Delia"
        guard case .text(let q, let o) = SearchQuery(searchState: text).buildSearchMode() else {
            Issue.record("a text session built another mode"); return
        }
        #expect(q == "Delia")
        #expect(o == text.options)

        let regex = session(.regex)
        regex.queryText = "[0-9]{3}"
        guard case .regex(let p, let ro) = SearchQuery(searchState: regex).buildSearchMode() else {
            Issue.record("a regex session built another mode"); return
        }
        #expect(p == "[0-9]{3}")
        #expect(ro == regex.options)
    }

    @Test("Several terms carry the session's terms in order")
    func multiTerm() {
        let search = session(.multiTerm)
        search.searchTerms = ["Delia", "Okafor"]
        guard case .multiTerm(let terms, let o) = SearchQuery(searchState: search).buildSearchMode() else {
            Issue.record("a several-terms session built another mode"); return
        }
        #expect(terms == ["Delia", "Okafor"])
        #expect(o == search.options)
    }

    @Test("A scan with no kinds chosen asks for every kind; with some chosen, for those")
    func scanKinds() throws {
        let all = session(.piiScan)
        all.enabledPIICategories = []
        guard case .piiScan(let every, _) = SearchQuery(searchState: all).buildSearchMode() else {
            Issue.record("a scan session built another mode"); return
        }
        #expect(every == Set(PIICategory.allCases))

        let some = session(.piiScan)
        let one = try #require(PIICategory.allCases.first)
        some.enabledPIICategories = [one]
        guard case .piiScan(let chosen, let o) = SearchQuery(searchState: some).buildSearchMode() else {
            Issue.record("a scan session built another mode"); return
        }
        #expect(chosen == [one])
        #expect(o == some.options)
    }
}

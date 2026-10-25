import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// A search result counts as covered only when a box holds the whole of it.
// A hand-drawn box that stops a letter short of "Jonathan" (87.5 % of the
// word) leaves that letter printed; the result is applied, not called
// covered. The one rule (`resultIsCovered`) drives the apply's skip, the
// sheet's covered markers and the gates they feed, and the draw nudge. A
// search whose every result a box already holds still asks the verifier to
// re-run it.

@Suite("Search coverage rule: covered means held whole", .tags(.search))
@MainActor
struct SearchCoverageRuleTests {

    /// "Jonathan" on page 0, and a box over all but its last letter (87.5 %).
    static let word = CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.02)
    static let shortBox = CGRect(x: 0.10, y: 0.50, width: 0.175, height: 0.02)
    static let wholeBox = CGRect(x: 0.09, y: 0.49, width: 0.22, height: 0.04)

    static func result(_ rect: CGRect = word, pii: Bool = false) -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: "Jonathan",
                     contextSnippet: "…Jonathan Reyes…", source: .textLayer, term: "Jonathan",
                     isSelected: true, piiCategory: pii ? .name : nil)
    }

    static func manual(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    /// A state with one hand-drawn box on page 0 and a typed search for
    /// "Jonathan" whose one result is selected.
    static func state(box: CGRect) -> (RedactionState, SearchState, SearchResult) {
        let state = RedactionState()
        state.addRegion(manual(box), page: 0, undoManager: nil)
        let search = SearchState()
        search.queryText = "Jonathan"
        let hit = result()
        search.results = [hit]
        state.activeSearch = search
        return (state, search, hit)
    }

    @Test("A box a letter short of the word does not cover it")
    func shortBoxDoesNotCover() {
        #expect(!resultIsCovered(Self.word, by: [Self.shortBox]))
    }

    @Test("A box short of the word by one thin letter, or by a quarter point, does not cover it")
    func thinShortfallDoesNotCover() {
        // An "l" at 12 pt is about 2.7 pt wide (0.0044 of a Letter page's
        // width): 97.8 % of the word, which the old 80 % rule called covered.
        let shortByL = CGRect(x: Self.word.minX, y: Self.word.minY, width: Self.word.width - 2.7 / 612, height: Self.word.height)
        let shortByQuarterPoint = CGRect(x: Self.word.minX, y: Self.word.minY, width: Self.word.width - 0.25 / 612, height: Self.word.height)
        #expect(!resultIsCovered(Self.word, by: [shortByL]))
        #expect(!resultIsCovered(Self.word, by: [shortByQuarterPoint]))
        let prepared = prepareApply(selected: [Self.result()], existingRectsByPage: [0: [shortByL]],
                                    appliedAt: Date(), searchRecord: nil)
        #expect(prepared.appliedCount == 1)
    }

    @Test("A box that holds the whole word covers it, and so does the word's own box")
    func wholeBoxCovers() {
        #expect(resultIsCovered(Self.word, by: [Self.wholeBox]))
        #expect(resultIsCovered(Self.word, by: [Self.word]))
    }

    @Test("Apply makes a region for a result a box holds only in part")
    func partialResultIsApplied() {
        let prepared = prepareApply(selected: [Self.result()], existingRectsByPage: [0: [Self.shortBox]],
                                    appliedAt: Date(), searchRecord: nil)
        #expect(prepared.appliedCount == 1)
        #expect(prepared.coveredResultIDs.isEmpty)
    }

    @Test("The apply counts the partly covered result as marked, and the toast says so")
    func partialApplyToastCounts() async {
        let (state, _, _) = Self.state(box: Self.shortBox)
        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)
        #expect(outcome?.applied == 1)
        #expect(outcome?.skippedOverlaps == 0)
        let message = CommitFeedback.markedMessage(applied: outcome?.applied ?? 0,
                                                   alreadyCovered: outcome?.skippedOverlaps ?? 0)
        #expect(message == "Marked 1 for redaction" + CommitFeedback.notYetRedactedSuffix)
    }

    @Test("A selected result a box holds only in part is not marked covered, so the gate stays up")
    func partialSelectionKeepsTheGate() {
        let (state, search, hit) = Self.state(box: Self.shortBox)
        state.refreshSearchMarkers(on: search)
        #expect(!search.coveredResultIDs.contains(hit.id))
        #expect(search.hasUnappliedSelections(liveApplied: state.liveAppliedSearchResultIDs))
    }

    @Test("The draw nudge offers a match the new box holds only in part, as Apply would apply it")
    func nudgeAgreesWithApply() {
        let hit = Self.result(pii: true)
        let match = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: Self.manual(Self.shortBox), page: 0, results: [hit], appliedIDs: [],
            suppressed: false, proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized)
        #expect(match?.id == hit.id)
    }

    @Test("A search whose every result a box already holds still asks for its re-check")
    func allCoveredSearchIsRechecked() async {
        let coordinator = makeCoordinator()
        let state = coordinator.redactionState
        state.addRegion(Self.manual(Self.wholeBox), page: 0, undoManager: nil)
        let search = SearchState()
        search.queryText = "Jonathan"
        search.results = [Self.result()]
        state.activeSearch = search
        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)
        #expect(outcome?.applied == 0)
        #expect(outcome?.skippedOverlaps == 1)
        let requests = coordinator.collectAppliedSearches()
        #expect(requests.contains { $0.record.query.kind == .text("Jonathan") },
                "the covered search is re-run on the output: \(requests.map(\.record.query.kind))")
    }
}

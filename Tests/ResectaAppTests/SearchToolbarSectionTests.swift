import Testing
import Foundation
@testable import ResectaApp

// Toolbar density reduction. Three pure-function contracts on
// `SearchToolbarSection` carry the gate logic so the visibility
// rules are testable without a SwiftUI host:
//
//  - `optionsExpandedByDefault` pins the disclosure default
//    (renamed from `optionsCollapsedByDefault`).
//  - `ocrControlsShouldShow(includeOCR:)` is the new gate (was
//    `hasOCRResults`) — controls surface as soon as Include OCR is on.
//  - `ocrSliderShouldBeDisabled(hasOCRResults:)` flips the controls to
//    disabled state with the "Awaiting OCR results" caption.

@Suite("Search toolbar", .tags(.search))
@MainActor
struct SearchToolbarSectionTests {

    @Test("Options disclosure starts collapsed by default")
    func optionsDisclosureStartsCollapsed() {
        // The constant is named for what it stores: expanded-
        // by-default is false, i.e. the disclosure starts collapsed.
        #expect(SearchToolbarSection.optionsExpandedByDefault == false)
    }

    @Test("OCR controls surface whenever Include OCR is on, regardless of results")
    func ocrControlsVisibilityFollowsIncludeOCR() {
        // Pre-scan or no-OCR-yet: user has Include OCR on but no results
        // have arrived. The gate keeps the controls
        // visible (in disabled state).
        #expect(SearchToolbarSection.ocrControlsShouldShow(includeOCR: true) == true)
        // Include OCR off: controls hidden entirely.
        #expect(SearchToolbarSection.ocrControlsShouldShow(includeOCR: false) == false)
    }

    @Test("OCR slider disabled when Include OCR on AND no OCR results yet")
    func ocrSliderDisabledState() {
        // Include OCR is on but no OCR results yet — disabled with caption.
        #expect(SearchToolbarSection.ocrSliderShouldBeDisabled(hasOCRResults: false) == true)
        // OCR results have arrived — interactive.
        #expect(SearchToolbarSection.ocrSliderShouldBeDisabled(hasOCRResults: true) == false)
    }

    @Test("Awaiting-OCR caption is the documented safe wording token")
    func awaitingCaptionMatchesTokenAdditions() {
        // The caption itself is a static literal; the audit-lint
        // pre-commit hook enforces the banned-word list and scans
        // the source on every commit. This test pins the wording to the
        // approved-caption list so future drift surfaces here too.
        #expect(SearchToolbarSection.awaitingOCRResultsCaption == "Awaiting OCR results")
    }

    @Test("Disabled-OCR caption is conditional on an OCR leg existing")
    func ocrDisabledCaptionIsConditional() {
        // At least one page classifies `.sparse`/`.none` → an OCR pass
        // will actually run, so "awaiting" is a real state.
        #expect(SearchToolbarSection.ocrDisabledCaption(anyPageAwaitsOCR: true)
                == SearchToolbarSection.awaitingOCRResultsCaption)
        // Every page classifies `.rich` → the engine routes no page to
        // OCR and no OCR results can ever arrive; the caption must say
        // that instead of promising results indefinitely (the
        // demonstrated forever-promise failure mode).
        let noLeg = SearchToolbarSection.ocrDisabledCaption(anyPageAwaitsOCR: false)
        #expect(noLeg == "OCR not needed — this document's pages read as searchable text")
        #expect(!noLeg.lowercased().contains("awaiting"))
    }

    @Test("PII Scan mode mirrors the OCR-controls visibility via shared static gates")
    func wu87PIIScanReusesWU08Gates() {
        // `piiScanOptions` reuses the
        // same gating helpers as `standardSearchOptions` via the
        // extracted `ocrControlsRow` component. The shared gates stay
        // mode-agnostic; an OUTER piiScan-only visibility
        // gate wraps the whole block (`piiScanOCRBlockShouldShow`,
        // pinned below) — these inner gates apply once that outer gate
        // shows the block. This case anchors the shared contract so a
        // per-mode split of the INNER gates trips a test rather than
        // silently diverging.

        // Pre-scan path: visibility fires; controls render disabled
        // with the awaiting caption.
        #expect(SearchToolbarSection.ocrControlsShouldShow(includeOCR: true) == true)
        #expect(SearchToolbarSection.ocrSliderShouldBeDisabled(hasOCRResults: false) == true)

        // Post-scan path: visibility fires AND interactive.
        #expect(SearchToolbarSection.ocrSliderShouldBeDisabled(hasOCRResults: true) == false)

        // Include OCR off: hide entirely (both modes).
        #expect(SearchToolbarSection.ocrControlsShouldShow(includeOCR: false) == false)
    }

    @Test("piiScan OCR block hides only on a known all-rich map (fail-open)")
    func up7PIIScanOCRBlockVisibility() {
        // Empty/unknown map (reset or mid-import edge): fail OPEN — the
        // block must show so a scannable document never loses its
        // controls.
        #expect(SearchToolbarSection.piiScanOCRBlockShouldShow(
            anyPageAwaitsOCR: false, statusKnown: false) == true)

        // Known map, every page `.rich`: the engine routes no page to
        // OCR — the block hides.
        #expect(SearchToolbarSection.piiScanOCRBlockShouldShow(
            anyPageAwaitsOCR: false, statusKnown: true) == false)

        // Known map with any `.sparse`/`.none` page: show.
        #expect(SearchToolbarSection.piiScanOCRBlockShouldShow(
            anyPageAwaitsOCR: true, statusKnown: true) == true)
    }

    @Test("Option changes re-run only sessions with something to make stale")
    func bhB04OptionChangeRetriggerGate() {
        // Committed run (even a no-match verdict): re-run — toggling
        // case-sensitivity off may produce matches.
        #expect(SearchToolbarSection.optionChangeShouldRetrigger(
            hasCompletedRun: true, hasResults: false) == true)
        // Live results mid-session: re-run.
        #expect(SearchToolbarSection.optionChangeShouldRetrigger(
            hasCompletedRun: false, hasResults: true) == true)
        #expect(SearchToolbarSection.optionChangeShouldRetrigger(
            hasCompletedRun: true, hasResults: true) == true)
        // Fresh / carried / short-term-guarded sessions stay
        // explicit-trigger — the option row is no debounce backdoor.
        #expect(SearchToolbarSection.optionChangeShouldRetrigger(
            hasCompletedRun: false, hasResults: false) == false)
    }

    @Test("Short-term warning suppressed while a regex error stands")
    func so02ShortTermWarningGate() {
        // 1–2 character query, no standing error: the pair renders.
        #expect(SearchToolbarSection.shortTermWarningShouldShow(
            queryCount: 1, isMultiTerm: false, hasRegexError: false) == true)
        #expect(SearchToolbarSection.shortTermWarningShouldShow(
            queryCount: 2, isMultiTerm: false, hasRegexError: false) == true)
        // A standing regex error suppresses the pair — "Search Anyway"
        // beside a non-compiling pattern was a no-op loop.
        #expect(SearchToolbarSection.shortTermWarningShouldShow(
            queryCount: 2, isMultiTerm: false, hasRegexError: true) == false)
        // Empty and ≥3-character queries never warn.
        #expect(SearchToolbarSection.shortTermWarningShouldShow(
            queryCount: 0, isMultiTerm: false, hasRegexError: false) == false)
        #expect(SearchToolbarSection.shortTermWarningShouldShow(
            queryCount: 3, isMultiTerm: false, hasRegexError: false) == false)
        // Multi-term keeps its own add-term flow; never warns here.
        #expect(SearchToolbarSection.shortTermWarningShouldShow(
            queryCount: 2, isMultiTerm: true, hasRegexError: false) == false)
    }

    // MARK: - Option controls disable mid-run

    @Test("Option controls disable exactly while a run is in flight")
    func h13OptionControlsDisabledDuringSearch() {
        #expect(SearchToolbarSection.optionControlsDisabled(isSearching: true) == true)
        #expect(SearchToolbarSection.optionControlsDisabled(isSearching: false) == false)
    }

    @Test("Source pin: optionChip, the Include OCR Pages toggle, and the multi-term conjunction toggle all route through optionControlsDisabled")
    func h13SourceSitesRouteThroughContract() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/Search/SearchToolbarSection.swift")
        let occurrences = source.components(separatedBy: "optionControlsDisabled(isSearching:").count - 1
        #expect(occurrences == 3,
                "expected 3 call sites (optionChip, Include OCR Pages toggle, multi-term conjunction toggle); found \(occurrences)")
    }

    /// Mirrors `HonestySurfacesTests.loadRepoFile`.
    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}

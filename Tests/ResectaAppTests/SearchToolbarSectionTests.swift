import Testing
import Foundation
@testable import ResectaApp

// Toolbar density reduction. Three pure-function contracts on
// `SearchToolbarSection` carry the gate logic so the visibility
// rules are testable without a SwiftUI host:
//
//  - `optionsExpandedByDefault` pins the disclosure default
//    (renamed from `optionsCollapsedByDefault`).
//  - `ocrControlsShouldShow(includeOCR:anyPageAwaitsOCR:statusKnown:sourceFilter:)`
//    is the gate (was `hasOCRResults`) — controls surface as soon as
//    Include OCR is on and a page can route to OCR, or a source filter
//    is set.
//  - `ocrSliderShouldBeDisabled(hasOCRResults:)` flips the controls to
//    disabled state with the "Awaiting OCR results" caption.

@Suite("Search toolbar", .tags(.search))
@MainActor
struct SearchToolbarSectionTests {

    @Test("The Case-sensitive chip is offered in Regex mode")
    func caseSensitiveChipShowsInRegexMode() throws {
        // The two chips the toolbar hides in Regex mode sit under an
        // `if searchState.searchModeType != .regex` guard; the Case-sensitive
        // chip must not — the engine honours the option there. Read from the
        // view source, the way `PatternAdmissionTests` reads the app sources.
        let file = repoRoot().appendingPathComponent("Sources/ResectaApp/Views/Search/SearchToolbarSection.swift")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let chip = try #require(lines.firstIndex { $0.contains("optionChip(\"Case-sensitive\"") })
        let whitespace = CharacterSet.whitespaces
        let openers = lines[..<chip].filter { line in
            let t = line.trimmingCharacters(in: whitespace)
            return t.hasPrefix("if ") || t.hasPrefix("FlowLayout(")
        }
        let opener = try #require(openers.last)
        #expect(opener.trimmingCharacters(in: whitespace).hasPrefix("FlowLayout("),
                "the Case-sensitive chip sits under a mode guard: \(opener)")
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

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
        #expect(SearchToolbarSection.ocrControlsShouldShow(
            includeOCR: true, anyPageAwaitsOCR: true, statusKnown: true, sourceFilter: .all) == true)
        // Include OCR off: controls hidden entirely.
        #expect(SearchToolbarSection.ocrControlsShouldShow(
            includeOCR: false, anyPageAwaitsOCR: true, statusKnown: true, sourceFilter: .all) == false)
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

    @Test("After a completed run with no OCR results the caption stops awaiting")
    func ocrDisabledCaptionAfterCompletedRun() {
        // The run finished and its OCR leg produced nothing: "awaiting"
        // would contradict the no-match copy beside it.
        let done = SearchToolbarSection.ocrDisabledCaption(anyPageAwaitsOCR: true, runCompleted: true)
        #expect(done == "No results from text recognition")
        #expect(SearchToolbarSection.ocrDisabledCaption(anyPageAwaitsOCR: true, runCompleted: false)
                == SearchToolbarSection.awaitingOCRResultsCaption)
        // No OCR leg at all keeps its own caption, run or not.
        #expect(SearchToolbarSection.ocrDisabledCaption(anyPageAwaitsOCR: false, runCompleted: true)
                == SearchToolbarSection.ocrDisabledCaption(anyPageAwaitsOCR: false))
        // The row passes the run state.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let row = (try? String(contentsOf: root.appendingPathComponent(
            "Sources/ResectaApp/Views/Search/SearchToolbarSection+Scan.swift"), encoding: .utf8)) ?? ""
        #expect(row.contains("runCompleted: searchState.hasCompletedRunSinceClear"))
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
        #expect(SearchToolbarSection.ocrControlsShouldShow(
            includeOCR: true, anyPageAwaitsOCR: true, statusKnown: true, sourceFilter: .all) == true)
        #expect(SearchToolbarSection.ocrSliderShouldBeDisabled(hasOCRResults: false) == true)

        // Post-scan path: visibility fires AND interactive.
        #expect(SearchToolbarSection.ocrSliderShouldBeDisabled(hasOCRResults: true) == false)

        // Include OCR off: hide entirely (both modes).
        #expect(SearchToolbarSection.ocrControlsShouldShow(
            includeOCR: false, anyPageAwaitsOCR: true, statusKnown: true, sourceFilter: .all) == false)
    }

    @Test("piiScan OCR block hides only on a known all-rich map (fail-open)")
    func up7PIIScanOCRBlockVisibility() {
        // Empty/unknown map (reset or mid-import edge): fail OPEN — the
        // block must show so a scannable document never loses its
        // controls.
        #expect(SearchToolbarSection.piiScanOCRBlockShouldShow(
            anyPageAwaitsOCR: false, statusKnown: false, sourceFilter: .all) == true)

        // Known map, every page `.rich`: the engine routes no page to
        // OCR — the block hides.
        #expect(SearchToolbarSection.piiScanOCRBlockShouldShow(
            anyPageAwaitsOCR: false, statusKnown: true, sourceFilter: .all) == false)

        // Known map with any `.sparse`/`.none` page: show.
        #expect(SearchToolbarSection.piiScanOCRBlockShouldShow(
            anyPageAwaitsOCR: true, statusKnown: true, sourceFilter: .all) == true)
    }

    @Test("A set source filter keeps the Source picker reachable with no OCR results")
    func sourcePickerReachableWhileFiltered() {
        // A persisted Source = OCR on a document whose pages read as
        // text hides every row; the picker that clears it must stay
        // enabled. Only the confidence slider waits for OCR results.
        #expect(SearchToolbarSection.ocrSourcePickerShouldBeDisabled(
            hasOCRResults: false, sourceFilter: .ocrOnly) == false)
        #expect(SearchToolbarSection.ocrSourcePickerShouldBeDisabled(
            hasOCRResults: false, sourceFilter: .textOnly) == false)
        #expect(SearchToolbarSection.ocrSourcePickerShouldBeDisabled(
            hasOCRResults: false, sourceFilter: .all) == true)
        #expect(SearchToolbarSection.ocrSourcePickerShouldBeDisabled(
            hasOCRResults: true, sourceFilter: .all) == false)
        #expect(SearchToolbarSection.ocrSliderShouldBeDisabled(hasOCRResults: false) == true)
    }

    @Test("The OCR row shows only when a page routes to OCR or a source filter is set")
    func ocrRowShowsOnlyWithAnOCRPageOrAFilter() {
        // Known all-text map, no filter: three inert controls — hidden.
        #expect(SearchToolbarSection.ocrControlsShouldShow(
            includeOCR: true, anyPageAwaitsOCR: false, statusKnown: true, sourceFilter: .all) == false)
        // Unknown map: fail open.
        #expect(SearchToolbarSection.ocrControlsShouldShow(
            includeOCR: true, anyPageAwaitsOCR: false, statusKnown: false, sourceFilter: .all) == true)
        // A set filter is always reachable, whatever the map or toggle.
        #expect(SearchToolbarSection.ocrControlsShouldShow(
            includeOCR: true, anyPageAwaitsOCR: false, statusKnown: true, sourceFilter: .ocrOnly) == true)
        #expect(SearchToolbarSection.ocrControlsShouldShow(
            includeOCR: false, anyPageAwaitsOCR: false, statusKnown: true, sourceFilter: .ocrOnly) == true)
        // The Scan side's block follows the same exit.
        #expect(SearchToolbarSection.piiScanOCRBlockShouldShow(
            anyPageAwaitsOCR: false, statusKnown: true, sourceFilter: .ocrOnly) == true)
    }

    @Test("Show All clears every filter that can hide a row")
    func showAllClearsTheHidingFilters() {
        withScratchDefaults { defaults in
            let state = SearchState(defaults: defaults)
            state.sourceFilter = .ocrOnly
            state.minimumOCRConfidence = 0.8
            state.piiCategoryFilter = [.email]
            state.appliedFilter = .unapplied
            SearchResultsSection.showAll(on: state)
            #expect(state.sourceFilter == .all)
            #expect(state.minimumOCRConfidence == 0)
            #expect(state.piiCategoryFilter == nil)
            #expect(state.appliedFilter == .all)
        }
        #expect(SearchEmptyStateCopy.showAllButton == "Show All")
    }

    @Test("The short-term warning counts trimmed characters — a query of spaces offers no Search Anyway")
    func shortTermWarningCountsTrimmedCharacters() {
        let blank = SearchToolbarSection.shortTermWarningQueryCount("   ")
        #expect(blank == 0)
        #expect(SearchToolbarSection.shortTermWarningShouldShow(
            queryCount: blank, isMultiTerm: false, hasRegexError: false) == false)
        #expect(SearchToolbarSection.shortTermWarningQueryCount(" a ") == 1)
        #expect(SearchToolbarSection.shortTermWarningQueryCount("ab") == 2)
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

    // MARK: - Refused patterns a built-in detector covers

    @Test("Built-in detector shape rules: email, SSN, phone, card; nothing for other shapes")
    func builtInDetectorCoveringShapes() {
        // The email shape: an unescaped @ anywhere in the pattern.
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"\S+@\S+\.\S+"#) == .email)
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"[\w.]+@example\.com"#) == .email)
        // An escaped @ is a literal the user means, not the email shape.
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"user\@host"#) == nil)
        // The number shapes, in each of the spellings the rules read.
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"\d{3}-\d{2}-\d{4}"#) == .ssn)
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"[0-9]{3}[- ]?[0-9]{2}[- ]?[0-9]{4}"#) == .ssn)
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"\(?\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}"#) == .phone)
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}"#) == .creditCard)
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"\d{16}"#) == .creditCard)
        // Shapes no detector covers stay silent.
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"(a|aa)*b"#) == nil)
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: #"\d{4}-\d{2}-\d{2}"#) == nil)
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: "invoice \\d+") == nil)
        #expect(SearchToolbarSection.builtInDetectorCovering(pattern: "") == nil)
        // The sentence names the detector the way the app does.
        #expect(SearchToolbarSection.builtInDetectorSentence(for: .email)
                == "Use the built-in Email detector.")
        #expect(SearchToolbarSection.builtInDetectorSentence(for: .creditCard)
                == "Use the built-in Credit Card detector.")
    }

    // MARK: - Option controls disable mid-run

    @Test("Option controls disable exactly while a run is in flight")
    func h13OptionControlsDisabledDuringSearch() {
        #expect(SearchToolbarSection.optionControlsDisabled(isSearching: true) == true)
        #expect(SearchToolbarSection.optionControlsDisabled(isSearching: false) == false)
    }

    @Test("Source pin: optionChip, the Include OCR Pages toggle, and the multi-term conjunction toggle all route through optionControlsDisabled")
    func h13SourceSitesRouteThroughContract() throws {
        // The three sites span the toolbar's base file and its Scan
        // extension (the Include OCR Pages toggle sits in the Scan options).
        let source = try loadRepoFile("Sources/ResectaApp/Views/Search/SearchToolbarSection.swift")
            + loadRepoFile("Sources/ResectaApp/Views/Search/SearchToolbarSection+Scan.swift")
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

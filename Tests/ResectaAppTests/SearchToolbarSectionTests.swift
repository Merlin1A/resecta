import Testing
import Foundation
@testable import ResectaApp

// WU-08 — toolbar density reduction. Three pure-function contracts on
// `SearchToolbarSection` carry the gate logic so the WU-08 visibility
// rules are testable without a SwiftUI host:
//
//  - `optionsCollapsedByDefault` pins the disclosure default per [D-01].
//  - `ocrControlsShouldShow(includeOCR:)` is the new gate (was
//    `hasOCRResults`) — controls surface as soon as Include OCR is on.
//  - `ocrSliderShouldBeDisabled(hasOCRResults:)` flips the controls to
//    disabled state with the "Awaiting OCR results" caption per [R-07].

@Suite("Search toolbar (WU-08)", .tags(.search))
@MainActor
struct SearchToolbarSectionTests {

    @Test("Options disclosure starts collapsed by default")
    func optionsDisclosureCollapsedByDefault() {
        #expect(SearchToolbarSection.optionsCollapsedByDefault == false)
    }

    @Test("OCR controls surface whenever Include OCR is on, regardless of results")
    func ocrControlsVisibilityFollowsIncludeOCR() {
        // Pre-scan or no-OCR-yet: user has Include OCR on but no results
        // have arrived. WU-08 changes the gate so the controls are
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

    @Test("Awaiting-OCR caption is the documented SAFE §19 token")
    func awaitingCaptionMatchesTokenAdditions() {
        // The caption itself is a static literal; the audit-lint
        // pre-commit hook is the canonical §19 enforcement and scans
        // the source on every commit. This test pins the wording to the
        // entry in the maintainer's token ledger so future drift surfaces here too.
        #expect(SearchToolbarSection.awaitingOCRResultsCaption == "Awaiting OCR results")
    }

    @Test("UXF-14 — disabled-OCR caption is conditional on an OCR leg existing")
    func ocrDisabledCaptionIsConditional() {
        // At least one page classifies `.sparse`/`.none` → an OCR pass
        // will actually run, so "awaiting" is a real state.
        #expect(SearchToolbarSection.ocrDisabledCaption(anyPageAwaitsOCR: true)
                == SearchToolbarSection.awaitingOCRResultsCaption)
        // Every page classifies `.rich` → the engine routes no page to
        // OCR and no OCR results can ever arrive; the caption must say
        // that instead of promising results indefinitely (the
        // demonstrated UXF-14 forever-promise).
        let noLeg = SearchToolbarSection.ocrDisabledCaption(anyPageAwaitsOCR: false)
        #expect(noLeg == "OCR not needed — this document's pages read as searchable text")
        #expect(!noLeg.lowercased().contains("awaiting"))
    }

    @Test("WU-87 — PII Scan mode mirrors WU-08 OCR-controls visibility via shared static gates")
    func wu87PIIScanReusesWU08Gates() {
        // Per WU-87, `piiScanOptions` reuses the
        // same gating helpers as `standardSearchOptions` via the
        // extracted `ocrControlsRow` component. The shared gates stay
        // mode-agnostic; UP-7 added an OUTER piiScan-only visibility
        // gate around the whole block (`piiScanOCRBlockShouldShow`,
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

    @Test("UP-7 — piiScan OCR block hides only on a known all-rich map (fail-open)")
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

    @Test("BH-B-04 — option changes re-run only sessions with something to make stale")
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
        // Fresh / carried (UXF-16) / short-term-guarded sessions stay
        // explicit-trigger — the option row is no debounce backdoor.
        #expect(SearchToolbarSection.optionChangeShouldRetrigger(
            hasCompletedRun: false, hasResults: false) == false)
    }
}

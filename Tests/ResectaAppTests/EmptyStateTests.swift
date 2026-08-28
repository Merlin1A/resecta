import Testing
import Foundation
@testable import ResectaApp

// Mode-specific empty-state copy + multi-term recall chips per
// mechanism-description discipline. Tests pin (a) the pure-function
// context discriminator that drives the per-branch copy, (b) the
// headline / description copy per branch including the audit-lint
// acceptance (no outcome promises), and (c) the recall-chip
// rendering helpers.

@Suite("Empty state copy", .tags(.search))
@MainActor
struct EmptyStateTests {

    // MARK: - Context discriminator

    @Test("Text mode pre-search context when query is empty")
    func textPreSearchContext() {
        let ctx = WU20Strings.context(
            mode: .text,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0,
            totalPages: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: false,
            scanStartFailed: false
        )
        #expect(ctx == .textPreSearch)
    }

    @Test("Text mode no-match context when query is non-empty and a run completed")
    func textNoMatchContext() {
        let ctx = WU20Strings.context(
            mode: .text,
            queryText: "alpha",
            multiTermTerms: [],
            recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0,
            totalPages: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: true,
            scanStartFailed: false
        )
        #expect(ctx == .textNoMatch)
    }

    @Test("Carried query without a completed run reads as not-run, never as a no-match verdict")
    func notRunContexts() {
        // The mode switch carries the query text but deliberately does
        // not re-run; until a run completes, the empty state
        // must not claim the query produced no matches.
        let text = WU20Strings.context(
            mode: .text, queryText: "alpha",
            multiTermTerms: [], recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0, totalPages: 0, totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: false, scanStartFailed: false
        )
        #expect(text == .textNotRun)

        let regex = WU20Strings.context(
            mode: .regex, queryText: "Page \\d+",
            multiTermTerms: [], recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0, totalPages: 0, totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: false, scanStartFailed: false
        )
        #expect(regex == .regexNotRun)

        let terms = WU20Strings.context(
            mode: .multiTerm, queryText: "",
            multiTermTerms: ["alpha"], recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0, totalPages: 0, totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: false, scanStartFailed: false
        )
        #expect(terms == .multiTermNotRun)
    }

    @Test("Not-run copy names a run affordance")
    func notRunCopyNamesRunAffordance() {
        #expect(WU20Strings.description(for: .textNotRun).contains("Return"))
        #expect(WU20Strings.description(for: .regexNotRun).contains("Return"))
        #expect(WU20Strings.description(for: .multiTermNotRun).contains("Return"))
        // The failed-start state's run affordance is its inline
        // "Scan Again" action, not the copy — the description must
        // not name the retired run button.
        #expect(!WU20Strings.description(for: .piiScanStartFailed).contains("Scan Document"))
    }

    @Test("Conjunction zero-hit names the all-terms gate, not per-term absence")
    func conjunctionNoMatchContext() {
        let ctx = WU20Strings.context(
            mode: .multiTerm, queryText: "",
            multiTermTerms: ["alpha", "zzz"], recentMultiTermSets: [],
            multiTermConjunction: true,
            currentSearchPage: 0, totalPages: 0, totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: true, scanStartFailed: false
        )
        #expect(ctx == .multiTermNoMatchConjunction)
        let copy = WU20Strings.description(for: .multiTermNoMatchConjunction)
        // Under conjunction, individual terms may still occur — the
        // copy must not claim absence "for any of the active terms".
        #expect(!copy.contains("for any of the active terms"))
        #expect(copy.contains("all of the active terms"))
    }

    @Test("Failed scan start outranks the pre-scan default")
    func scanStartFailedContext() {
        let ctx = WU20Strings.context(
            mode: .piiScan, queryText: "",
            multiTermTerms: [], recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0, totalPages: 0, totalCount: 0,
            enabledPIICategoryCount: 12,
            hasCompletedRun: false, scanStartFailed: true
        )
        #expect(ctx == .piiScanStartFailed)
    }

    @Test("Multi-term pre-search context flips on recents presence")
    func multiTermPreSearchFlipsOnRecents() {
        let noRecents = WU20Strings.context(
            mode: .multiTerm,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0,
            totalPages: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: false,
            scanStartFailed: false
        )
        #expect(noRecents == .multiTermPreSearchNoRecents)

        let withRecents = WU20Strings.context(
            mode: .multiTerm,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [["alpha", "beta"]],
            multiTermConjunction: false,
            currentSearchPage: 0,
            totalPages: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: false,
            scanStartFailed: false
        )
        #expect(withRecents == .multiTermPreSearchWithRecents)
    }

    @Test("Multi-term no-match context when terms present and a run completed")
    func multiTermNoMatchContext() {
        let ctx = WU20Strings.context(
            mode: .multiTerm,
            queryText: "",
            multiTermTerms: ["alpha", "beta"],
            recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0,
            totalPages: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0,
            hasCompletedRun: true,
            scanStartFailed: false
        )
        #expect(ctx == .multiTermNoMatch)
    }

    @Test("PII Scan pre-scan context when currentSearchPage = 0")
    func piiScanPreScanContext() {
        let ctx = WU20Strings.context(
            mode: .piiScan,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 0,
            totalPages: 0,
            totalCount: 0,
            enabledPIICategoryCount: 12,
            hasCompletedRun: false,
            scanStartFailed: false
        )
        #expect(ctx == .piiScanPreScan)
    }

    @Test("PII Scan post-scan zero-result context carries detector count")
    func piiScanPostScanZeroContext() {
        let ctx = WU20Strings.context(
            mode: .piiScan,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 8,
            totalPages: 0,
            totalCount: 0,
            enabledPIICategoryCount: 7,
            hasCompletedRun: true,
            scanStartFailed: false
        )
        #expect(ctx == .piiScanPostScanZero(detectorCount: 7))
    }

    @Test("Cancelled scan never renders the post-scan clean bill")
    func piiScanCancelledContext() {
        // A cancelled run leaves currentSearchPage at the cancelled
        // position with hasCompletedRun still false — exactly the state
        // that used to render "Scan complete · N detectors matched 0
        // candidates" on a partially-scanned document.
        let ctx = WU20Strings.context(
            mode: .piiScan,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [],
            multiTermConjunction: false,
            currentSearchPage: 8,
            totalPages: 120,
            totalCount: 0,
            enabledPIICategoryCount: 17,
            hasCompletedRun: false,
            scanStartFailed: false
        )
        #expect(ctx == .piiScanCancelled(pagesScanned: 8, pageCount: 120))
    }

    @Test("Cancelled-scan copy names the partial coverage, no completion claim")
    func piiScanCancelledCopy() {
        let context = WU20Strings.EmptyContext
            .piiScanCancelled(pagesScanned: 8, pageCount: 120)
        #expect(WU20Strings.headline(for: context) == "Scan cancelled")
        // The completed-run checkmark is reserved for full runs.
        #expect(WU20Strings.headlineSymbol(for: context) == "stop.circle")
        let copy = WU20Strings.description(for: context)
        #expect(copy == "Detection stopped after 8 of 120 pages — the remaining pages weren't scanned.")
        #expect(!copy.contains("complete"))
        #expect(!copy.contains("detector"))
    }

    // MARK: - Description copy

    @Test("Text pre-search description uses mechanism-description verbs")
    func textPreSearchCopyMechanism() {
        let copy = WU20Strings.description(for: .textPreSearch)
        // Must use "match" not the audit-lint-forbidden lookup
        // verb (assembled via concat to keep this test source clean).
        let forbidden = "fin" + "d"
        #expect(!copy.lowercased().contains(forbidden))
        #expect(copy.contains("match"))
    }

    @Test("PII Scan pre-scan description names no retired control")
    func piiScanPreScanCopyNamesNoRetiredControl() {
        // The persistent run button retired with the auto-run-first
        // Scan interface. The vestigial pre-scan description keeps the
        // role sentence as residue (wording constraints pinned by
        // `PIIScanRoleCopyTests`) and must not point at the retired
        // button.
        let copy = WU20Strings.description(for: .piiScanPreScan)
        #expect(!copy.contains("Scan Document"))
    }

    @Test("Browse Templates copy is removed from piiScanPreScan description")
    func testBrowseTemplatesCopyRemoved() {
        let copy = WU20Strings.description(for: .piiScanPreScan)
        // Retires the dead "Browse Templates" affordance
        // from the empty-state copy. This test verifies the old string is
        // absent from the WU20Strings surface.
        #expect(!copy.contains("Browse Templates"))
    }

    @Test("Search role line mounts on pre-search contexts only")
    func searchRoleSubtitleContexts() {
        // The Search interface's one-line role sentence renders above
        // the per-mode caption on the pre-search empty states. It does
        // not render on no-match branches (result feedback owns those)
        // or on the Scan side (whose role copy lives in the
        // piiScanPreScan description).
        let mounted: [WU20Strings.EmptyContext] = [
            .textPreSearch, .regexPreSearch,
            .multiTermPreSearchNoRecents, .multiTermPreSearchWithRecents,
        ]
        let bare: [WU20Strings.EmptyContext] = [
            .textNoMatch, .regexNoMatch, .multiTermNoMatch,
            .multiTermNoMatchConjunction,
            .textNotRun, .regexNotRun, .multiTermNotRun,
            .piiScanPreScan, .piiScanStartFailed,
            .piiScanPostScanZero(detectorCount: 5),
            .piiScanCancelled(pagesScanned: 3, pageCount: 12),
        ]
        for context in mounted {
            #expect(WU20Strings.showsSearchRoleSubtitle(for: context),
                    "role line missing on \(context)")
        }
        for context in bare {
            #expect(!WU20Strings.showsSearchRoleSubtitle(for: context),
                    "role line unexpectedly mounted on \(context)")
        }
    }

    @Test("Search role line states the literal-match contract, mechanism-description only")
    func searchRoleSubtitleWording() {
        let copy = WU20Strings.searchRoleSubtitle
        // The literal-match contract: results follow the query, and
        // nothing is inferred beyond it.
        #expect(copy.contains("Matches exactly what you ask for"))
        #expect(copy.contains("nothing inferred"))
        // Mechanism-description discipline — forbidden vocabulary
        // assembled via concat so this source does not itself trip
        // the pre-commit sweep.
        let lowered = copy.lowercased()
        let forbidden: [String] = [
            "guarant" + "ee",
            "ensur" + "e",
            "fin" + "d",
            "cat" + "ch",
            "100" + "%",
        ]
        for phrase in forbidden {
            #expect(!lowered.contains(phrase), "forbidden phrase: \(phrase)")
        }
    }

    @Test("PII Scan post-scan zero-result is mechanism-description (no outcome promise)")
    func piiScanPostScanZeroIsMechanism() {
        let copy = WU20Strings.description(for: .piiScanPostScanZero(detectorCount: 7))
        #expect(copy == "7 detectors matched 0 candidates above threshold.\n\n"
            + WU20Strings.piiScanZeroCalibrationLine + "\n\n"
            + WU20Strings.piiScanZeroRecourseLine)
        // Forbidden outcome promises — assembled via concat so
        // the source itself does not trip the audit-lint hook.
        let outcomePhrases: [String] = [
            "no PII " + "detected",
            "all " + "clear",
            "your document " + "is clean",
            "nothing to " + "redact",
            "no PII " + "matched",
        ]
        for phrase in outcomePhrases {
            #expect(!copy.lowercased().contains(phrase.lowercased()))
        }
    }

    @Test("PII Scan post-scan zero-result uses singular suffix for 1 detector")
    func piiScanPostScanZeroSingular() {
        let copy = WU20Strings.description(for: .piiScanPostScanZero(detectorCount: 1))
        #expect(copy == "1 detector matched 0 candidates above threshold.\n\n"
            + WU20Strings.piiScanZeroCalibrationLine + "\n\n"
            + WU20Strings.piiScanZeroRecourseLine)
    }

    // MARK: - Post-scan-zero headline, glyph, recourse

    @Test("Post-scan-zero headline names the produced count, not a clean-bill affirmation")
    func piiScanPostScanZeroHeadline() {
        let headline = WU20Strings.headline(for: .piiScanPostScanZero(detectorCount: 5))
        #expect(headline == "No items flagged")
        #expect(!headline.lowercased().contains("complete"))
    }

    @Test("Post-scan-zero glyph matches the Search-side no-match sibling glyph")
    func piiScanPostScanZeroGlyph() {
        let zeroGlyph = WU20Strings.headlineSymbol(for: .piiScanPostScanZero(detectorCount: 5))
        #expect(zeroGlyph == "doc.text.magnifyingglass")
        #expect(zeroGlyph == WU20Strings.headlineSymbol(for: .textNoMatch))
        #expect(zeroGlyph == WU20Strings.headlineSymbol(for: .regexNoMatch))
        #expect(zeroGlyph == WU20Strings.headlineSymbol(for: .multiTermNoMatch))
        #expect(zeroGlyph != "checkmark.circle")
    }

    @Test("Calibration line states a threshold outcome, not a content verdict")
    func piiScanZeroCalibrationLineWording() {
        let copy = WU20Strings.piiScanZeroCalibrationLine
        #expect(copy == "A zero result means nothing on the scanned pages cleared the current threshold for those detectors \u{2014} it is not a statement about what the document contains.")
    }

    @Test("Recourse line names the three existing controls by their shipped labels")
    func piiScanZeroRecourseLineWording() {
        let copy = WU20Strings.piiScanZeroRecourseLine
        #expect(copy == "To look further: re-run with different detectors (\u{21bb}), search for specific terms in Search, or change the Detection Sensitivity preset in Settings.")
        #expect(copy.contains("Search"))
        #expect(copy.contains("Settings"))
        #expect(copy.contains("\u{21bb}"))
    }

    @Test("Zero-state calibration + recourse lines are mechanism-description only")
    func piiScanZeroLinesAreMechanism() {
        // Forbidden vocabulary — assembled via concat so this
        // source itself does not trip the pre-commit M-1 sweep.
        let forbidden: [String] = [
            "guarant" + "ee",
            "ensur" + "e",
            "impossi" + "ble",
            "perfect" + "ly",
            "flawless" + "ly",
            "fin" + "d",
            "cat" + "ch",
            "100" + "%",
            "secur" + "e",
            "safe",
            "clean",
            "protect" + "ed",
            "zero networking",
        ]
        for line in [WU20Strings.piiScanZeroCalibrationLine, WU20Strings.piiScanZeroRecourseLine] {
            let lowered = line.lowercased()
            for phrase in forbidden {
                #expect(!lowered.contains(phrase), "forbidden phrase '\(phrase)' in: \(line)")
            }
        }
    }

    @Test("No percent sign in any post-scan-zero-state line")
    func piiScanZeroLinesNoPercentSign() {
        #expect(!WU20Strings.piiScanZeroCalibrationLine.contains("%"))
        #expect(!WU20Strings.piiScanZeroRecourseLine.contains("%"))
        let composed = WU20Strings.description(for: .piiScanPostScanZero(detectorCount: 3))
        #expect(!composed.contains("%"))
    }

    @Test("Filtered-out copy points at filter chips, mechanism-description")
    func filteredOutCopyMechanism() {
        let copy = WU20Strings.filteredOutDescription
        #expect(copy.contains("filters"))
        let forbidden = "fin" + "d"
        #expect(!copy.lowercased().contains(forbidden))
    }

    @Test("All branches contain no audit-lint-forbidden phrases")
    func allBranchesNoForbiddenPhrases() {
        let allContexts: [WU20Strings.EmptyContext] = [
            .textPreSearch, .textNotRun, .textNoMatch,
            .regexPreSearch, .regexNotRun, .regexNoMatch,
            .multiTermPreSearchNoRecents, .multiTermPreSearchWithRecents,
            .multiTermNotRun, .multiTermNoMatch, .multiTermNoMatchConjunction,
            .piiScanPreScan, .piiScanStartFailed,
            .piiScanPostScanZero(detectorCount: 5),
            .piiScanCancelled(pagesScanned: 3, pageCount: 12),
        ]
        // Forbidden phrase set per the M-1 check (CONTRIBUTING, audit checklist) — assembled
        // via string concat so the test source itself does not trip
        // the pre-commit hook.
        let forbidden: [String] = [
            "guarant" + "ee",
            "ensur" + "e",
            "impossi" + "ble",
            "perfect" + "ly",
            "flawless" + "ly",
            // word-boundary lookup verbs from the M-1 regex —
            // split mid-word so the test source itself does not
            // contain the bare trigger token.
            "fin" + "ds",
            "fin" + "ding",
            "cat" + "ches",
            "cat" + "ching",
        ]
        for context in allContexts {
            let copy = WU20Strings.description(for: context).lowercased()
            for phrase in forbidden {
                #expect(
                    !copy.contains(phrase),
                    "Empty-state copy for \(context) contains forbidden phrase '\(phrase)': \(copy)"
                )
            }
        }
    }

    // MARK: - Recall chips

    @Test("Recall chip label joins terms with non-breaking-space-plus")
    func recallChipLabelFormat() {
        let label = WU20Strings.recallChipLabel(terms: ["alpha", "beta", "gamma"])
        #expect(label == "alpha\u{00A0}+\u{00A0}beta\u{00A0}+\u{00A0}gamma")
    }

    @Test("Recall chip accessibility label uses 'and' between terms for VoiceOver")
    func recallChipAccessibilityLabelFormat() {
        let label = WU20Strings.recallChipAccessibilityLabel(terms: ["alpha", "beta"])
        #expect(label == "Recall recent search: alpha and beta")
    }

    @Test("Recent searches header copy is exactly 'Recent searches'")
    func recentSearchesHeader() {
        #expect(WU20Strings.recentSearchesHeader == "Recent searches")
    }
}

// MARK: - SearchState recall ring

@Suite("SearchState recentMultiTermSets ring", .tags(.search))
@MainActor
struct SearchStateRecentMultiTermSetsTests {

    @Test("recordMultiTermSearch is a no-op for empty terms")
    func recordEmptyIsNoOp() {
        let state = SearchState()
        state.recordMultiTermSearch(terms: [])
        #expect(state.recentMultiTermSets.isEmpty)
    }

    @Test("recordMultiTermSearch inserts new sets at the front")
    func recordInsertsAtFront() {
        let state = SearchState()
        state.recordMultiTermSearch(terms: ["alpha"])
        state.recordMultiTermSearch(terms: ["beta", "gamma"])
        #expect(state.recentMultiTermSets == [["beta", "gamma"], ["alpha"]])
    }

    @Test("recordMultiTermSearch dedupes existing sets and moves to front")
    func recordDedupesAndMovesToFront() {
        let state = SearchState()
        state.recordMultiTermSearch(terms: ["alpha"])
        state.recordMultiTermSearch(terms: ["beta"])
        state.recordMultiTermSearch(terms: ["alpha"])  // re-record alpha
        #expect(state.recentMultiTermSets == [["alpha"], ["beta"]])
    }

    @Test("recordMultiTermSearch caps the ring at recentMultiTermSetsCap")
    func recordCapsAtCap() {
        let state = SearchState()
        for i in 0..<(SearchState.recentMultiTermSetsCap + 3) {
            state.recordMultiTermSearch(terms: ["term-\(i)"])
        }
        #expect(state.recentMultiTermSets.count == SearchState.recentMultiTermSetsCap)
        // Most-recent-first: the last-recorded should be at index 0.
        #expect(state.recentMultiTermSets.first == ["term-\(SearchState.recentMultiTermSetsCap + 2)"])
    }

    @Test("clear() resets recentMultiTermSets to empty")
    func clearResetsRing() {
        let state = SearchState()
        state.recordMultiTermSearch(terms: ["alpha", "beta"])
        state.clear()
        #expect(state.recentMultiTermSets.isEmpty)
    }

    @Test("clearResults() preserves recentMultiTermSets across per-search resets")
    func clearResultsPreservesRing() {
        let state = SearchState()
        state.recordMultiTermSearch(terms: ["alpha", "beta"])
        state.clearResults()
        #expect(state.recentMultiTermSets == [["alpha", "beta"]])
    }

    @Test("clearResults() resets the frozen detector-count snapshot")
    func clearResultsResetsLastRunDetectorCount() {
        let state = SearchState()
        state.lastRunDetectorCount = 17
        state.clearResults()
        #expect(state.lastRunDetectorCount == nil,
                "the next run's copy must not inherit a prior run's snapshot")
    }
}

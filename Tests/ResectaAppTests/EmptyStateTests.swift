import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-20 — Mode-specific empty-state copy + multi-term recall chips
// per [R-34] mechanism-description discipline. Tests pin (a) the
// pure-function context discriminator that drives the per-branch
// copy, (b) the headline / description copy per branch including
// the §19 audit acceptance (no outcome promises), and (c) the
// recall-chip rendering helpers.

@Suite("Empty state copy (WU-20)", .tags(.search))
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
            currentSearchPage: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0
        )
        #expect(ctx == .textPreSearch)
    }

    @Test("Text mode no-match context when query is non-empty and totalCount = 0")
    func textNoMatchContext() {
        let ctx = WU20Strings.context(
            mode: .text,
            queryText: "alpha",
            multiTermTerms: [],
            recentMultiTermSets: [],
            currentSearchPage: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0
        )
        #expect(ctx == .textNoMatch)
    }

    @Test("Multi-term pre-search context flips on recents presence")
    func multiTermPreSearchFlipsOnRecents() {
        let noRecents = WU20Strings.context(
            mode: .multiTerm,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [],
            currentSearchPage: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0
        )
        #expect(noRecents == .multiTermPreSearchNoRecents)

        let withRecents = WU20Strings.context(
            mode: .multiTerm,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [["alpha", "beta"]],
            currentSearchPage: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0
        )
        #expect(withRecents == .multiTermPreSearchWithRecents)
    }

    @Test("Multi-term no-match context when terms present and totalCount = 0")
    func multiTermNoMatchContext() {
        let ctx = WU20Strings.context(
            mode: .multiTerm,
            queryText: "",
            multiTermTerms: ["alpha", "beta"],
            recentMultiTermSets: [],
            currentSearchPage: 0,
            totalCount: 0,
            enabledPIICategoryCount: 0
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
            currentSearchPage: 0,
            totalCount: 0,
            enabledPIICategoryCount: 12
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
            currentSearchPage: 8,
            totalCount: 0,
            enabledPIICategoryCount: 7
        )
        #expect(ctx == .piiScanPostScanZero(detectorCount: 7))
    }

    // MARK: - Description copy

    @Test("Text pre-search description uses mechanism-description verbs")
    func textPreSearchCopyMechanism() {
        let copy = WU20Strings.description(for: .textPreSearch)
        // §19: must use "match" not the audit-lint-forbidden lookup
        // verb (assembled via concat to keep this test source clean).
        let forbidden = "fin" + "d"
        #expect(!copy.lowercased().contains(forbidden))
        #expect(copy.contains("match"))
    }

    @Test("PII Scan pre-scan description points at Scan Document button, mechanism-description only")
    func piiScanPreScanCopyPointsAtScanDocument() {
        // UP-6 folded the QRC-16a role sentence into this description
        // (wording constraints pinned by `PIIScanRoleCopyTests`); the
        // Scan CTA must survive the merge.
        let copy = WU20Strings.description(for: .piiScanPreScan)
        #expect(copy.contains("**Scan Document**"))
    }

    @Test("Browse Templates copy is removed from piiScanPreScan description (WU-20 §4.2)")
    func testBrowseTemplatesCopyRemoved() {
        let copy = WU20Strings.description(for: .piiScanPreScan)
        // Design 04 §4.2 retires the dead "Browse Templates" affordance
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
            .piiScanPreScan, .piiScanPostScanZero(detectorCount: 5),
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

    @Test("PII Scan pre-scan secondary line is nil when no detectors active")
    func piiScanPreScanSecondaryNilWhenNoDetectors() {
        let secondary = WU20Strings.piiScanPreScanSecondary(enabledPIICategoryCount: 0)
        #expect(secondary == nil)
    }

    @Test("PII Scan pre-scan secondary line states the detector count and names no retired control (UXF-23)")
    func piiScanPreScanSecondaryWithDetectors() {
        let secondary = WU20Strings.piiScanPreScanSecondary(enabledPIICategoryCount: 5)
        #expect(secondary != nil)
        #expect(secondary?.contains("5") == true)
        // UXF-23 discipline: never name an affordance the view doesn't
        // have. "Customize" was retired long ago; the Confidence slider
        // retired with the two-interface chassis (Settings' Detection
        // Sensitivity preset is the one engine-level control).
        #expect(secondary?.contains("Customize") == false)
        #expect(secondary?.contains("Confidence slider") == false)
    }

    @Test("PII Scan pre-scan secondary line is mechanism-description (no outcome promise)")
    func piiScanPreScanSecondaryIsMechanism() {
        let secondary = WU20Strings.piiScanPreScanSecondary(enabledPIICategoryCount: 3) ?? ""
        let forbidden = "guarant" + "ee"
        #expect(!secondary.lowercased().contains(forbidden))
        let ensureWord = "ensur" + "e"
        #expect(!secondary.lowercased().contains(ensureWord))
    }

    @Test("PII Scan post-scan zero-result is mechanism-description (no outcome promise)")
    func piiScanPostScanZeroIsMechanism() {
        let copy = WU20Strings.description(for: .piiScanPostScanZero(detectorCount: 7))
        #expect(copy == "7 detectors matched 0 candidates above threshold.")
        // §19 forbidden outcome promises — assembled via concat so
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
        #expect(copy == "1 detector matched 0 candidates above threshold.")
    }

    @Test("Filtered-out copy points at filter chips, mechanism-description")
    func filteredOutCopyMechanism() {
        let copy = WU20Strings.filteredOutDescription
        #expect(copy.contains("filters"))
        let forbidden = "fin" + "d"
        #expect(!copy.lowercased().contains(forbidden))
    }

    @Test("All branches contain no §19 forbidden phrases")
    func allBranchesNoForbiddenPhrases() {
        let allContexts: [WU20Strings.EmptyContext] = [
            .textPreSearch, .textNoMatch,
            .regexPreSearch, .regexNoMatch,
            .multiTermPreSearchNoRecents, .multiTermPreSearchWithRecents,
            .multiTermNoMatch,
            .piiScanPreScan,
            .piiScanPostScanZero(detectorCount: 5),
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

@Suite("SearchState recentMultiTermSets ring (WU-20)", .tags(.search))
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
}

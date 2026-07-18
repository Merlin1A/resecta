import Testing
import Foundation
@testable import ResectaApp
import RedactionEngine

// q11 — piiScan truth + role legibility.
// UXF-02: pre-scan idle state must not claim a completed scan.
// UXF-03 / QRC-14: coverageReport.* + doctypeDiagnostic.* keys must
//   resolve from the "Legal" table (raw-key leakage regression pin).
// QRC-16a: role copy wording constraints.
// UXF-13 (labels only): explicit selection-default labels.

@Suite("q11 — UXF-02 idle honesty")
struct PIIScanIdleHonestyTests {

    @Test("clearResults() resets scan-progress counters so a mode switch cannot fake a completed scan")
    @MainActor
    func clearResultsResetsScanProgress() {
        let state = SearchState()
        state.currentSearchPage = 12
        state.totalPages = 12
        state.clearResults()
        #expect(state.currentSearchPage == 0)
        #expect(state.totalPages == 0)
    }

    @Test("piiScan context is pre-scan after clearResults() even when a prior search had set page progress")
    @MainActor
    func contextIsPreScanAfterClear() {
        let state = SearchState()
        state.currentSearchPage = 7
        state.clearResults()
        let ctx = WU20Strings.context(
            mode: .piiScan,
            queryText: "",
            multiTermTerms: [],
            recentMultiTermSets: [],
            currentSearchPage: state.currentSearchPage,
            totalCount: state.totalCount,
            enabledPIICategoryCount: 17
        )
        #expect(ctx == .piiScanPreScan)
    }

    @Test("pre-scan headline states the actual condition, not a verdict")
    func preScanHeadlineIsHonest() {
        let headline = WU20Strings.headline(for: .piiScanPreScan)
        #expect(headline == "Not scanned yet")
        #expect(!headline.lowercased().contains("complete"))
    }
}

@Suite("q11 — UXF-03 / QRC-14 Legal-table resolution")
struct CoverageReportLocalizationTests {

    /// All 8 coverageReport.* + 3 doctypeDiagnostic.* keys the two
    /// diagnostics views render. A defaulted-table lookup resolves
    /// against Localizable and leaks the raw key to the UI.
    nonisolated static let legalTableKeys: [String] = [
        "coverageReport.title",
        "coverageReport.scannedPages",
        "coverageReport.enabledCategories",
        "coverageReport.candidates",
        "coverageReport.applied",
        "coverageReport.deselected",
        "coverageReport.belowThreshold",
        "coverageReport.overlapSuppressed",
        "doctypeDiagnostic.title",
        "doctypeDiagnostic.topKeywordsHeader",
        "doctypeDiagnostic.subtitle",
    ]

    @Test("every coverage-report and doctype-diagnostic key resolves from the Legal table (no raw-key leakage)", arguments: legalTableKeys)
    func keyResolvesFromLegalTable(key: String) {
        let resolved = String(
            localized: String.LocalizationValue(key),
            table: "Legal",
            bundle: Bundle(for: SearchState.self)
        )
        #expect(resolved != key, "\(key) fell through to the raw key")
        #expect(!resolved.hasPrefix("coverageReport."))
        #expect(!resolved.hasPrefix("doctypeDiagnostic."))
    }
}

@Suite("q11 — QRC-16a role copy")
struct PIIScanRoleCopyTests {

    // UP-6: the role copy moved from the piiScan toolbar
    // (`SearchToolbarSection.piiScanRoleSubtitle`, deleted) into the
    // pre-scan empty state; the QRC-16a wording constraints follow it.

    @Test("Scan role copy states the text-detector mechanism, locality, scope, text-only limit, and rationale visibility")
    func subtitleWordingConstraints() {
        // The copy formerly positioned this mode against the
        // Auto-Detect menu entry; that entry point retired with the
        // two-interface toolbar, so the constraint set is
        // self-contained: the mechanism (PII text detectors), the
        // locality (on-device), the default scope (whole document),
        // the honest capability limit (text content only), and — the
        // interface's role sentence, folded in with the copy pass —
        // rationale visibility (results show the reasoning behind
        // each item). No reference to a surface that no longer
        // exists.
        let copy = WU20Strings.description(for: .piiScanPreScan)
        #expect(copy.contains("on-device"))
        #expect(copy.contains("PII text detectors"))
        #expect(copy.contains("whole document"))
        #expect(copy.contains("text content only"))
        #expect(copy.contains("show why"))
        #expect(!copy.contains("Auto-Detect"))
    }

    @Test("piiScan role copy is mechanism-description (no outcome promise)")
    func subtitleIsMechanism() {
        let copy = WU20Strings.description(for: .piiScanPreScan).lowercased()
        // Forbidden absolutes assembled from halves so this source
        // does not itself trip the M-1 sweep.
        let halves: [(String, String)] = [
            ("guaran", "tee"), ("ens", "ure"), ("all p", "ii"), ("catc", "hes all"), ("10", "0%"),
        ]
        for (a, b) in halves {
            let phrase = a + b
            #expect(!copy.contains(phrase), "forbidden phrase: \(phrase)")
        }
    }
}

@Suite("q11 — UXF-13 review-first selection-default labels")
struct SelectionDefaultLabelTests {

    // The triage sheet's "All N preselected" summary retired with the
    // all-preselected arrival default itself: the review-first arrival rule flips every
    // producer to all-DESELECTED, and the one footer label family
    // below covers both result origins of the unified surface.

    @Test("footer states the none-selected arrival default explicitly — any origin")
    func noneSelectedYet() {
        let label = SearchFooterSection.selectionCountLabel(selected: 0, total: 27)
        #expect(label == "27 found — none selected yet")
    }

    @Test("footer keeps M-of-N form outside the arrival default")
    func footerOtherForms() {
        #expect(SearchFooterSection.selectionCountLabel(selected: 4, total: 27)
                == "4 of 27 selected")
        #expect(SearchFooterSection.selectionCountLabel(selected: 27, total: 27)
                == "27 of 27 selected")
        #expect(SearchFooterSection.selectionCountLabel(selected: 0, total: 0)
                == "0 of 0 selected")
    }
}

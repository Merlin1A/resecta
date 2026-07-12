import Testing
import Foundation
import PDFKit
import RedactionEngine
@testable import ResectaApp

// WU-71 / [P10] path (a) — app-side propagation tests. Verifies that
// `RedactionState.applySearchResults` threads the SearchResult's
// rationale into the region's `Source` so the iPad popover and iPhone
// canvas action sheet can read it via
// `RedactionState.rationale(forRegionID:)`.

@Suite("Region rationale handoff (WU-71)", .tags(.search))
@MainActor
struct RegionRationaleHandoffTests {

    /// Build a minimal SearchResult that the apply path can consume.
    /// All identifying fields (matchedText, contextSnippet, term) are
    /// dummy values; the test only inspects the rationale handoff.
    private func makeResult(rationale: MatchRationale?) -> SearchResult {
        SearchResult(
            id: UUID(),
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            matchedText: "dummy",
            contextSnippet: "...dummy...",
            source: .textLayer,
            term: "dummy",
            isSelected: true,
            piiCategory: nil,
            piiConfidence: nil,
            rationale: rationale
        )
    }

    @Test("Apply search result populates region rationale")
    func applyPropagatesRationale() async {
        let state = RedactionState()
        let search = SearchState()
        let rationale = MatchRationale(
            ruleID: "test.rule",
            signals: [.regexPattern(name: "test.pattern")],
            preThresholdScore: 0.5,
            finalScore: 0.8,
            appliedThreshold: 0.6
        )
        search.appendResult(makeResult(rationale: rationale))
        search.flushPendingResults()
        state.activeSearch = search

        _ = await state.applySearchResults(undoManager: nil)

        guard let region = state.regions[0]?.first else {
            Issue.record("expected one region after apply")
            return
        }
        switch region.source {
        case .searchMatch(_, let propagated):
            #expect(propagated == rationale, "rationale must propagate verbatim into Source")
        default:
            Issue.record("expected .searchMatch source, got \(region.source)")
        }
    }

    @Test("Apply with nil rationale leaves Source.rationale nil")
    func applyWithNilRationaleStaysNil() async {
        let state = RedactionState()
        let search = SearchState()
        search.appendResult(makeResult(rationale: nil))
        search.flushPendingResults()
        state.activeSearch = search

        _ = await state.applySearchResults(undoManager: nil)

        guard let region = state.regions[0]?.first else {
            Issue.record("expected one region after apply")
            return
        }
        switch region.source {
        case .searchMatch(_, let propagated):
            #expect(propagated == nil)
        default:
            Issue.record("expected .searchMatch source")
        }
    }

    @Test("rationale(forRegionID:) returns the propagated MatchRationale")
    func rationaleLookupRoundTrip() async {
        let state = RedactionState()
        let search = SearchState()
        let rationale = MatchRationale(
            ruleID: "lookup.test",
            signals: [],
            preThresholdScore: 0.4,
            finalScore: 0.7,
            appliedThreshold: nil
        )
        search.appendResult(makeResult(rationale: rationale))
        search.flushPendingResults()
        state.activeSearch = search

        _ = await state.applySearchResults(undoManager: nil)
        guard let region = state.regions[0]?.first else {
            Issue.record("no region applied")
            return
        }
        let looked = state.rationale(forRegionID: region.id)
        #expect(looked == rationale)
    }

    @Test("Audit export carries rationale via existing MatchAuditSnapshot path")
    func auditExportIncludesRationale() async {
        let state = RedactionState()
        let search = SearchState()
        let rationale = MatchRationale(
            ruleID: "audit.test",
            signals: [.regexPattern(name: "audit.pattern")],
            preThresholdScore: 0.5,
            finalScore: 0.9,
            appliedThreshold: 0.7
        )
        search.appendResult(makeResult(rationale: rationale))
        search.flushPendingResults()
        state.activeSearch = search

        _ = await state.applySearchResults(undoManager: nil)

        // The audit pathway (MatchAuditSnapshot) already carried rationale
        // pre-WU-71. WU-71 leaves that pathway intact and adds a parallel
        // path via Source. Verify the audit snapshot still carries it.
        let snapshots = state.appliedMatchAuditSnapshots
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.rationale == rationale)
    }

    @Test("rationaleMenuShouldShow gates on Source rationale presence")
    func canvasMenuGatedOnRationale() {
        let withRationale = RedactionRegion(
            id: UUID(),
            normalizedRect: .zero,
            source: .searchMatch(
                term: "x",
                rationale: MatchRationale(ruleID: "r", preThresholdScore: 0, finalScore: 0)
            )
        )
        let withoutRationale = RedactionRegion(
            id: UUID(),
            normalizedRect: .zero,
            source: .searchMatch(term: "x", rationale: nil)
        )
        let manual = RedactionRegion(id: UUID(), normalizedRect: .zero, source: .manual)
        let face = RedactionRegion(id: UUID(), normalizedRect: .zero, source: .detectedFace)

        #expect(RedactionOverlayView.rationaleMenuShouldShow(region: withRationale))
        #expect(!RedactionOverlayView.rationaleMenuShouldShow(region: withoutRationale))
        #expect(!RedactionOverlayView.rationaleMenuShouldShow(region: manual))
        #expect(!RedactionOverlayView.rationaleMenuShouldShow(region: face))
    }
}

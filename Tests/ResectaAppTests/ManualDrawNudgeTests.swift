import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Manual-draw nearby-PII nudge predicate + accept
// path + suppression boundary resets. The predicate
// `RedactionState.nearbyUnappliedPIIMatch(...)` is pure and pinned
// without a SwiftUI host; the boundary-reset tests instantiate a
// `RedactionState` to exercise the didSet on `activeSearch` and the
// explicit resets in `clearAll()` + `clearForNewDocument()`, which are
// load-bearing scope. The rationale-continuity test pins
// the accept-seam handoff — a nudge-accepted region
// carries `.searchMatch(term:rationale:)` with the source result's
// rationale intact, so `RedactionState.rationale(forRegionID:)`
// continues to surface the rationale on the canvas.

@Suite("Manual-draw nearby-PII nudge")
@MainActor
struct ManualDrawNudgeTests {

    // MARK: - Helpers

    /// Build a manual-source region at the given normalized rect.
    static func manualRegion(at rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    /// Build a PII search result on `page` at `rect`. The rationale carries
    /// a stable rule ID so the continuity test can assert it survives
    /// the accept path.
    static func piiResult(
        id: UUID = UUID(),
        page: Int = 0,
        rect: CGRect,
        category: PIICategory = .ssn,
        ruleID: String = "ssn.state-machine"
    ) -> SearchResult {
        let rationale = MatchRationale(
            ruleID: ruleID,
            signals: [.regexPattern(name: "ssn.sep")],
            preThresholdScore: 0.85,
            finalScore: 0.85,
            appliedThreshold: 0.5
        )
        return SearchResult(
            id: id,
            pageIndex: page,
            normalizedRect: rect,
            matchedText: "123-45-6789",
            contextSnippet: "ssn 123-45-6789 line",
            source: .textLayer,
            term: category.rawValue,
            isSelected: false,
            piiCategory: category,
            piiConfidence: 0.85,
            rationale: rationale
        )
    }

    // MARK: - (a) Proximity threshold (load-bearing)

    @Test("Just-inside 50pt proximity surfaces the match")
    func proximityJustInsideFires() {
        // Added region near top-left; PII match a hair closer than the
        // 0.082 normalized threshold (≈ 50pt on letter at 72 DPI).
        let added = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        let result = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        // Edge-to-edge dx = 0.18 - 0.15 = 0.03; dy = 0; dist ≈ 0.03 < 0.082.
        let match = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: added,
            page: 0,
            results: [result],
            appliedIDs: [],
            suppressed: false,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized
        )
        #expect(match?.id == result.id)
    }

    @Test("Just-outside 50pt proximity does NOT surface the match")
    func proximityJustOutsideSilent() {
        let added = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        // Place PII match far enough that the edge-to-edge distance
        // exceeds the 0.082 normalized threshold. dx = 0.30 - 0.15 = 0.15.
        let result = Self.piiResult(rect: CGRect(x: 0.30, y: 0.10, width: 0.05, height: 0.02))
        let match = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: added,
            page: 0,
            results: [result],
            appliedIDs: [],
            suppressed: false,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized
        )
        #expect(match == nil)
    }

    // MARK: - (b) Applied-IDs filter

    @Test("Match already in appliedResultIDs is skipped")
    func appliedMatchSkipped() {
        let added = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        let result = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        let match = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: added,
            page: 0,
            results: [result],
            appliedIDs: [result.id],
            suppressed: false,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized
        )
        #expect(match == nil)
    }

    // MARK: - Category + page + overlap filters

    @Test("Non-PII (text/regex) results are skipped")
    func nonPIIResultsSkipped() {
        let added = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        // Text-mode result has piiCategory == nil.
        let textResult = SearchResult(
            id: UUID(),
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02),
            matchedText: "Alice",
            contextSnippet: "hi Alice",
            source: .textLayer,
            term: "Alice",
            piiCategory: nil,
            piiConfidence: nil,
            rationale: nil
        )
        let match = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: added,
            page: 0,
            results: [textResult],
            appliedIDs: [],
            suppressed: false,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized
        )
        #expect(match == nil)
    }

    @Test("Cross-page candidates are skipped")
    func crossPageCandidatesSkipped() {
        let added = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        // Same normalized rect, but on page 3. Predicate scopes to `page`.
        let result = Self.piiResult(page: 3, rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        let match = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: added,
            page: 0,
            results: [result],
            appliedIDs: [],
            suppressed: false,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized
        )
        #expect(match == nil)
    }

    @Test("Candidate already covered by the new region (>80% overlap) is skipped")
    func selfOverlapSkipped() {
        // Manual region totally enclosing the PII match — user drew over it.
        let added = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.10, height: 0.04))
        let result = Self.piiResult(rect: CGRect(x: 0.12, y: 0.12, width: 0.04, height: 0.02))
        let match = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: added,
            page: 0,
            results: [result],
            appliedIDs: [],
            suppressed: false,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized
        )
        #expect(match == nil)
    }

    // MARK: - (c) Suppression bypass

    @Test("suppressed=true short-circuits the predicate")
    func suppressionBypassesPredicate() {
        let added = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        let result = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        let match = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: added,
            page: 0,
            results: [result],
            appliedIDs: [],
            suppressed: true,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized
        )
        #expect(match == nil)
    }

    // MARK: - (c) Suppression boundary resets (load-bearing)

    @Test("boundary (a): activeSearch transition resets suppression")
    func boundaryActiveSearchTransitionResets() {
        let state = RedactionState()
        let search = SearchState()
        state.activeSearch = search
        state.setManualDrawNudgeSuppressedForTesting(true)
        #expect(state.manualDrawNudgeSuppressedForSession == true)
        // Sheet dismiss — activeSearch → nil fires the didSet which resets.
        state.activeSearch = nil
        #expect(state.manualDrawNudgeSuppressedForSession == false)
    }

    @Test("boundary (a) replay: re-opening the sheet resets again")
    func boundaryActiveSearchReplayResets() {
        let state = RedactionState()
        // First session: flag set, then dismiss, then re-open.
        state.activeSearch = SearchState()
        state.setManualDrawNudgeSuppressedForTesting(true)
        state.activeSearch = nil
        // Second session starts with a clean flag from the dismissal above;
        // suppress again to prove the next transition still resets.
        state.setManualDrawNudgeSuppressedForTesting(true)
        state.activeSearch = SearchState()
        #expect(state.manualDrawNudgeSuppressedForSession == false)
    }

    @Test("boundary (b): clearForNewDocument resets suppression")
    func boundaryNewDocumentResets() {
        let state = RedactionState()
        state.setManualDrawNudgeSuppressedForTesting(true)
        state.pendingManualDrawNudge = Self.piiResult(rect: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.02))
        #expect(state.manualDrawNudgeSuppressedForSession == true)
        state.clearForNewDocument()
        #expect(state.manualDrawNudgeSuppressedForSession == false)
        #expect(state.pendingManualDrawNudge == nil)
    }

    @Test("boundary (c): clearAll resets suppression")
    func boundaryClearAllResets() {
        let state = RedactionState()
        state.setManualDrawNudgeSuppressedForTesting(true)
        state.pendingManualDrawNudge = Self.piiResult(rect: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.02))
        #expect(state.manualDrawNudgeSuppressedForSession == true)
        state.clearAll()
        #expect(state.manualDrawNudgeSuppressedForSession == false)
        #expect(state.pendingManualDrawNudge == nil)
    }

    // MARK: - (d) Accept path + rationale continuity (load-bearing)

    @Test("Accept path creates a region whose Source carries the result's rationale")
    func acceptPropagatesRationale() {
        let state = RedactionState()
        let search = SearchState()
        state.activeSearch = search
        let resultRect = CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02)
        let nudge = Self.piiResult(rect: resultRect, ruleID: "ssn.state-machine.v2")
        // Direct accept path with the value-type capture, matching the
        // closure-capture pattern the toast actionHandler uses.
        let region = state.acceptManualDrawNudge(nudge, undoManager: nil)
        #expect(region != nil)
        guard let region else { return }
        // Source is `.searchMatch` carrying the rationale.
        if case .searchMatch(let term, let rationale) = region.source {
            #expect(term == nudge.term)
            #expect(rationale?.ruleID == "ssn.state-machine.v2")
        } else {
            Issue.record("Accepted region source is not .searchMatch")
        }
        // Canvas surfaces look up the rationale via `rationale(forRegionID:)`.
        let lookup = state.rationale(forRegionID: region.id)
        #expect(lookup?.ruleID == "ssn.state-machine.v2")
    }

    @Test("Accept path inserts the result ID into appliedResultIDs")
    func acceptUpdatesAppliedResultIDs() {
        let state = RedactionState()
        let search = SearchState()
        state.activeSearch = search
        let nudge = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        _ = state.acceptManualDrawNudge(nudge, undoManager: nil)
        #expect(search.appliedResultIDs.contains(nudge.id))
    }

    @Test("Accept path clears pendingManualDrawNudge without setting suppression")
    func acceptClearsPendingWithoutSuppressing() {
        let state = RedactionState()
        let search = SearchState()
        state.activeSearch = search
        let nudge = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        state.pendingManualDrawNudge = nudge
        _ = state.acceptManualDrawNudge(nudge, undoManager: nil)
        #expect(state.pendingManualDrawNudge == nil)
        // Suppression is set by the toast-enqueue path, not by accept.
        #expect(state.manualDrawNudgeSuppressedForSession == false)
    }

    @Test("Accept after the search session closed still adds the match as an applied region")
    func acceptWithoutALiveSessionAddsTheRegion() {
        let state = RedactionState()
        // The toast outlives the sheet: the session is gone when the
        // Add button is tapped. The nudge carries everything the region
        // needs (its rect, term and rationale).
        let nudge = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        state.pendingManualDrawNudge = nudge
        let region = state.acceptManualDrawNudge(nudge, undoManager: nil)
        #expect(region != nil, "today the accept refuses without a live session")
        #expect(state.regions[nudge.pageIndex]?.count == 1)
        #expect(state.liveAppliedSearchResultIDs == [nudge.id])
        #expect(state.pendingManualDrawNudge == nil)
    }

    @Test("markManualDrawNudgeSuppressed sets the flag and clears the pending nudge")
    func markSuppressedSetsFlagAndClears() {
        let state = RedactionState()
        state.activeSearch = SearchState()
        state.pendingManualDrawNudge = Self.piiResult(rect: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.02))
        state.markManualDrawNudgeSuppressed()
        #expect(state.manualDrawNudgeSuppressedForSession == true)
        #expect(state.pendingManualDrawNudge == nil)
    }

    // MARK: - addRegion post-add hook integration

    @Test("addRegion on a manual region with a nearby unapplied PII match sets pendingManualDrawNudge")
    func addRegionTriggersNudge() {
        let state = RedactionState()
        let search = SearchState()
        let candidate = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        search.results = [candidate]
        state.activeSearch = search
        let manual = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        state.addRegion(manual, page: 0, undoManager: nil)
        #expect(state.pendingManualDrawNudge?.id == candidate.id)
    }

    @Test("addRegion on a manual region with NO nearby match leaves pending nil")
    func addRegionWithoutMatchSilent() {
        let state = RedactionState()
        let search = SearchState()
        let farResult = Self.piiResult(rect: CGRect(x: 0.50, y: 0.50, width: 0.05, height: 0.02))
        search.results = [farResult]
        state.activeSearch = search
        let manual = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        state.addRegion(manual, page: 0, undoManager: nil)
        #expect(state.pendingManualDrawNudge == nil)
    }

    @Test("addRegion on a .searchMatch source does NOT fire the nudge (avoids recursion)")
    func searchMatchSourceSkipsNudge() {
        let state = RedactionState()
        let search = SearchState()
        let candidate = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        search.results = [candidate]
        state.activeSearch = search
        let nonManual = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02),
            source: .searchMatch(term: "ssn", rationale: nil)
        )
        state.addRegion(nonManual, page: 0, undoManager: nil)
        #expect(state.pendingManualDrawNudge == nil)
    }

    // MARK: - Covered matches

    @Test("A name another region already covers does not nudge when a region is drawn beside it")
    func coveredMatchSkippedWhenDrawingBeside() {
        let state = RedactionState()
        let search = SearchState()
        let name = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        search.results = [name]
        state.activeSearch = search
        // The user draws over the name first: the new region covers it,
        // so that draw is silent (the self-overlap skip).
        let cover = Self.manualRegion(at: CGRect(x: 0.17, y: 0.09, width: 0.07, height: 0.04))
        state.addRegion(cover, page: 0, undoManager: nil)
        #expect(state.pendingManualDrawNudge == nil, "precondition: drawing over the name is silent")

        // Then a region beside it: 0.03 from the name, clear of `cover`.
        let beside = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        state.addRegion(beside, page: 0, undoManager: nil)
        #expect(state.pendingManualDrawNudge == nil,
                "today the nudge offers the name: the predicate tests only the NEW region's overlap")
    }

    @Test("A name no region covers still nudges when a region is drawn beside it")
    func uncoveredMatchStillNudges() {
        let state = RedactionState()
        let search = SearchState()
        let name = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        search.results = [name]
        state.activeSearch = search
        // A region elsewhere on the page that does not cover the name.
        let elsewhere = Self.manualRegion(at: CGRect(x: 0.60, y: 0.60, width: 0.10, height: 0.04))
        state.addRegion(elsewhere, page: 0, undoManager: nil)
        state.pendingManualDrawNudge = nil

        let beside = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        state.addRegion(beside, page: 0, undoManager: nil)
        #expect(state.pendingManualDrawNudge?.id == name.id)
    }

    @Test("The apply and the nudge share one coverage rule: a covered name is covered for both")
    func applyAndNudgeAgreeOnCoverage() async {
        let state = RedactionState()
        let search = SearchState()
        let name = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))
        search.results = [name]
        state.activeSearch = search
        let cover = Self.manualRegion(at: CGRect(x: 0.17, y: 0.09, width: 0.07, height: 0.04))
        state.addRegion(cover, page: 0, undoManager: nil)

        // The strip's Apply on the covered name: dedup-skipped as covered.
        let outcome = await state.applyFindings(.searchResult(id: name.id), undoManager: nil)
        #expect(outcome?.coveredResultIDs == [name.id])
        #expect(outcome?.applied == 0)

        // The nudge reads the same rule for a draw beside it.
        let beside = Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02))
        state.addRegion(beside, page: 0, undoManager: nil)
        #expect(state.pendingManualDrawNudge == nil)
    }

    // MARK: - (e) The accept refuses while a run owns the regions

    @Test("An accept while a run owns the regions changes nothing")
    func acceptDuringARunChangesNothing() {
        // The toast outlives the run start: its Add can be tapped while
        // the pipeline is burning or verifying the pages.
        let phases: [(String, DocumentState.Phase)] = [
            ("detecting", .detecting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "Starting"))),
            ("redacting", .redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "Starting"))),
            ("verifying", .verifying(progress: .init(currentLayer: 1, totalLayers: 5,
                                                     layerName: "Layer 1", completedLayers: []))),
            ("exporting", .exporting),
        ]
        for (label, phase) in phases {
            let state = RedactionState()
            let doc = DocumentState()
            doc.phase = phase
            let output = URL(fileURLWithPath: "/tmp/redacted.pdf")
            state.outputURL = output
            let versionBefore = state.regionVersion
            let nudge = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))

            let region = state.acceptManualDrawNudge(nudge, undoManager: nil, documentState: doc)

            #expect(region == nil, "\(label): the accept must refuse")
            #expect(state.regions.values.allSatisfy { $0.isEmpty }, "\(label): no region added")
            #expect(state.regionMetadata.isEmpty && state.appliedMatchAudit.isEmpty, "\(label)")
            #expect(state.regionVersion == versionBefore, "\(label): no region-version bump")
            #expect(state.outputURL == output, "\(label): the run's output stays linked")
        }
    }

    @Test("An accept in the editing phase still adds the match")
    func acceptWhileEditingAddsTheRegion() {
        let state = RedactionState()
        let doc = DocumentState()
        doc.phase = .editing
        let nudge = Self.piiResult(rect: CGRect(x: 0.18, y: 0.10, width: 0.05, height: 0.02))

        let region = state.acceptManualDrawNudge(nudge, undoManager: nil, documentState: doc)

        #expect(region != nil)
        #expect(state.regions[nudge.pageIndex]?.count == 1)
    }

    @Test("A run start drops the nearby-match toast")
    func runStartDropsTheNudgeToast() {
        let coord = makeLoadedCoordinator()
        let toasts = ToastQueueManager()
        coord.toastManager = toasts
        coord.redactionState.addRegion(
            Self.manualRegion(at: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02)),
            page: 0, undoManager: nil)
        toasts.enqueue("1 match nearby. Add to selection?", actionLabel: "Add", editsRegions: true) {}
        #expect(toasts.activeToasts.count == 1)

        coord.runFullPipeline(documentOverride: nil)
        defer { coord.documentState.cancelActivePipeline(redactionState: coord.redactionState) }

        #expect(coord.documentState.activePipelineTask != nil, "the run started")
        #expect(!toasts.activeToasts.contains { $0.editsRegions })
    }
}

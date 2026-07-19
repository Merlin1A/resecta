import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The one apply seam (`RedactionState.applyFindings`): every result
// origin promotes through one commit transaction that creates the
// regions AND writes the audit records — `RegionMetadata` plus
// `MatchAuditSnapshot` with `regionID` populated — with one two-leg
// undo implementation underneath.
//
// Four contract families pinned here:
//   1. Search-origin preservation — the outputs the pre-seam search
//      apply produced, produced identically by the seam.
//   2. Detection-origin audit parity — the records the detection side
//      never wrote, now written truthfully: fields the origin lacks
//      (query term, `MatchRationale`, per-word OCR confidence) stay
//      nil rather than carrying invented values.
//   3. One undo implementation — undo removes regions + metadata +
//      audit in lockstep and restores recorded decisions; redo
//      re-inserts all three without re-recording decisions.
//   4. The mutation re-guard — every origin refuses to mutate while
//      the pipeline owns `regions`, re-checked inside the action.

// MARK: - Shared fixtures

@MainActor
private func makeSearchResult(
    page: Int = 0,
    y: Double = 0.1,
    matchedText: String = "123-45-6789",
    term: String = "PII Scan",
    source: SearchSource = .textLayer,
    piiCategory: PIICategory? = .ssn,
    rationale: MatchRationale? = nil,
    isSelected: Bool = true
) -> SearchResult {
    SearchResult(
        pageIndex: page,
        normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.04),
        matchedText: matchedText,
        contextSnippet: "…\(matchedText)…",
        source: source,
        term: term,
        isSelected: isSelected,
        piiCategory: piiCategory,
        piiConfidence: piiCategory == nil ? nil : 0.91,
        rationale: rationale
    )
}

private func makeDetection(
    page: Int = 0,
    y: Double = 0.5,
    kind: DetectionResult.Kind = .pii(.ssn),
    confidence: Double = 0.9,
    matchedText: String? = "123-45-6789",
    provenance: DetectionResult.Provenance = .ocrRan
) -> DetectionResult {
    DetectionResult(
        normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.04),
        kind: kind,
        confidence: confidence,
        matchedText: matchedText,
        recognitionLevel: .accurate,
        provenance: provenance
    )
}

/// A DocumentState parked in a pipeline-owning phase
/// (`canMutateRegions == false`).
@MainActor
private func pipelineOwnedDocumentState() -> DocumentState {
    let doc = DocumentState()
    doc.phase = .editing
    doc.transition(to: .detecting(
        progress: .init(currentPage: 0, totalPages: 1, currentStep: "Starting")))
    precondition(!doc.canMutateRegions)
    return doc
}

// MARK: - 1. Search-origin preservation

@Suite("Apply seam — search-origin preservation")
@MainActor
struct ApplySeamSearchOriginTests {

    @Test("Region, metadata, and audit outputs carry the result's own values")
    func outputsCarryResultValues() async {
        let state = RedactionState()
        let search = SearchState()
        let result = makeSearchResult(
            source: .ocr(confidence: 0.87),
            rationale: MatchRationale(
                ruleID: "ssn.pattern",
                signals: [.presetThresholdPass(raw: 0.91, cutoff: 0.7)],
                preThresholdScore: 0.91,
                finalScore: 0.91,
                appliedThreshold: 0.7
            )
        )
        search.results = [result]
        state.activeSearch = search

        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(outcome?.applied == 1)
        guard let region = state.regions[0]?.first else {
            Issue.record("no region created")
            return
        }
        #expect(region.normalizedRect == result.normalizedRect)
        #expect(region.source == .searchMatch(term: result.term, rationale: result.rationale))

        let meta = state.regionMetadata[region.id]
        #expect(meta?.piiKind == .pii(.ssn))
        #expect(meta?.matchedText == result.matchedText)

        let audit = state.appliedMatchAudit[region.id]
        #expect(audit?.origin == .search)
        #expect(audit?.regionID == region.id)
        #expect(audit?.resultID == result.id)
        #expect(audit?.matchedText == result.matchedText)
        #expect(audit?.term == result.term)
        #expect(audit?.source == .ocr(confidence: 0.87))
        #expect(audit?.rationale?.ruleID == "ssn.pattern")
    }

    @Test("Overlap skips still earn no region, no badge membership, no audit entry")
    func overlapSkipContractCarries() async {
        let state = RedactionState()
        // Pre-existing region exactly where the first result sits.
        let prior = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.04),
            source: .manual
        )
        state.regions[0] = [prior]
        let search = SearchState()
        let covered = makeSearchResult(y: 0.1)
        let fresh = makeSearchResult(y: 0.6, matchedText: "987-65-4321")
        search.results = [covered, fresh]
        state.activeSearch = search

        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(outcome?.applied == 1)
        #expect(outcome?.skippedOverlaps == 1)
        #expect(outcome?.appliedResultIDs == [fresh.id],
                "only the survivor joins the applied-badge set")
        #expect(state.appliedMatchAudit.count == 1)
    }

    @Test("Empty selection returns the zero outcome with no version bump")
    func emptySelectionIsInert() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [makeSearchResult(isSelected: false)]
        state.activeSearch = search
        let versionBefore = state.regionVersion

        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(outcome == .zero)
        #expect(state.regionVersion == versionBefore,
                "an inert apply must not signal a region mutation")
    }

    @Test("No active search returns nil")
    func noActiveSearchRefuses() async {
        let state = RedactionState()
        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)
        #expect(outcome == nil)
    }

    @Test("The seam owns the conditional-dismiss tracker reset for the search origin")
    func trackerResetOwnedBySeam() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [makeSearchResult()]
        search.userModifiedSelections = true
        state.activeSearch = search

        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(search.userModifiedSelections == false,
                "committed selections reset the tracker inside the path")
    }
}

// MARK: - 2. Detection-origin audit parity

@Suite("Apply seam — detection-origin audit parity")
@MainActor
struct ApplySeamDetectionOriginTests {

    @Test("Staged-review apply writes metadata AND audit per created region")
    func stagedApplyWritesBothRecords() async {
        let state = RedactionState()
        let ocrDetection = makeDetection(page: 0)
        let textLayerDetection = makeDetection(
            page: 2, kind: .pii(.email), matchedText: "j@x.com",
            provenance: .ocrSkippedDueToCoverage)
        state.pendingTriage = [0: [ocrDetection], 2: [textLayerDetection]]
        state.triageSelections = [ocrDetection.id: true, textLayerDetection.id: true]

        let outcome = await state.applyFindings(.stagedDetections, undoManager: nil)

        #expect(outcome?.applied == 2)
        let allRegions = state.regions.values.flatMap { $0 }
        #expect(allRegions.count == 2)
        for region in allRegions {
            #expect(state.regionMetadata[region.id] != nil,
                    "every created region carries metadata")
            let audit = state.appliedMatchAudit[region.id]
            #expect(audit != nil, "every created region carries an audit record")
            #expect(audit?.origin == .scan)
            #expect(audit?.regionID == region.id,
                    "regionID is populated for the scan origin too")
            #expect(audit?.term == nil,
                    "a detection run has no query term — nil, never invented")
            #expect(audit?.rationale == nil,
                    "DetectionResult carries no MatchRationale — nil, never invented")
        }

        // Source truthfulness: provenance-recorded text-layer production
        // carries through; an OCR-ran page has no per-word OCR
        // confidence at this granularity, so the field stays nil.
        let page0Audit = state.regions[0].flatMap { $0.first }
            .flatMap { state.appliedMatchAudit[$0.id] }
        let page2Audit = state.regions[2].flatMap { $0.first }
            .flatMap { state.appliedMatchAudit[$0.id] }
        #expect(page0Audit?.source == nil)
        #expect(page0Audit?.piiConfidence == ocrDetection.confidence)
        #expect(page0Audit?.matchedText == ocrDetection.matchedText)
        #expect(page2Audit?.source == .textLayer)
        #expect(page2Audit?.piiCategory == .email)
    }

    @Test("Group apply writes audit records for every promoted member")
    func groupApplyWritesAudit() async {
        let state = RedactionState()
        let a = makeDetection(page: 1, kind: .pii(.name), matchedText: "John Doe")
        let b = makeDetection(page: 3, kind: .pii(.name), matchedText: "John Doe")
        state.pendingTriage = [1: [a], 3: [b]]
        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("expected the John Doe cluster")
            return
        }

        let outcome = await state.applyFindings(.entityGroup(group), undoManager: nil)

        #expect(outcome?.applied == 2)
        #expect(state.appliedMatchAudit.count == 2)
        for region in state.regions.values.flatMap({ $0 }) {
            #expect(state.appliedMatchAudit[region.id]?.origin == .scan)
            #expect(state.appliedMatchAudit[region.id]?.regionID == region.id)
        }
    }

    @Test("Detection-map apply writes both records; routed signature candidates get neither")
    func detectionMapApplyWritesBothRecords() async {
        let state = RedactionState()
        let ssn = makeDetection(page: 0)
        let signature = makeDetection(
            page: 1, kind: .pii(.signatureCandidate), matchedText: nil)

        let outcome = await state.applyFindings(
            .detectionResults([0: [ssn], 1: [signature]]), undoManager: nil)

        #expect(outcome?.applied == 1)
        #expect(outcome?.signatureCandidates == 1)
        guard let region = state.regions[0]?.first else {
            Issue.record("no region created")
            return
        }
        #expect(state.regionMetadata[region.id] != nil)
        #expect(state.appliedMatchAudit[region.id]?.origin == .scan)
        // The routed candidate created no region, so no records exist for
        // it — audit describes applied regions only.
        #expect(state.appliedMatchAudit.count == 1)
        #expect(state.regionMetadata.count == 1)
    }

    @Test("A face detection's audit record tolerates absent text and pairs its PII fields")
    func faceDetectionAuditHasNilText() async {
        let state = RedactionState()
        let face = makeDetection(page: 0, kind: .face, matchedText: nil)
        state.pendingTriage = [0: [face]]
        state.triageSelections = [face.id: true]

        _ = await state.applyFindings(.stagedDetections, undoManager: nil)

        let audit = state.appliedMatchAudit.values.first
        #expect(audit != nil)
        #expect(audit?.matchedText == nil)
        #expect(audit?.piiCategory == nil)
        #expect(audit?.piiConfidence == nil,
                "a face detector's confidence is not a PII confidence — the pair stays nil together")
        // The raw confidence still travels on the region's metadata.
        let regionID = state.regions[0]?.first?.id
        #expect(regionID.flatMap { state.regionMetadata[$0] }?.confidence == 0.9)
    }

    @Test("Detection-origin applies never record the search apply-version marker")
    func detectionOriginSkipsMarker() async {
        let state = RedactionState()
        let detection = makeDetection()
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: true]

        _ = await state.applyFindings(.stagedDetections, undoManager: nil)

        #expect(state.lastAppliedSearchRegionVersion == -1,
                "the applied-marker discrimination belongs to the search origin only")
        #expect(state.regionVersion > 0)
    }

    @Test("Staged apply resets the dismiss tracker; a group apply keeps it set")
    func trackerRuleByOrigin() async {
        let state = RedactionState()
        let search = SearchState()
        state.activeSearch = search

        let a = makeDetection(page: 1, kind: .pii(.name), matchedText: "John Doe")
        let b = makeDetection(page: 3, kind: .pii(.name), matchedText: "John Doe")
        let c = makeDetection(page: 0, kind: .pii(.email), matchedText: "j@x.com")
        state.pendingTriage = [0: [c], 1: [a], 3: [b]]
        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("expected the John Doe cluster")
            return
        }

        // A group promotion is a partial commit — the remaining review
        // selections are still live work.
        search.userModifiedSelections = true
        _ = await state.applyFindings(.entityGroup(group), undoManager: nil)
        #expect(search.userModifiedSelections == true)

        // The full staged apply resolves the selection context.
        state.triageSelections[c.id] = true
        _ = await state.applyFindings(.stagedDetections, undoManager: nil)
        #expect(search.userModifiedSelections == false)
    }
}

// MARK: - 3. One undo implementation

@Suite("Apply seam — one undo implementation")
@MainActor
struct ApplySeamUndoTests {

    @Test("Staged-apply undo removes regions + metadata + audit and restores decisions; redo re-inserts without re-recording")
    func stagedUndoRedoLockstep() async {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let detection = makeDetection()
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: true]

        undo.beginUndoGrouping()
        _ = await state.applyFindings(.stagedDetections, undoManager: undo)
        undo.endUndoGrouping()

        guard let regionID = state.regions[0]?.first?.id else {
            Issue.record("no region created")
            return
        }
        #expect(state.regionMetadata[regionID] != nil)
        #expect(state.appliedMatchAudit[regionID] != nil)
        #expect(state.priors.mean(.ssn) > 0.5)
        #expect(state.surfaceForms.lookup("123-45-6789") == .accepted)

        let versionAfterApply = state.regionVersion
        undo.undo()
        #expect(state.regions[0]?.isEmpty ?? true)
        #expect(state.regionMetadata[regionID] == nil)
        #expect(state.appliedMatchAudit[regionID] == nil,
                "audit entries drop in lockstep with their regions")
        #expect(state.priors.mean(.ssn) == 0.5, "recorded decisions restore on undo")
        #expect(state.surfaceForms.lookup("123-45-6789") == nil)
        #expect(state.pendingTriage == nil, "undo does not reopen the review")
        #expect(state.regionVersion > versionAfterApply,
                "the undo leg bumps regionVersion — the canvas overlay refresh gate and the sheet's applied-marker clear both key on it")

        let versionAfterUndo = state.regionVersion
        undo.redo()
        #expect(state.regions[0]?.count == 1)
        #expect(state.regionMetadata[regionID] != nil)
        #expect(state.appliedMatchAudit[regionID] != nil)
        #expect(state.priors.mean(.ssn) == 0.5,
                "redo re-inserts the artifacts without re-recording decisions — carried semantics")
        #expect(state.regionVersion > versionAfterUndo,
                "the redo leg is a region mutation too")
    }

    @Test("Group-apply undo restores decisions and drops all three artifact sets")
    func groupUndoParity() async {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let a = makeDetection(page: 1, kind: .pii(.name), matchedText: "John Doe")
        let b = makeDetection(page: 3, kind: .pii(.name), matchedText: "John Doe")
        state.pendingTriage = [1: [a], 3: [b]]
        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("expected the John Doe cluster")
            return
        }

        undo.beginUndoGrouping()
        _ = await state.applyFindings(.entityGroup(group), undoManager: undo)
        undo.endUndoGrouping()
        #expect(state.priors.mean(.name) > 0.5)
        #expect(state.appliedMatchAudit.count == 2)

        undo.undo()
        #expect(state.priors.mean(.name) == 0.5)
        #expect(state.regions.values.flatMap { $0 }.isEmpty)
        #expect(state.regionMetadata.isEmpty)
        #expect(state.appliedMatchAudit.isEmpty)
    }

    @Test("Search-apply undo leaves priors untouched — no decision snapshot for that origin")
    func searchUndoDoesNotTouchPriors() async {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        // Seed a non-default prior so an accidental restore would move it.
        state.priors = state.priors.updated(category: .ssn, decision: .accepted)
        let priorMean = state.priors.mean(.ssn)

        let search = SearchState()
        search.results = [makeSearchResult()]
        state.activeSearch = search

        undo.beginUndoGrouping()
        _ = await state.applyFindings(.selectedSearchResults, undoManager: undo)
        undo.endUndoGrouping()
        let versionAfterApply = state.regionVersion
        undo.undo()

        #expect(state.priors.mean(.ssn) == priorMean,
                "the search origin records no decisions, so undo restores none")
        #expect(state.regions.values.flatMap { $0 }.isEmpty)
        #expect(state.appliedMatchAudit.isEmpty)
        #expect(state.regionVersion > versionAfterApply,
                "search-origin undo bumps past the recorded apply version so `shouldClearAppliedMarkers` can distinguish it from the apply's own bump")
        #expect(state.regionVersion != state.lastAppliedSearchRegionVersion,
                "the marker handler reads this inequality as a real undo")
    }

    @Test("Batch delete undo bumps regionVersion on the restore leg")
    func removeRegionsUndoBumpsVersion() {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let region = makeDetection().toRegion()
        state.addRegion(region, page: 0, undoManager: nil)

        let versionBefore = state.regionVersion
        undo.beginUndoGrouping()
        state.removeRegions([region.id], page: 0, undoManager: undo)
        undo.endUndoGrouping()
        #expect(state.regions[0]?.isEmpty ?? true)
        #expect(state.regionVersion > versionBefore)

        let versionAfterDelete = state.regionVersion
        undo.undo()
        #expect(state.regions[0]?.count == 1, "undo re-inserts the deleted region")
        #expect(state.regionVersion > versionAfterDelete,
                "the undo leg is a region mutation — the overlay refresh gate keys on the bump")

        let versionAfterUndo = state.regionVersion
        undo.redo()
        #expect(state.regions[0]?.isEmpty ?? true, "redo re-deletes")
        #expect(state.regionVersion > versionAfterUndo,
                "the redo leg recurses into removeRegions, which bumps at entry")
    }
}

// MARK: - 4. Mutation re-guard

@Suite("Apply seam — mutation re-guard")
@MainActor
struct ApplySeamReGuardTests {

    @Test("Every origin refuses while the pipeline owns regions, with zero mutations")
    func allOriginsRefuseDuringPipelinePhase() async {
        let doc = pipelineOwnedDocumentState()

        // Search origin.
        let searchState = RedactionState()
        let search = SearchState()
        search.results = [makeSearchResult()]
        searchState.activeSearch = search
        let searchOutcome = await searchState.applyFindings(
            .selectedSearchResults, undoManager: nil, documentState: doc)
        #expect(searchOutcome == nil)
        #expect(searchState.regions.isEmpty)

        // Staged-review origin: the review must survive the refusal
        // untouched — a refused apply must not resolve it.
        let stagedState = RedactionState()
        let detection = makeDetection()
        stagedState.pendingTriage = [0: [detection]]
        stagedState.triageSelections = [detection.id: true]
        let stagedOutcome = await stagedState.applyFindings(
            .stagedDetections, undoManager: nil, documentState: doc)
        #expect(stagedOutcome == nil)
        #expect(stagedState.regions.isEmpty)
        #expect(stagedState.pendingTriage != nil,
                "a refused apply leaves the review pending")
        #expect(stagedState.triageSelections[detection.id] == true,
                "a refused apply preserves the user's selections")
        #expect(stagedState.priors.mean(.ssn) == 0.5,
                "a refused apply records no decisions")

        // Group origin.
        let groupState = RedactionState()
        let a = makeDetection(page: 1, kind: .pii(.name), matchedText: "John Doe")
        let b = makeDetection(page: 3, kind: .pii(.name), matchedText: "John Doe")
        groupState.pendingTriage = [1: [a], 3: [b]]
        let groups = CrossPageEntityGroup.clusters(from: groupState.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("expected the John Doe cluster")
            return
        }
        let groupOutcome = await groupState.applyFindings(
            .entityGroup(group), undoManager: nil, documentState: doc)
        #expect(groupOutcome == nil)
        #expect(groupState.regions.isEmpty)
        #expect(groupState.pendingTriage?.values.flatMap { $0 }.count == 2,
                "a refused group apply prunes nothing")

        // Detection-map origin.
        let mapState = RedactionState()
        let mapOutcome = await mapState.applyFindings(
            .detectionResults([0: [makeDetection()]]), undoManager: nil, documentState: doc)
        #expect(mapOutcome == nil)
        #expect(mapState.regions.isEmpty)
        #expect(mapState.pendingTriage == nil)
    }

    @Test("A permissive documentState admits the apply (the guard reads live phase)")
    func permissivePhaseAdmits() async {
        let doc = DocumentState()
        doc.phase = .editing
        #expect(doc.canMutateRegions)

        let state = RedactionState()
        let detection = makeDetection()
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: true]

        let outcome = await state.applyFindings(
            .stagedDetections, undoManager: nil, documentState: doc)
        #expect(outcome?.applied == 1)
    }
}

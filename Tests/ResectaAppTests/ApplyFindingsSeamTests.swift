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
// The contract families pinned here:
//   1. Search-origin preservation — the outputs the pre-seam search
//      apply produced, produced identically by the seam.
//   3. One undo implementation — undo removes regions + metadata +
//      audit in lockstep; redo re-inserts all three.
//   4. The mutation re-guard — every origin refuses to mutate while
//      the pipeline owns `regions`, re-checked inside the action.
//   5. The single-result origin — the compact handle's
//      per-item Apply: one result by id, the bulk origin's artifacts
//      and bookkeeping one at a time, refusals with zero mutations.

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

    @Test("A PII Scan apply returns the created count the Marked notice reports")
    func piiScanApplyFeedsMarkedNotice() async {
        let state = RedactionState()
        let search = SearchState()
        search.searchModeType = .piiScan
        search.results = (0..<3).map { i in
            makeSearchResult(y: 0.1 + 0.1 * Double(i), matchedText: "match-\(i)")
        }
        state.activeSearch = search

        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(outcome?.applied == 3)
        #expect(outcome?.skippedOverlaps == 0)
        #expect(CommitFeedback.markedMessage(
            applied: outcome?.applied ?? 0,
            alreadyCovered: outcome?.skippedOverlaps ?? 0)
            == "Marked 3 for redaction. Not redacted until you tap Redact.")
    }
}

// MARK: - 3. One undo implementation

@Suite("Apply seam — one undo implementation")
@MainActor
struct ApplySeamUndoTests {

    @Test("The applied-search stamp rides the lockstep undo: gone on undo, back on redo, byte-equal")
    func searchRecordRidesLockstepUndo() async {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let search = SearchState()
        search.searchModeType = .text
        search.queryText = "123-45-6789"
        search.results = [makeSearchResult(piiCategory: nil), makeSearchResult(y: 0.3, piiCategory: nil)]
        state.activeSearch = search
        let expected = search.appliedSearchRecord()
        #expect(expected != nil, "precondition: a typed query yields a record")

        undo.beginUndoGrouping()
        _ = await state.applyFindings(.selectedSearchResults, undoManager: undo)
        undo.endUndoGrouping()
        let stamped = state.appliedMatchAudit
        #expect(stamped.count == 2)
        #expect(stamped.values.allSatisfy { $0.searchRecord == expected })

        undo.undo()
        #expect(state.appliedMatchAudit.isEmpty, "undo drops the stamped snapshots with their regions")
        #expect(state.regions.values.flatMap { $0 }.isEmpty)

        undo.redo()
        #expect(state.appliedMatchAudit == stamped, "redo restores the identical snapshots, record included")
        #expect(state.regions.values.flatMap { $0 }.count == 2)
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
    }

    @Test("A permissive documentState admits the apply (the guard reads live phase)")
    func permissivePhaseAdmits() async {
        let doc = DocumentState()
        doc.phase = .editing
        #expect(doc.canMutateRegions)

        let state = RedactionState()
        let search = SearchState()
        search.results = [makeSearchResult()]
        state.activeSearch = search

        let outcome = await state.applyFindings(
            .selectedSearchResults, undoManager: nil, documentState: doc)
        #expect(outcome?.applied == 1)
    }
}

// MARK: - 5. Single-result origin

@Suite("Apply seam — single-result origin")
@MainActor
struct ApplySeamSingleResultOriginTests {

    @Test("Applies exactly the addressed result — the other checked row stays un-applied")
    func appliesOnlyTheAddressedResult() async {
        let state = RedactionState()
        let search = SearchState()
        let other = makeSearchResult(y: 0.1)
        let target = makeSearchResult(
            y: 0.6, matchedText: "987-65-4321",
            source: .ocr(confidence: 0.87),
            rationale: MatchRationale(
                ruleID: "ssn.pattern",
                signals: [.presetThresholdPass(raw: 0.91, cutoff: 0.7)],
                preThresholdScore: 0.91,
                finalScore: 0.91,
                appliedThreshold: 0.7
            )
        )
        search.results = [other, target]   // both checked
        state.activeSearch = search

        let outcome = await state.applyFindings(.searchResult(id: target.id), undoManager: nil)

        #expect(outcome?.applied == 1)
        #expect(outcome?.skippedOverlaps == 0)
        #expect(outcome?.appliedResultIDs == [target.id])
        #expect(outcome?.coveredResultIDs.isEmpty == true)
        let regions = state.regions.values.flatMap { $0 }
        #expect(regions.count == 1, "exactly ONE region — the checked sibling stays un-applied")
        guard let region = regions.first else {
            Issue.record("no region created")
            return
        }
        #expect(region.normalizedRect == target.normalizedRect)
        #expect(region.source == .searchMatch(term: target.term, rationale: target.rationale))
        let meta = state.regionMetadata[region.id]
        #expect(meta?.piiKind == .pii(.ssn))
        #expect(meta?.matchedText == target.matchedText)
        let audit = state.appliedMatchAudit[region.id]
        #expect(audit?.origin == .search)
        #expect(audit?.regionID == region.id)
        #expect(audit?.resultID == target.id)
        #expect(audit?.source == .ocr(confidence: 0.87))
        #expect(audit?.rationale?.ruleID == "ssn.pattern")
        #expect(state.regionMetadata.count == 1)
        #expect(state.appliedMatchAudit.count == 1)
    }

    @Test("The single and bulk origins build identical artifacts for the same result")
    func mirrorsTheBulkOriginPerResult() async {
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

        let bulkState = RedactionState()
        let bulkSearch = SearchState()
        bulkSearch.results = [result]
        bulkState.activeSearch = bulkSearch
        _ = await bulkState.applyFindings(.selectedSearchResults, undoManager: nil)

        let singleState = RedactionState()
        let singleSearch = SearchState()
        singleSearch.results = [result]
        singleState.activeSearch = singleSearch
        _ = await singleState.applyFindings(.searchResult(id: result.id), undoManager: nil)

        guard let bulkRegion = bulkState.regions[0]?.first,
              let singleRegion = singleState.regions[0]?.first else {
            Issue.record("both origins must create a region")
            return
        }
        #expect(singleRegion.normalizedRect == bulkRegion.normalizedRect)
        #expect(singleRegion.source == bulkRegion.source)
        let bulkMeta = bulkState.regionMetadata[bulkRegion.id]
        let singleMeta = singleState.regionMetadata[singleRegion.id]
        #expect(singleMeta?.piiKind == bulkMeta?.piiKind)
        #expect(singleMeta?.confidence == bulkMeta?.confidence)
        #expect(singleMeta?.matchedText == bulkMeta?.matchedText)
        #expect(singleMeta?.recognitionLevel == bulkMeta?.recognitionLevel)
        let bulkAudit = bulkState.appliedMatchAudit[bulkRegion.id]
        let singleAudit = singleState.appliedMatchAudit[singleRegion.id]
        #expect(singleAudit?.origin == bulkAudit?.origin)
        #expect(singleAudit?.resultID == bulkAudit?.resultID)
        #expect(singleAudit?.pageIndex == bulkAudit?.pageIndex)
        #expect(singleAudit?.matchedText == bulkAudit?.matchedText)
        #expect(singleAudit?.source == bulkAudit?.source)
        #expect(singleAudit?.piiCategory == bulkAudit?.piiCategory)
        #expect(singleAudit?.piiConfidence == bulkAudit?.piiConfidence)
        #expect(singleAudit?.rationale?.ruleID == bulkAudit?.rationale?.ruleID)
        #expect(singleAudit?.term == bulkAudit?.term)
    }

    @Test("The checkbox neither gates nor is required — an unchecked current result applies")
    func checkboxDoesNotGate() async {
        let state = RedactionState()
        let search = SearchState()
        let unchecked = makeSearchResult(isSelected: false)
        search.results = [unchecked]
        state.activeSearch = search

        let outcome = await state.applyFindings(.searchResult(id: unchecked.id), undoManager: nil)

        #expect(outcome?.applied == 1)
        #expect(outcome?.appliedResultIDs == [unchecked.id])
        #expect(state.regions[0]?.count == 1)
        #expect(search.results.first?.isSelected == false,
                "the tap is the accept — the checkbox is not touched")
    }

    @Test("A covered result is inert: reported as covered, nothing created, no version bump")
    func coveredResultIsInert() async {
        let state = RedactionState()
        let prior = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.04),
            source: .manual
        )
        state.regions[0] = [prior]
        let search = SearchState()
        let covered = makeSearchResult(y: 0.1)
        search.results = [covered]
        state.activeSearch = search
        let versionBefore = state.regionVersion

        let outcome = await state.applyFindings(.searchResult(id: covered.id), undoManager: nil)

        #expect(outcome?.applied == 0)
        #expect(outcome?.skippedOverlaps == 1)
        #expect(outcome?.appliedResultIDs.isEmpty == true, "no badge for a covered result")
        #expect(outcome?.coveredResultIDs == [covered.id], "the graying set learns it")
        #expect(state.regions[0]?.count == 1, "no duplicate region over the prior")
        #expect(state.appliedMatchAudit.isEmpty)
        #expect(state.regionVersion == versionBefore,
                "an inert apply must not signal a region mutation")
    }

    @Test("Undo removes the region, metadata, audit and marker in one step; redo restores all three")
    func undoRedoLockstep() async {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let search = SearchState()
        let result = makeSearchResult()
        search.results = [result]
        state.activeSearch = search

        undo.beginUndoGrouping()
        _ = await state.applyFindings(.searchResult(id: result.id), undoManager: undo)
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Mark 1 Instance",
                "the singular form of the search origins' one action-name construction")

        guard let regionID = state.regions[0]?.first?.id else {
            Issue.record("no region created")
            return
        }
        #expect(state.regionMetadata[regionID] != nil)
        #expect(state.appliedMatchAudit[regionID] != nil)
        let versionAfterApply = state.regionVersion

        undo.undo()
        #expect(state.regions[0]?.isEmpty ?? true)
        #expect(state.regionMetadata[regionID] == nil)
        #expect(state.appliedMatchAudit[regionID] == nil)
        #expect(state.regionVersion > versionAfterApply)

        let versionAfterUndo = state.regionVersion
        undo.redo()
        #expect(state.regions[0]?.count == 1)
        #expect(state.regionMetadata[regionID] != nil)
        #expect(state.appliedMatchAudit[regionID] != nil)
        #expect(state.regionVersion > versionAfterUndo)
    }

    @Test("The bulk origin reads the same construction: plural above one, singular at one")
    func bulkActionNameGrammar() async {
        let plural = RedactionState()
        let pluralUndo = UndoManager()
        pluralUndo.groupsByEvent = false
        let pluralSearch = SearchState()
        pluralSearch.results = [makeSearchResult(y: 0.1), makeSearchResult(y: 0.6)]
        plural.activeSearch = pluralSearch
        pluralUndo.beginUndoGrouping()
        _ = await plural.applyFindings(.selectedSearchResults, undoManager: pluralUndo)
        pluralUndo.endUndoGrouping()
        #expect(pluralUndo.undoActionName == "Mark 2 Instances", "the toast's verb, no document text")

        let singular = RedactionState()
        let singularUndo = UndoManager()
        singularUndo.groupsByEvent = false
        let singularSearch = SearchState()
        singularSearch.results = [makeSearchResult()]
        singular.activeSearch = singularSearch
        singularUndo.beginUndoGrouping()
        _ = await singular.applyFindings(.selectedSearchResults, undoManager: singularUndo)
        singularUndo.endUndoGrouping()
        #expect(singularUndo.undoActionName == "Mark 1 Instance")
    }

    @Test("Refuses while the pipeline owns regions, with zero mutations")
    func refusesDuringPipelinePhase() async {
        let doc = pipelineOwnedDocumentState()
        let state = RedactionState()
        let search = SearchState()
        let result = makeSearchResult()
        search.results = [result]
        state.activeSearch = search
        let versionBefore = state.regionVersion

        let outcome = await state.applyFindings(
            .searchResult(id: result.id), undoManager: nil, documentState: doc)

        #expect(outcome == nil)
        #expect(state.regions.isEmpty)
        #expect(state.appliedMatchAudit.isEmpty)
        #expect(state.regionVersion == versionBefore)
    }

    @Test("A stale id — a result no longer on board — refuses with zero mutations")
    func staleIDRefuses() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [makeSearchResult()]
        search.userModifiedSelections = true
        state.activeSearch = search
        let versionBefore = state.regionVersion

        let outcome = await state.applyFindings(.searchResult(id: UUID()), undoManager: nil)

        #expect(outcome == nil)
        #expect(state.regions.isEmpty)
        #expect(state.regionMetadata.isEmpty)
        #expect(state.appliedMatchAudit.isEmpty)
        #expect(state.regionVersion == versionBefore)
        #expect(search.userModifiedSelections == true, "a refusal touches no session state")
    }

    @Test("No active search refuses")
    func noActiveSearchRefuses() async {
        let state = RedactionState()
        let outcome = await state.applyFindings(.searchResult(id: UUID()), undoManager: nil)
        #expect(outcome == nil)
        #expect(state.regions.isEmpty)
    }

    @Test("A partial commit keeps the conditional-dismiss tracker set (the entity-group rule)")
    func partialCommitKeepsTracker() async {
        let state = RedactionState()
        let search = SearchState()
        let first = makeSearchResult(y: 0.1)
        let second = makeSearchResult(y: 0.6, matchedText: "987-65-4321")
        search.results = [first, second]
        search.userModifiedSelections = true
        state.activeSearch = search

        let outcome = await state.applyFindings(.searchResult(id: first.id), undoManager: nil)

        #expect(outcome?.applied == 1)
        #expect(search.userModifiedSelections == true,
                "the other selections are still live work — the tracker stays set")
    }
}

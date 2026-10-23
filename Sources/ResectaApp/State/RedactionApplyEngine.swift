import Foundation
import RedactionEngine

// Apply's one home: the one apply seam (`applyFindings` and the two types
// it speaks in), the gate that runs applies one at a time, and the
// detached prepare step the search origin runs off the MainActor. Moved
// out of `RedactionState.swift` along its `// MARK: - The one apply seam`,
// `// MARK: - Apply serialization` and `// MARK: - Apply prepare helper`
// seams. The search origins, the shared commit and the manual-draw nudge
// stay in `RedactionState.swift`: they write state only that file may
// write. The gate's two stored flags stay there too (an extension adds
// no storage) and are read from here.

extension RedactionState {

    // MARK: - The one apply seam

    /// Which staged work an `applyFindings` call promotes to regions.
    enum ApplyOrigin {
        /// The selected rows of `activeSearch.results` — the search
        /// side and the Scan interface's in-sheet run results.
        case selectedSearchResults
        /// One result of `activeSearch.results`, addressed by id — the
        /// compact handle's per-item Apply. Selection state is not
        /// consulted: the tap IS the accept for that one result.
        /// Resolved against the live results at call time, so a result
        /// the search has since re-flushed refuses with zero mutations
        /// instead of applying by index.
        case searchResult(id: UUID)
    }

    /// What one `applyFindings` call did. Counts feed the shared
    /// commit-toast copy (`CommitFeedback`), which reports regions
    /// actually created — never the raw detection or selection total.
    struct ApplyOutcome: Equatable {
        /// Regions actually created (overlap skips excluded).
        let applied: Int
        /// Search origin only: selected results skipped for >80%
        /// overlap with an existing region. Skipped results earn no
        /// applied badge and no audit entry.
        let skippedOverlaps: Int
        /// Search origin only: the `SearchResult.id`s that produced a
        /// region this pass.
        let appliedResultIDs: Set<UUID>
        /// Search origin only: the `SearchResult.id`s
        /// dedup-skipped as already covered. No badge, no audit entry
        /// — consumed only by the Apply-graying gate.
        var coveredResultIDs: Set<UUID> = []

        static let zero = ApplyOutcome(
            applied: 0, skippedOverlaps: 0,
            appliedResultIDs: [])
    }

    /// The one apply path for BOTH result origins. Every origin creates
    /// its regions AND writes the audit records — `RegionMetadata` plus
    /// `MatchAuditSnapshot` with `regionID` populated — through the one
    /// commit transaction, with one undo implementation
    /// (`commitApply`). Returns nil when the call is refused (no active
    /// search for the search origins, a single-result apply whose
    /// result is no longer on board, or the pipeline owns `regions`);
    /// otherwise an outcome whose counts feed the shared commit toast.
    ///
    /// Serialization: applies run one at a time, in call order (see
    /// `waitForApplyTurn()` below). A call that arrives while another
    /// apply is in flight waits for that apply to commit — or to be
    /// refused — before it reads any state, so the search origin's
    /// overlap test always runs against the regions every earlier apply
    /// created. Two overlapping applies of the same selection therefore
    /// create each region once: the later one skips every match as
    /// already covered.
    ///
    /// Mutation guard: when `documentState` is passed, the call refuses
    /// to mutate `regions` / `regionMetadata` while the pipeline owns
    /// them (`!canMutateRegions`) — re-checked HERE, inside the action
    /// and after the wait for the apply turn, so a caller racing a
    /// pipeline start cannot slip a mutation in behind a button-level
    /// `.disabled` gate. The search origin checks again after its
    /// detached prepare step resumes, closing the window a pipeline
    /// start opens during that suspension. The parameter stays optional
    /// for source compatibility and test seams; the sheet entry points
    /// pass it.
    @discardableResult
    func applyFindings(
        _ origin: ApplyOrigin,
        undoManager: UndoManager?,
        documentState: DocumentState? = nil
    ) async -> ApplyOutcome? {
        await waitForApplyTurn()
        defer { endApplyTurn() }
        if let documentState, !documentState.canMutateRegions {
            return nil
        }
        // The conditional-dismiss tracker reset is owned by this path:
        // the search origin resets it on every non-refused outcome (it
        // resolves the session's whole selection context); a
        // single-result apply from the compact handle leaves it set.
        // Each branch resets the session it actually applied against.
        switch origin {
        case .selectedSearchResults:
            return await applySelectedSearchResultsOrigin(
                undoManager: undoManager, documentState: documentState)
        case .searchResult(let id):
            return applySearchResultOrigin(id: id, undoManager: undoManager)
        }
    }
    // MARK: - Apply serialization

    // The apply contract is snapshot → prepare → commit. The search
    // origin snapshots the existing region rects on the MainActor,
    // prepares its regions off the actor (`prepareApply`, a real
    // suspension), then commits on the MainActor by appending the
    // prepared set. The commit does not re-run the overlap test against
    // the live `regions`, so two applies whose snapshot→commit windows
    // overlapped would each commit the full prepared set — every match
    // twice. The gate below closes that window: an apply owns the path
    // from its first state read to the end of its commit, and every
    // later caller waits its turn in arrival order. The other origins
    // never suspend between their reads and their commit, so for them
    // the gate only orders them behind an in-flight search-origin apply.
    //
    // An uncontended call takes the gate without suspending, which keeps
    // the synchronous origins' timing unchanged. The sheet's `isApplying`
    // flag still stops a second tap at the UI; this gate is the path's
    // own contract, independent of any caller.

    /// Take the apply path: at once when it is free, otherwise after
    /// every earlier caller's apply has finished.
    func waitForApplyTurn() async {
        if !applyInProgress {
            applyInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            applyWaiters.append(continuation)
        }
        // Resumed by `endApplyTurn()`: the path is ours, and
        // `applyInProgress` stayed true through the hand-off.
    }

    /// Release the apply path, handing it to the next waiter if any.
    func endApplyTurn() {
        if applyWaiters.isEmpty {
            applyInProgress = false
        } else {
            applyWaiters.removeFirst().resume()
        }
    }
}

// MARK: - Apply prepare helper

/// The one coverage rule the apply's skip and the draw nudge share: a
/// result is covered when a single rect overlaps more than 80 % of its area.
nonisolated func resultIsCovered(_ resultRect: CGRect, by rects: [CGRect]) -> Bool {
    let resultArea = resultRect.width * resultRect.height
    return resultArea > 0 && rects.contains { rect in
        let overlap = resultRect.intersection(rect)
        return !overlap.isNull && overlap.width * overlap.height / resultArea > 0.8
    }
}

/// Sendable bundle returned by the detached `prepareApply` step.
struct PreparedApply: Sendable {
    let createdRegions: [Int: [RedactionRegion]]
    let createdMetadata: [UUID: RegionMetadata]
    let createdAudit: [UUID: MatchAuditSnapshot]
    let appliedCount: Int
    let skippedOverlaps: Int
    /// The `SearchResult.id`s that actually produced a
    /// region this pass. Overlap-skipped results are absent, so the
    /// sheet's `appliedResultIDs` union (the green "applied" badge state)
    /// matches the audit-backed set instead of the full selection.
    let appliedResultIDs: Set<UUID>
    /// The `SearchResult.id`s dedup-SKIPPED for >80% overlap
    /// with an existing region. These are kept out of
    /// `appliedResultIDs` (no badge, no audit entry); the sheet unions
    /// them into `SearchState.coveredResultIDs` so `selectionFullyApplied`
    /// can gray Apply on a fully covered selection.
    let coveredResultIDs: Set<UUID>
}

/// Pure-function detached prepare step for the search origin of
/// `RedactionState.applyFindings`.
/// Runs the overlap rejection against a snapshot of existing region
/// rects per page and constructs the per-result region / metadata /
/// audit-snapshot trio. No actor state is read; the result is re-merged
/// on MainActor by the caller. File-level (not a static method) so the
/// detached task body captures no implicit `Self`, which keeps the
/// Swift 6 region-based isolation checker happy.
///
/// `nonisolated`: under the SE-0466 MainActor-default flip an unannotated
/// global function would become MainActor-isolated, but this is INTENTIONALLY
/// dispatched off MainActor via `Task.detached` (the search-origin apply) so a
/// large apply does not freeze the actor — so it must stay nonisolated. No
/// actor state is read; all inputs are Sendable snapshots passed by value.
///
/// `searchRecord` is the session's applied-search record
/// (`SearchState.appliedSearchRecord()`, read on MainActor by the caller),
/// stamped on every audit snapshot this pass creates so the Search
/// Re-check can re-run the query on the output; nil for a `.piiScan`
/// session. It rides the snapshot through `commitApply`'s two-leg undo
/// untouched — the snapshot is the undo unit.
nonisolated func prepareApply(
    selected: [SearchResult],
    existingRectsByPage: [Int: [CGRect]],
    appliedAt: Date,
    searchRecord: AppliedSearchRecord?
) -> PreparedApply {
    var createdRegions: [Int: [RedactionRegion]] = [:]
    var createdMetadata: [UUID: RegionMetadata] = [:]
    // Snapshot the rationale + category + matchedText at apply
    // time, before the live SearchResult is lost. Keyed by region.id.
    var createdAudit: [UUID: MatchAuditSnapshot] = [:]
    var skippedOverlaps = 0
    var appliedResultIDs: Set<UUID> = []
    var coveredResultIDs: Set<UUID> = []

    for result in selected {
        // Skip results an existing region already covers.
        if resultIsCovered(result.normalizedRect, by: existingRectsByPage[result.pageIndex] ?? []) {
            skippedOverlaps += 1
            coveredResultIDs.insert(result.id)
            continue
        }

        // Thread the SearchResult rationale into
        // the region's Source so downstream surfaces (RegionInfoPopover
        // disclosure, canvas long-press action sheet, audit export) can
        // read it without re-querying MatchAuditSnapshot.
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: result.normalizedRect,
            source: .searchMatch(term: result.term, rationale: result.rationale)
        )
        createdRegions[result.pageIndex, default: []].append(region)
        appliedResultIDs.insert(result.id)

        let confidence: Double = switch result.source {
        case .textLayer: 1.0
        case .ocr(let conf): Double(conf)
        }
        // A PII-scan result carries its detected category —
        // stamp the region with it, so downstream surfaces (info popover,
        // long-press row, verifier term collection) see the category the
        // detector reported. Typed text/regex results have no category and
        // keep the search-match kind, where `term` is the user's query.
        let piiKind: DetectionResult.Kind = result.piiCategory
            .map { .pii($0.piiKind) } ?? .searchMatch(term: result.term)
        createdMetadata[region.id] = RegionMetadata(
            piiKind: piiKind,
            confidence: confidence,
            matchedText: result.matchedText,
            recognitionLevel: result.source == .textLayer ? .fast : .accurate
        )
        createdAudit[region.id] = MatchAuditSnapshot(
            origin: .search,
            resultID: result.id,
            regionID: region.id,
            pageIndex: result.pageIndex,
            matchedText: result.matchedText,
            source: result.source,
            piiCategory: result.piiCategory,
            piiConfidence: result.piiConfidence,
            rationale: result.rationale,
            term: result.term,
            appliedAt: appliedAt,
            searchRecord: searchRecord
        )
    }

    let appliedCount = createdRegions.values.reduce(0) { $0 + $1.count }
    return PreparedApply(
        createdRegions: createdRegions,
        createdMetadata: createdMetadata,
        createdAudit: createdAudit,
        appliedCount: appliedCount,
        skippedOverlaps: skippedOverlaps,
        appliedResultIDs: appliedResultIDs,
        coveredResultIDs: coveredResultIDs
    )
}

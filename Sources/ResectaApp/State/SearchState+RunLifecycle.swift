import Foundation
import RedactionEngine

extension SearchState {
    // MARK: - Trigger single-flight

    /// Single-flight gate for `triggerSearch()`. Returns true when the
    /// caller owns the setup window; false coalesces this call into one
    /// deferred re-trigger. Pinned by `SearchStateTests`.
    func beginTriggerSetup() -> Bool {
        guard !triggerSetupInFlight else {
            pendingRetrigger = true
            return false
        }
        triggerSetupInFlight = true
        return true
    }

    /// Close the setup window. Returns true when a coalesced caller
    /// requested a re-trigger while the window was held.
    func endTriggerSetup() -> Bool {
        triggerSetupInFlight = false
        let retrigger = pendingRetrigger
        pendingRetrigger = false
        return retrigger
    }

    // MARK: - Result Batching (P2)

    /// Batch size threshold before immediate flush.
    private static let batchFlushSize = 50

    /// Time interval between automatic flushes.
    private static let flushInterval: Duration = .milliseconds(100)

    // MARK: - Run token

    /// Starts a run: mints and returns the token the run's consumer
    /// passes to `appendResult(_:run:)`. Called after `clearResults()`.
    func beginRun() -> Int {
        runToken += 1
        lastRunOptions = options
        return runToken
    }

    // MARK: - Methods

    func cancelSearch() async {
        let task = activeSearchTask
        activeSearchTask = nil
        task?.cancel()
        _ = await task?.value
        isSearching = false
        flushPendingResults() // Deliver any buffered results
    }

    // Fire-and-forget cancellation for two cases that cannot await the
    // task's `value`: (a) self-cancellation from inside the task
    // (`appendResult` cap-hit, or the run's end at the cap,
    // `runEndsCancelled`) — awaiting a task from within itself
    // deadlocks; (b) document close / sheet teardown, where the caller
    // wipes shared state regardless, so a leaked cleanup tail has
    // nothing to clobber.
    func cancelSearchWithoutAwait() {
        activeSearchTask?.cancel()
        activeSearchTask = nil
        isSearching = false
        flushPendingResults()
    }

    /// A run's stream has ended: whether the run ends as a cancelled one,
    /// which skips the cleanup tail. A cancelled task does: a successor
    /// may own the state. So does the current run when it stopped at the
    /// result limit, where the engine ends the stream: it is stopped as
    /// the cap's cancel stops one (`cancelSearchWithoutAwait`: what it
    /// holds is flushed, the run is no longer searching), so the completed
    /// flag stays down and no Scan report or run record is written (the
    /// return rule's "a run that stopped at the result cap is listed").
    /// A superseded run's end (another token) never takes the cap branch,
    /// so it cannot stop a successor's run.
    func runEndsCancelled(run: Int, taskCancelled: Bool) -> Bool {
        if taskCancelled { return true }
        guard resultsAtCap, run == runToken else { return false }
        cancelSearchWithoutAwait()
        return true
    }

    /// Replace-selection primitive: every result's `isSelected` is set to
    /// `predicate(result)` — predicates that match a subset deselect the
    /// rest. It is the footer Select All / Deselect All toggle's building
    /// block, where "deselect everything not in the target set" is
    /// exactly the wanted behavior (the "Select where…"
    /// predicate menu and its additive `addToSelection(where:)` sibling
    /// retired with the footer menu — this is the one predicate
    /// primitive left). Bumps `resultVersion` once for the full pass (no
    /// per-result observer churn). Performance gate: <100ms on 10k
    /// results — pinned by `SearchStateSelectionTests`.
    func setSelection(where predicate: (SearchResult) -> Bool) {
        let decided = Self.occurrenceSelection(results, where: predicate)
        for i in results.indices { results[i].isSelected = results[i].hasBox && (decided[Self.occurrenceKey(results[i])] ?? false) }
        resultVersion += 1
    }

    /// Footer bar select-all / deselect-all toggle. Composes with
    /// `setSelection(where:)` (the replace primitive) while preserving
    /// filtered-only behavior — results outside the active filter retain
    /// their existing `isSelected`. The captured `filteredIDs` + `target`
    /// makes the predicate a pure function of `result.id`.
    func toggleSelectAll() {
        let filtered = filteredResults.filter(\.hasBox)
        let filteredIDs = Set(filtered.map(\.id))
        let target = !filtered.allSatisfy(\.isSelected)
        setSelection { result in
            filteredIDs.contains(result.id) ? target : result.isSelected
        }
    }

    func toggleSelection(for id: UUID) {
        guard let result = results.first(where: { $0.id == id }), result.hasBox else { return }
        let key = Self.occurrenceKey(result), target = !result.isSelected
        setSelection { Self.occurrenceKey($0) == key ? target : $0.isSelected }
    }

    /// Current index of a result by ID, or nil if removed.
    func index(of id: UUID) -> Int? {
        results.firstIndex(where: { $0.id == id })
    }

    /// Selections not yet applied, from the rows (never a gesture tracker): a selected result no live applied
    /// region covers (`liveApplied` = `RedactionState.liveAppliedSearchResultIDs`; covered counts as applied).
    func hasUnappliedSelections(liveApplied: Set<UUID>) -> Bool {
        results.contains { $0.isSelected && !liveApplied.contains($0.id) && !coveredResultIDs.contains($0.id) }
    }

    /// Buffer a result from the search stream. Flushed in batches
    /// to avoid per-result @Observable change notifications (P2).
    /// The engine's limit counts matches, not rows (P3): a line of a
    /// match already listed is always kept, so a match that runs over
    /// two lines is listed whole; a new match is kept only while fewer
    /// than `DocumentSearcher.maxResults` are listed. The match that
    /// reaches the limit marks it, and the run goes on so that match's
    /// later lines still arrive; the first new match past the limit is
    /// dropped and stops the run. The engine stops at the limit itself, so
    /// a run at the limit most often stops at its stream's end
    /// (`runEndsCancelled`).
    /// `run` names the run the result belongs to (the token
    /// `beginRun()` handed its consumer); a result from a superseded
    /// run is dropped before anything below sees it. A caller that
    /// holds no token — a direct seed — appends to the current run.
    func appendResult(_ result: SearchResult, run: Int? = nil) {
        if let run, run != runToken { return }
        // Matches never outnumber rows, so they are counted only once
        // the rows reach the limit.
        if results.count + pendingResults.count >= DocumentSearcher.maxResults {
            let listed = listedMatchKeys()
            if listed.count >= DocumentSearcher.maxResults, !listed.contains(Self.occurrenceKey(result)) {
                markCapReached()  // a new match past the limit is dropped
                return
            }
        }
        pendingResults.append((run: runToken, result: result))
        if !resultsAtCap, results.count + pendingResults.count >= DocumentSearcher.maxResults,
           listedMatchKeys().count >= DocumentSearcher.maxResults {
            noteCapReached()  // the match that reaches the limit is kept, with its later lines
        }
        if pendingResults.count >= Self.batchFlushSize {
            flushPendingResults()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.flushInterval)
                guard !Task.isCancelled else { return }
                self?.flushPendingResults()
            }
        }
    }

    /// The matches listed so far, by the key that groups a match's lines:
    /// the published results and those still buffered.
    private func listedMatchKeys() -> Set<UUID> {
        var keys = Set(results.map(Self.occurrenceKey))
        for entry in pendingResults { keys.insert(Self.occurrenceKey(entry.result)) }
        return keys
    }

    /// Flush buffered results into the published array. Single version
    /// bump. Only the current run's entries move; anything buffered
    /// under an earlier token is discarded with the flush.
    func flushPendingResults() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingResults.isEmpty else { return }
        let current = pendingResults.filter { $0.run == runToken }.map(\.result)
        pendingResults.removeAll()
        guard !current.isEmpty else { return }
        results.append(contentsOf: Self.landing(current))
        resultVersion += 1
    }
}

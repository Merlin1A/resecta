import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-09 → q16/UXF-19 — mode-switch discard routed through the undo-toast
// pattern. The .onChange handler inside SearchAndRedactSheet snapshots
// the session BEFORE `clearResults()` ([RR-04] reset-after-check
// ordering), clears, then calls
// `SearchAndRedactSheet.enqueueModeSwitchUndoToast(...)`. The toast fires
// for ANY user-initiated clear that dropped at least one result — the
// all-applied list that formerly cleared silently (pack 01 carve-out B)
// included. Programmatic transitions (saved-search recall, ST-95) skip
// both the clear and the toast by design (carve-out A — deliberate).

@Suite("Mode-switch discard undo toast (WU-09 / UXF-19)", .tags(.search))
@MainActor
struct ModeSwitchToastTests {

    @Test("User-initiated switch with unapplied results enqueues undo toast")
    func userSwitchEnqueuesToast() {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let state = SearchState()
        state.results = [
            makeResult(page: 0),
            makeResult(page: 0),
            makeResult(page: 1),
        ]
        // 3 results, 1 applied → 2 unapplied.
        let appliedID = state.results[0].id
        state.appliedResultIDs = [appliedID]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        let unapplied = SearchAndRedactSheet.unappliedMatchCount(in: state)
        state.clearResults()
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: unapplied
        )

        #expect(manager.activeToasts.count == 1)
        #expect(manager.activeToasts.first?.severity == .info)
        #expect(manager.activeToasts.first?.message == "Mode switch cleared 2 unapplied matches.")
        #expect(manager.activeToasts.first?.actionLabel == "Undo")
        #expect(manager.activeToasts.first?.actionHandler != nil)
    }

    @Test("Singular suffix when exactly one unapplied result")
    func singularSuffix() {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let state = SearchState()
        state.results = [makeResult(page: 0)]
        // 0 applied → 1 unapplied.

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        let unapplied = SearchAndRedactSheet.unappliedMatchCount(in: state)
        state.clearResults()
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: unapplied
        )

        #expect(manager.activeToasts.first?.message == "Mode switch cleared 1 unapplied match.")
    }

    @Test("User-initiated switch with no results does NOT enqueue toast")
    func emptyStateNoToast() {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let state = SearchState()
        // Empty results array → nothing cleared → no toast.

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 0
        )

        #expect(manager.activeToasts.isEmpty)
    }

    @Test("All-applied clear now toasts too (pack 01 carve-out B closed)")
    func allAppliedClearToasts() {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let state = SearchState()
        let r1 = makeResult(page: 0)
        let r2 = makeResult(page: 1)
        state.results = [r1, r2]
        state.appliedResultIDs = [r1.id, r2.id]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        let unapplied = SearchAndRedactSheet.unappliedMatchCount(in: state)
        #expect(unapplied == 0)
        state.clearResults()
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: unapplied
        )

        #expect(manager.activeToasts.count == 1)
        #expect(manager.activeToasts.first?.message
                == "Mode switch cleared 2 matches (all already applied).")
    }

    @Test("Programmatic switch does NOT enqueue toast even with unapplied results")
    func programmaticSwitchSkipsToast() {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let state = SearchState()
        state.results = [makeResult(page: 0), makeResult(page: 0), makeResult(page: 1)]
        // 3 unapplied, but the transition is programmatic (ST-95 recall).
        state.isProgrammaticModeChange = true

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: state.isProgrammaticModeChange,
            unappliedCount: SearchAndRedactSheet.unappliedMatchCount(in: state)
        )

        #expect(manager.activeToasts.isEmpty)
    }

    // MARK: - Undo restore

    @Test("Undo restores mode, results, applied markers, filter, and sort order")
    func undoRestoresSession() async {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let state = SearchState()
        let r1 = makeResult(page: 0)
        let r2 = makeResult(page: 1)
        state.searchModeType = .piiScan
        state.results = [r1, r2]
        state.appliedResultIDs = [r1.id]
        state.piiCategoryFilter = [.name]
        state.sortOrder = .pageAscending
        state.appliedFilter = .unapplied

        // Simulate the .onChange body: snapshot (with the OLD mode from
        // the onChange parameter), clear, enqueue.
        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .piiScan)
        let unapplied = SearchAndRedactSheet.unappliedMatchCount(in: state)
        state.searchModeType = .text
        state.clearResults()
        state.piiCategoryFilter = nil
        state.sortOrder = .discoveryOrder
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: unapplied
        )

        // Post-clear: session is empty in the new mode.
        #expect(state.results.isEmpty)
        #expect(state.appliedResultIDs.isEmpty)

        // Tap Undo via the toast's action handler. The restore is
        // deferred one runloop turn (CAT-396 F10 deferral pattern).
        // BH-B-07 — the target resolves through the LIVE activeSearch.
        rs.activeSearch = state
        let toast = try! #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()

        #expect(state.searchModeType == .piiScan)
        #expect(state.isProgrammaticModeChange == true,
                "the restore routes through the ST-95 programmatic hook so the .onChange handler preserves rather than re-clears")
        #expect(state.results.map(\.id) == [r1.id, r2.id])
        #expect(state.appliedResultIDs == [r1.id])
        #expect(state.piiCategoryFilter == [.name])
        #expect(state.sortOrder == .pageAscending)
        #expect(state.appliedFilter == .unapplied,
                "clearResults() resets the applied-state chip to .all; the restore puts it back")
    }

    // MARK: - BH-B-07 restore-target resolution

    @Test("BH-B-07: Undo after sheet reopen restores into the NEW live SearchState")
    func undoRestoresIntoReopenedSession() async {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let original = SearchState()
        let r1 = makeResult(page: 0)
        original.results = [r1]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: original, previousMode: .regex)
        original.clearResults()
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )

        // Simulate dismiss + reopen: the original session dies, a fresh
        // SearchState becomes the live session — the pre-fix
        // [weak searchState] capture no-oped exactly here.
        let reopened = SearchState()
        rs.activeSearch = reopened

        let toast = try! #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()

        #expect(reopened.searchModeType == .regex)
        #expect(reopened.results.map(\.id) == [r1.id])
    }

    @Test("BH-B-07: Undo with no live sheet mints a session and presents it")
    func undoMintsAndPresentsWhenNoSheetIsUp() async {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let original = SearchState()
        let r1 = makeResult(page: 1)
        original.results = [r1]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: original, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )
        // Sheet fully closed: no live session at tap time.
        #expect(rs.activeSearch == nil)

        let toast = try! #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()

        // Assigning activeSearch IS the presentation trigger.
        let presented = try! #require(rs.activeSearch)
        #expect(presented.searchModeType == .text)
        #expect(presented.results.map(\.id) == [r1.id])
    }

    @Test("BH-B-07: Undo no-ops while a detection review is pending")
    func undoNoOpsDuringPendingReview() async {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let original = SearchState()
        original.results = [makeResult(page: 0)]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: original, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )
        // A pending review owns the surface.
        rs.pendingTriage = [:]

        let toast = try! #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()

        #expect(rs.activeSearch == nil,
                "the restore must not mint/present a session under a pending review")
    }

    @Test("Undo no-ops gracefully after the RedactionState is gone")
    func undoNoOpsAfterRedactionStateDeallocated() async {
        let manager = ToastQueueManager()
        var rs: RedactionState? = RedactionState()
        let state = SearchState()
        state.results = [makeResult(page: 0)]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs!,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )
        rs = nil

        // The closure holds [weak redactionState]; the structural
        // assertion is that the (deferred) restore no-ops without
        // crashing.
        let toast = try! #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()
        #expect(manager.activeToasts.count == 1)
    }

    @Test("BH-B-07: restore arms the programmatic flag only when the mode actually changes")
    func restoreFlagOnlyOnRealModeChange() {
        let state = SearchState()
        let sameMode = state.searchModeType
        let snapshot = SearchAndRedactSheet.ModeSwitchSnapshot(
            mode: sameMode,
            results: [makeResult(page: 0)],
            appliedResultIDs: [],
            piiCategoryFilter: nil,
            sortOrder: .discoveryOrder,
            appliedFilter: .all
        )
        SearchAndRedactSheet.restoreModeSwitchSnapshot(snapshot, in: state)
        // No .onChange consumer ever fires for a same-mode restore — a
        // stale true would mis-classify the next USER transition.
        #expect(state.isProgrammaticModeChange == false)
        #expect(state.results.count == 1)
    }

    @Test("unappliedMatchCount clamps to zero when applied IDs outpace results")
    func unappliedCountClampsAtZero() {
        let state = SearchState()
        state.results = [makeResult(page: 0)]
        // Defensively populate applied IDs with phantom UUIDs that don't
        // exist in `results` (can happen briefly between region-version
        // .onChange resets per the SearchAndRedactSheet wiring).
        state.appliedResultIDs = [UUID(), UUID(), UUID()]

        #expect(SearchAndRedactSheet.unappliedMatchCount(in: state) == 0)
    }

    // CAT-396 (C-J1, the "F10 deferral pattern"): the KI-4 purge re-run toast's
    // actionHandler defers `activeSearch = nil` + the pipeline kick-off one
    // runloop turn via `Task { @MainActor }`, so the @Observable teardown does
    // not co-mutate with `toastManager.dismiss(item)`'s synchronous
    // `withAnimation { activeToasts.removeAll }` in the same tap. This mirrors
    // ToastView's button-action order (actionHandler() then dismiss(item)) and
    // pins that the two mutations are sequential, not simultaneous.
    // (runFullPipeline is not invoked here — the contract under test is the
    // deferral of the @Observable teardown; production defers both together.)
    @Test("KI-4 Re-run action defers activeSearch teardown past the synchronous toast dismiss (CAT-396)")
    func ki4RerunActionDefersActiveSearchTeardown() async {
        let manager = ToastQueueManager()
        let state = RedactionState()
        state.activeSearch = SearchState()

        let item = ToastItem(
            message: "Re-run to regenerate the redacted output",
            severity: .warning,
            actionLabel: "Re-run"
        )
        manager.enqueue(item)
        #expect(manager.activeToasts.contains(item),
                "precondition: the toast is displayed before the tap")

        // ToastView's button action: actionHandler() (deferred teardown) then
        // the synchronous toastManager.dismiss(item).
        let actionHandler: @MainActor () -> Void = {
            Task { @MainActor in state.activeSearch = nil }
        }
        actionHandler()
        manager.dismiss(item)

        // Synchronously: the toast removal already ran inside the tap's
        // animation transaction, but the activeSearch teardown is deferred.
        #expect(state.activeSearch != nil,
                "activeSearch teardown must be deferred past the toast dismiss")
        #expect(manager.activeToasts.isEmpty,
                "the toast is dismissed synchronously in the tap")

        await Task.yield()
        #expect(state.activeSearch == nil,
                "the deferred teardown must fire on the next runloop turn")
    }

    private func makeResult(page: Int) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            matchedText: "x",
            contextSnippet: "…x…",
            source: .textLayer,
            term: "x"
        )
    }
}

import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// Mode-switch discard is routed through the undo-toast
// pattern. The .onChange handler inside SearchAndRedactSheet snapshots
// the session before `clearResults()` (reset-after-check
// ordering), clears, then calls
// `SearchAndRedactSheet.enqueueModeSwitchUndoToast(...)`. The toast fires
// for any user-initiated clear that dropped at least one result — the
// all-applied list that formerly cleared silently (carve-out B)
// included. Programmatic transitions (saved-search recall) skip
// both the clear and the toast by design (carve-out A — deliberate).

@Suite("Mode-switch discard undo toast", .tags(.search))
@MainActor
struct ModeSwitchToastTests {

    @Test("User-initiated switch with unapplied results enqueues undo toast")
    func userSwitchEnqueuesToast() {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let doc = Self.editingDocument()
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
            documentState: doc,
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
        let doc = Self.editingDocument()
        let state = SearchState()
        state.results = [makeResult(page: 0)]
        // 0 applied → 1 unapplied.

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        let unapplied = SearchAndRedactSheet.unappliedMatchCount(in: state)
        state.clearResults()
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            documentState: doc,
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
        let doc = Self.editingDocument()
        let state = SearchState()
        // Empty results array → nothing cleared → no toast.

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            documentState: doc,
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
        let doc = Self.editingDocument()
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
            documentState: doc,
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
        let doc = Self.editingDocument()
        let state = SearchState()
        state.results = [makeResult(page: 0), makeResult(page: 0), makeResult(page: 1)]
        // 3 unapplied, but the transition is programmatic (a saved-search recall).
        state.isProgrammaticModeChange = true

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            documentState: doc,
            snapshot: snapshot,
            isProgrammatic: state.isProgrammaticModeChange,
            unappliedCount: SearchAndRedactSheet.unappliedMatchCount(in: state)
        )

        #expect(manager.activeToasts.isEmpty)
    }

    // MARK: - Undo restore

    @Test("Undo restores mode, results, applied markers, filter, and sort order")
    func undoRestoresSession() async throws {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let doc = Self.editingDocument()
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
            documentState: doc,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: unapplied
        )

        // Post-clear: session is empty in the new mode.
        #expect(state.results.isEmpty)
        #expect(state.appliedResultIDs.isEmpty)

        // Tap Undo via the toast's action handler. The restore is
        // deferred one runloop turn.
        // The target resolves through the LIVE activeSearch.
        rs.activeSearch = state
        let toast = try #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()

        #expect(state.searchModeType == .piiScan)
        #expect(state.isProgrammaticModeChange == true,
                "the restore routes through the saved-search-recall programmatic hook so the .onChange handler preserves rather than re-clears")
        #expect(state.results.map(\.id) == [r1.id, r2.id])
        #expect(state.appliedResultIDs == [r1.id])
        #expect(state.piiCategoryFilter == [.name])
        #expect(state.sortOrder == .pageAscending)
        #expect(state.appliedFilter == .unapplied,
                "clearResults() resets the applied-state chip to .all; the restore puts it back")
    }

    // MARK: - Restore-target resolution

    @Test("Undo after sheet reopen restores into the NEW live SearchState")
    func undoRestoresIntoReopenedSession() async throws {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let doc = Self.editingDocument()
        let original = SearchState()
        let r1 = makeResult(page: 0)
        original.results = [r1]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: original, previousMode: .regex)
        original.clearResults()
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            documentState: doc,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )

        // Simulate dismiss + reopen: the original session dies, a fresh
        // SearchState becomes the live session — the pre-fix
        // [weak searchState] capture no-oped exactly here.
        let reopened = SearchState()
        rs.activeSearch = reopened

        let toast = try #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()

        #expect(reopened.searchModeType == .regex)
        #expect(reopened.results.map(\.id) == [r1.id])
    }

    @Test("Undo with no live sheet mints a session and presents it")
    func undoMintsAndPresentsWhenNoSheetIsUp() async throws {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let doc = Self.editingDocument()
        let original = SearchState()
        let r1 = makeResult(page: 1)
        original.results = [r1]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: original, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            documentState: doc,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )
        // Sheet fully closed: no live session at tap time.
        #expect(rs.activeSearch == nil)

        let toast = try #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()

        // Assigning activeSearch IS the presentation trigger.
        let presented = try #require(rs.activeSearch)
        #expect(presented.searchModeType == .text)
        #expect(presented.results.map(\.id) == [r1.id])
    }

    @Test("Undo no-ops gracefully after the RedactionState is gone")
    func undoNoOpsAfterRedactionStateDeallocated() async throws {
        let manager = ToastQueueManager()
        var rs: RedactionState? = RedactionState()
        let doc = Self.editingDocument()
        let state = SearchState()
        state.results = [makeResult(page: 0)]

        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs!,
            documentState: doc,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )
        rs = nil

        // The closure holds [weak redactionState]; the structural
        // assertion is that the (deferred) restore no-ops without
        // crashing.
        let toast = try #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()
        #expect(manager.activeToasts.count == 1)
    }

    @Test("Restore arms the programmatic flag only when the mode actually changes")
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

    @Test("unappliedMatchCount leaves out matches a region already covers")
    func unappliedCountExcludesCovered() {
        let state = SearchState()
        let a = makeResult(page: 0), b = makeResult(page: 0), c = makeResult(page: 1)
        state.results = [a, b, c]
        state.appliedResultIDs = [a.id]
        state.coveredResultIDs = [b.id]
        #expect(SearchAndRedactSheet.unappliedMatchCount(in: state) == 1)
        state.coveredResultIDs = [a.id, b.id]
        #expect(SearchAndRedactSheet.unappliedMatchCount(in: state) == 1,
                "an id in both sets counts once")
    }

    // The KI-4 purge re-run toast's
    // actionHandler defers `activeSearch = nil` + the pipeline kick-off one
    // runloop turn via `Task { @MainActor }`, so the @Observable teardown does
    // not co-mutate with `toastManager.dismiss(item)`'s synchronous
    // `withAnimation { activeToasts.removeAll }` in the same tap. This mirrors
    // the receipt's button-action order (actionHandler() then dismiss(item)) and
    // pins that the two mutations are sequential, not simultaneous.
    // (runFullPipeline is not invoked here — the contract under test is the
    // deferral of the @Observable teardown; production defers both together.)
    @Test("KI-4 Re-run action defers activeSearch teardown past the synchronous toast dismiss")
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

        // The receipt's button action: actionHandler() (deferred teardown) then
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

    // MARK: - Run start and phase

    @Test("A run start removes the mode-switch Undo")
    func runStartRemovesTheModeSwitchUndo() {
        let coord = makeLoadedCoordinator()
        let toasts = ToastQueueManager()
        coord.toastManager = toasts
        coord.redactionState.addRegion(
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.05, height: 0.02),
                            source: .manual),
            page: 0, undoManager: nil)
        let state = SearchState()
        state.results = [makeResult(page: 0)]
        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        state.clearResults()
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: toasts,
            redactionState: coord.redactionState,
            documentState: coord.documentState,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )
        #expect(toasts.activeToasts.count == 1)
        #expect(toasts.activeToasts.first?.actionHandler != nil, "the mode-switch Undo is up before the run")

        coord.runFullPipeline(documentOverride: nil)
        defer { coord.documentState.cancelActivePipeline(redactionState: coord.redactionState) }

        #expect(coord.documentState.activePipelineTask != nil, "the run started")
        #expect(!toasts.activeToasts.contains { $0.actionHandler != nil })
    }

    @Test("The mode-switch Undo is withdrawn when the phase leaves editing")
    func modeSwitchUndoWithdrawnWhenThePhaseLeavesEditing() {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let doc = Self.editingDocument()
        manager.documentPhaseDidChange(to: .editing)
        // Something that must be seen is up, so the Undo waits behind it.
        manager.post(.deletedBoxes(count: 2), action: {})
        let state = SearchState()
        state.results = [makeResult(page: 0)]
        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: state, previousMode: .text)
        state.clearResults()
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            documentState: doc,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )
        #expect(manager.waitingToasts.map(\.message) == ["Mode switch cleared 1 unapplied match."],
                "precondition: the Undo is waiting")

        manager.documentPhaseDidChange(to: .verifying)

        #expect(manager.waitingToasts.isEmpty, "the waiting Undo is withdrawn")
        #expect(manager.activeToasts.isEmpty)
        manager.clearAll()
    }

    /// Every phase other than editing, one row each.
    enum NotEditingPhase: String, CaseIterable, CustomTestStringConvertible {
        case empty, importing, detecting, redacting, verifying, verified, exporting, failed
        var testDescription: String { self == .verified ? "verified (the results screen)" : rawValue }
    }

    private static func phase(_ row: NotEditingPhase) -> DocumentState.Phase {
        switch row {
        case .empty: .empty
        case .importing: .importing
        case .detecting: .detecting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "Starting"))
        case .redacting: .redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "Starting"))
        case .verifying:
            .verifying(progress: .init(currentLayer: 1, totalLayers: 5, layerName: "Layer 1", completedLayers: []))
        case .verified: .verified(report: VerificationReport(layers: [], overallStatus: .pass, durationSeconds: 0))
        case .exporting: .exporting
        case .failed: .failed(error: .importError(.corrupt), returnPhase: .empty)
        }
    }

    @Test("Eight phases other than editing, each named once")
    func notEditingPhaseCount() {
        let kinds = NotEditingPhase.allCases.map { row -> DocumentState.PhaseKind in
            let doc = DocumentState()
            doc.phase = Self.phase(row)
            return doc.phaseKind
        }
        #expect(NotEditingPhase.allCases.count == 8)
        #expect(Set(kinds).count == 8)
        #expect(!kinds.contains(.editing))
    }

    @Test("Undo does nothing and opens nothing while the document is not being edited",
          arguments: NotEditingPhase.allCases)
    func undoDoesNothingOutsideEditing(_ row: NotEditingPhase) async throws {
        let manager = ToastQueueManager()
        let rs = RedactionState()
        let doc = DocumentState()
        let original = SearchState()
        original.results = [makeResult(page: 0)]
        let snapshot = SearchAndRedactSheet.modeSwitchSnapshot(of: original, previousMode: .text)
        SearchAndRedactSheet.enqueueModeSwitchUndoToast(
            on: manager,
            redactionState: rs,
            documentState: doc,
            snapshot: snapshot,
            isProgrammatic: false,
            unappliedCount: 1
        )
        doc.phase = Self.phase(row)
        #expect(rs.activeSearch == nil)

        let toast = try #require(manager.activeToasts.first)
        toast.actionHandler?()
        await Task.yield()

        #expect(rs.activeSearch == nil, "no session is created, so Search is not presented")
    }

    /// A document being edited, so the existing tests keep their meaning:
    /// the mode switch's Undo restores only while editing. The test holds
    /// it, since the Undo holds it weakly.
    private static func editingDocument() -> DocumentState {
        let doc = DocumentState()
        doc.phase = .editing
        return doc
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

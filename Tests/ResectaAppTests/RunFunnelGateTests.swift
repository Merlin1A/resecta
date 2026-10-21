import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
import RedactionEngine

// The run funnel refuses what the Redact button refuses. Every route into a
// full run (the button, ⇧⌘R, the paused banner's Restart, the purge Re-run,
// Run Verification's full route) reaches `runFullPipeline`, so the funnel
// reads the same predicate as the button: unapplied search selections, or
// no effective region, refuse the run before any side effect, with the
// button's hint as a notice.

@Suite("Run funnel gate", .tags(.coordination))
@MainActor
struct RunFunnelGateTests {

    private struct Fixture {
        let coord: PipelineCoordinator
        let undo: UndoManager
        let toasts: ToastQueueManager
    }

    private func fixture(region: CGRect) -> Fixture {
        let coord = makeLoadedCoordinator()
        coord.settingsState.paranoidMode = false
        coord.settingsState.autoVerify = false
        coord.redactionState.regions[0] = [RedactionRegion(
            id: UUID(), normalizedRect: region, source: .manual)]
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: coord.redactionState) { _ in }
        undo.endUndoGrouping()
        coord.undoManager = undo
        let toasts = ToastQueueManager()
        coord.toastManager = toasts
        return Fixture(coord: coord, undo: undo, toasts: toasts)
    }

    private let effective = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)

    /// Stops a run the funnel should not have started, so a red test does
    /// not leave a task running into the next one.
    private func settle(_ coord: PipelineCoordinator) async {
        guard let task = coord.documentState.activePipelineTask else { return }
        coord.documentState.cancelActivePipeline(redactionState: coord.redactionState)
        _ = await task.value
    }

    @Test("Unapplied search selections refuse the run before any side effect")
    func selectionsRefuseTheRun() async {
        let f = fixture(region: effective)
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.userModifiedSelections = true
        f.coord.redactionState.activeSearch = search

        f.coord.runFullPipeline(documentOverride: .secureRasterization)
        let started = f.coord.documentState.activePipelineTask != nil
        await settle(f.coord)

        #expect(!started)
        #expect(f.coord.documentState.phaseKind == .editing)
        #expect(f.coord.redactionState.activeSearch === search)
        #expect(search.userModifiedSelections)
        #expect(f.undo.canUndo)
        #expect(f.toasts.activeToasts.map(\.message) == ["Apply or clear the selected matches first"])
    }

    @Test("No effective region refuses the run with the missing-regions hint")
    func noEffectiveRegionRefusesTheRun() async {
        let f = fixture(region: CGRect(x: 0.5, y: 0.5, width: 0.0005, height: 0.0005))

        f.coord.runFullPipeline(documentOverride: .secureRasterization)
        let started = f.coord.documentState.activePipelineTask != nil
        await settle(f.coord)

        #expect(!started)
        #expect(f.coord.documentState.phaseKind == .editing)
        #expect(f.undo.canUndo)
        #expect(f.toasts.activeToasts.map(\.message) == ["Draw regions or apply Scan or Search results first"])
    }

    @Test("An effective region and no selections start the run")
    func effectiveRegionStartsTheRun() async {
        let f = fixture(region: effective)

        f.coord.runFullPipeline(documentOverride: .secureRasterization)
        let started = f.coord.documentState.activePipelineTask != nil
        await settle(f.coord)

        #expect(started)
        #expect(f.toasts.activeToasts.isEmpty)
    }

    @Test("A run already in flight is refused without a notice")
    func busyRefusesSilently() async {
        let f = fixture(region: effective)
        f.coord.documentState.activePipelineTask = Task { }

        f.coord.runFullPipeline(documentOverride: .secureRasterization)

        #expect(f.toasts.activeToasts.isEmpty)
        #expect(f.undo.canUndo)
        f.coord.documentState.activePipelineTask = nil
    }
}

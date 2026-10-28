import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// A registered region step (an undo or a redo) that arrives while a run
// owns the regions, such as the system's three-finger gesture, must not
// change the regions under the run or delete its registered output. The
// undo waits: it is still there when the run ends.

@Suite("Region steps wait while a run owns the regions", .tags(.coordination))
@MainActor
struct RegionMutationGuardTests {

    private struct Fixture {
        let doc: DocumentState
        let red: RedactionState
        let undo: UndoManager
        let output: URL
    }

    /// An editing session with one drawn region (its undo registered) and
    /// a registered output on disk, wired as `RedactWorkspace` wires it.
    private func session() throws -> Fixture {
        let doc = DocumentState()
        let red = RedactionState()
        red.mutationGate = doc
        doc.phase = .editing
        let undo = makeUndoManager()
        undo.beginUndoGrouping()
        red.addRegion(
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                            source: .manual),
            page: 0, undoManager: undo)
        undo.endUndoGrouping()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard_\(UUID().uuidString).pdf")
        try makeTestPDFData().write(to: output)
        red.outputURL = output
        return Fixture(doc: doc, red: red, undo: undo, output: output)
    }

    private func waitForUndo(_ undo: UndoManager) async {
        for _ in 0..<50 where !undo.canUndo { await Task.yield() }
    }

    @Test("An undo during a pending run leaves the regions and the output, and still undoes after the run",
          .timeLimit(.minutes(1)))
    func undoWaitsForAPendingRun() async throws {
        let f = try session()
        f.doc.activePipelineTask = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }

        f.undo.undo()

        #expect(f.red.regions[0]?.count == 1, "the region changed under the run")
        #expect(f.red.outputURL == f.output, "the output was unregistered")
        #expect(FileManager.default.fileExists(atPath: f.output.path), "the output's file was deleted")
        await waitForUndo(f.undo)
        #expect(f.undo.canUndo, "the step is still there")

        f.doc.activePipelineTask?.cancel()
        f.doc.activePipelineTask = nil
        f.undo.undo()
        #expect((f.red.regions[0] ?? []).isEmpty, "after the run the undo removes the region")
    }

    @Test("An undo while redacting or verifying leaves the regions and the output",
          .timeLimit(.minutes(1)))
    func undoWaitsWhileTheRunOwnsThePhase() async throws {
        for phase in [DocumentState.Phase.redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "s")),
                      .verifying(progress: .init(currentLayer: 1, totalLayers: 1, layerName: "l", completedLayers: []))] {
            let f = try session()
            f.doc.phase = phase

            f.undo.undo()

            #expect(f.red.regions[0]?.count == 1, "\(f.doc.phaseKind): the region changed under the run")
            #expect(FileManager.default.fileExists(atPath: f.output.path), "\(f.doc.phaseKind): the output was deleted")
            await waitForUndo(f.undo)
            #expect(f.undo.canUndo, "\(f.doc.phaseKind): the step is still there")
        }
    }

    @Test("A redo during a pending run leaves the regions and the output", .timeLimit(.minutes(1)))
    func redoDuringAPendingRunLeavesTheRegions() async throws {
        let f = try session()
        f.undo.undo()
        try #require((f.red.regions[0] ?? []).isEmpty, "precondition: the undo ran in editing")
        try #require(f.undo.canRedo)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard_\(UUID().uuidString).pdf")
        try makeTestPDFData().write(to: output)
        f.red.outputURL = output
        f.doc.activePipelineTask = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }

        f.undo.redo()

        #expect((f.red.regions[0] ?? []).isEmpty, "the redo changed the regions under the run")
        #expect(FileManager.default.fileExists(atPath: output.path), "the output was deleted")
        f.doc.activePipelineTask?.cancel()
        f.doc.activePipelineTask = nil
    }

    @Test("Without a run the steps run as before", .timeLimit(.minutes(1)))
    func stepsRunWithoutARun() throws {
        let f = try session()
        f.undo.undo()
        #expect((f.red.regions[0] ?? []).isEmpty)
        f.undo.redo()
        #expect(f.red.regions[0]?.count == 1)
    }
}

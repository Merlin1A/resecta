import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The run's record carries the producer's own account of the export: which
// way found the information dictionary for the fixed-value rewrite. On an
// export the system writer made, that is its index. The check never reads
// it; this test reads it from the run's own value. A file the rewrite left
// with part of an old value is never promoted.

@Suite("The run's record says which way found the information dictionary", .serialized, .tags(.coordination))
@MainActor
struct RunRecordInfoDictionaryTests {

    @Test("An ordinary export's record says the index found the dictionary", .timeLimit(.minutes(3)))
    func ordinaryExportFoundByIndex() async throws {
        let coord = try await RunRecordTests.finishedRun()
        let record = try #require(coord.redactionState.lastRunInputs?.record, "the run keeps its record")
        #expect(record.produced.infoDictionary == .byIndex,
                "the record says \(String(describing: record.produced.infoDictionary))")
        // The writer's account joins the rasterizer's, never replaces it: the
        // same record still holds the box the run painted on page 0.
        #expect(record.produced.paintedRectangles.count == 1,
                "the record holds \(record.produced.paintedRectangles.count) painted boxes")
    }

    @Test("A literal left part-written by the rewrite, and not written again whole, promotes no output",
          .timeLimit(.minutes(3)))
    func partWrittenLiteralPromotesNoOutput() async throws {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(RunRecordTests.region(CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05)),
                                       page: 0, undoManager: nil)
        try await PDFStreamReconstructor.$rewriteWholeFails.withValue(true) {
            try await PDFStreamReconstructor.$indexWayFault.withValue(.shortFirstWrite) {
                coord.runFullPipeline(documentOverride: .secureRasterization)
                let run = try #require(coord.documentState.activePipelineTask, "the run started")
                await run.value
            }
        }
        #expect(coord.redactionState.outputURL == nil, "an output was promoted")
        #expect(coord.documentState.phaseKind == .failed, "the run ended \(coord.documentState.phaseKind)")
    }
}

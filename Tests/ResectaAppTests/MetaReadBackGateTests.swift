import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The app keeps an export only when its read-back held: the coordinator's
// gate before the atomic rename reads `metaReadBackHeld` beside the page
// count and the whole-patch flag, as the engine's own page loop does.

@Suite("The export is kept only when its read-back held", .serialized, .tags(.coordination))
@MainActor
struct MetaReadBackGateTests {

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    @Test("The coordinator's gate before the rename reads the read-back")
    func coordinatorGateReadsTheReadBack() throws {
        let text = try source("Sources/ResectaApp/State/PipelineCoordinator+Rasterization.swift")
        let gate = try #require(text.range(of: "await reconstructor.metaReadBackHeld else {"), "the gate reads the read-back")
        let rename = try #require(text.range(of: "replaceItemAt(outputURL, withItemAt: tempURL)"), "the rename")
        #expect(gate.upperBound < rename.lowerBound)
        let guardStart = try #require(text.range(of: "guard await reconstructor.writtenPageCount == pages.count,"))
        let between = text[guardStart.lowerBound..<gate.upperBound]
        #expect(between.contains("await reconstructor.infoPatchesWhole,"))
        #expect(text.components(separatedBy: "metaReadBackHeld").count == 2, "read once, in the gate")
    }

    @Test("With the read-back accepting, a literal left part-written still promotes no output: the whole-patch flag stops it alone",
          .timeLimit(.minutes(3)))
    func wholePatchFlagStopsAlone() async throws {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(RunRecordTests.region(CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05)),
                                       page: 0, undoManager: nil)
        try await PDFStreamReconstructor.$readBackAccepts.withValue(true) {
            try await PDFStreamReconstructor.$rewriteWholeFails.withValue(true) {
                try await PDFStreamReconstructor.$indexWayFault.withValue(.shortFirstWrite) {
                    coord.runFullPipeline(documentOverride: .secureRasterization)
                    let run = try #require(coord.documentState.activePipelineTask, "the run started")
                    await run.value
                }
            }
        }
        #expect(coord.redactionState.outputURL == nil, "an output was promoted")
        #expect(coord.documentState.phaseKind == .failed, "the run ended \(coord.documentState.phaseKind)")
    }
}

import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The position check is handed the run's record: on the run, the record made
// at the Redact tap; on a re-check from the Run Verification card, the same
// record, kept with the run inputs beside the output.
// `verificationRecordSeam` observes what the checks receive.

@Suite("The position check is handed the run's record", .serialized, .tags(.coordination))
@MainActor
struct RecheckRecordTests {

    @Test("A run and its re-check hand the checks the run's record", .timeLimit(.minutes(3)))
    func runAndRecheck() async throws {
        let coord = try InkStripRunEntryTests.coordinator()
        let region = InkStripRunEntryTests.hand(
            InkStripRunEntryTests.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"))
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)

        var received: [RunRecord?] = []
        coord.verificationRecordSeam = { received.append($0) }

        coord.runFullPipeline(documentOverride: .searchableRedaction)
        let run = try #require(coord.documentState.activePipelineTask, "the run started")
        await run.value
        guard case .verified = coord.documentState.phase else {
            Issue.record("the run did not end verified: \(coord.documentState.phaseKind)")
            return
        }
        coord.runVerifyOnly()
        let recheck = try #require(coord.documentState.activePipelineTask, "the re-check started")
        await recheck.value
        guard case .verified = coord.documentState.phase else {
            Issue.record("the re-check did not end verified: \(coord.documentState.phaseKind)")
            return
        }

        try #require(received.count == 2, "the checks ran on the run and on the re-check: \(received.count)")
        let onRun = try #require(received[0], "the run hands the checks a record")
        let page = try #require(onRun.confirmed.pages.first { $0.pageIndex == 0 }, "the record has page 1")
        #expect(page.regions.map(\.id) == [region.id], "the run's record holds the region")
        // A page made with no plan is not the page the run recorded: the
        // record carries the page's boxes.
        #expect(page != RunRecord.Page(pageIndex: 0, regions: page.regions), "the run's record has the page's boxes")
        #expect(received[1] == onRun, "the re-check hands the checks the run's record")
        #expect(coord.redactionState.lastRunInputs?.record == onRun, "the record kept is the one handed")
    }
}

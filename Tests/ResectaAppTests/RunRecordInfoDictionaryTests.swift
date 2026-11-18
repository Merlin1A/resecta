import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The run's record carries the producer's own account of the export: which
// way found the information dictionary for the fixed-value rewrite. On an
// export the system writer made, that is its index. The check never reads
// it; this test reads it from the run's own value.

@Suite("The run's record says which way found the information dictionary", .serialized, .tags(.coordination))
@MainActor
struct RunRecordInfoDictionaryTests {

    @Test("An ordinary export's record says the index found the dictionary", .timeLimit(.minutes(3)))
    func ordinaryExportFoundByIndex() async throws {
        let coord = try await RunRecordTests.finishedRun()
        let record = try #require(coord.redactionState.lastRunInputs?.record, "the run keeps its record")
        #expect(record.produced.infoDictionary == .byIndex,
                "the record says \(String(describing: record.produced.infoDictionary))")
    }
}

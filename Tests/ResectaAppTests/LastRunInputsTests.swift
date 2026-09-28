import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The verification inputs of a redaction run travel as ONE value —
// `RedactionState.LastRunInputs` — recorded beside the output when
// `processDocument` returns and cleared with it. It replaces four separate
// `lastRun*` properties plus a separate deselection record, which shared a
// lifetime but not a type; and the results strip now reads the run's own
// OCR-skip pages and degrade list from this value instead of the session's
// most recent scan record, which need not be the run behind the report.

@Suite("Last-run inputs — one value", .tags(.coordination))
@MainActor
struct LastRunInputsTests {

    private func scanResult(_ index: Int, selected: Bool) -> SearchResult {
        SearchResult(
            pageIndex: index,
            normalizedRect: CGRect(x: 0.1 * CGFloat(index), y: 0.2, width: 0.1, height: 0.03),
            matchedText: "match-\(index)", contextSnippet: "…match-\(index)…",
            source: .textLayer, term: "Name", isSelected: selected,
            piiCategory: .name, piiConfidence: 0.9)
    }

    @Test("recordLastRunInputs retains the whole value; clearOutput drops it")
    func recordAndClearWithOutput() {
        let redaction = RedactionState()
        #expect(redaction.lastRunInputs == nil)
        let deselection = RedactionState.DeselectionSnapshot(
            items: [scanResult(0, selected: false)], totalCount: 3)
        let inputs = RedactionState.LastRunInputs.fixture(
            perPageModes: [.searchableRedaction, .secureRasterization],
            perPageFallbackReasons: [nil, .rtlText],
            sensitiveTerms: [SensitiveTerm(text: "Delia Hartwell")],
            manualRegionsWithoutText: 2,
            deselection: deselection,
            ocrSkippedPages: [2, 4],
            degradeFailures: ["NameGazetteer"])

        redaction.recordLastRunInputs(inputs)

        #expect(redaction.lastRunInputs == inputs)
        #expect(redaction.lastRunInputs?.perPageModes == [.searchableRedaction, .secureRasterization])
        #expect(redaction.lastRunInputs?.perPageFallbackReasons == [nil, .rtlText])
        #expect(redaction.lastRunInputs?.sensitiveTerms.terms == [SensitiveTerm(text: "Delia Hartwell")])
        #expect(redaction.lastRunInputs?.sensitiveTerms.manualRegionsWithoutText == 2)
        #expect(redaction.lastRunInputs?.appliedSearches == [])
        #expect(redaction.lastRunInputs?.deselection == deselection)
        #expect(redaction.lastRunInputs?.ocrSkippedPages == [2, 4])
        #expect(redaction.lastRunInputs?.degradeFailures == ["NameGazetteer"])

        redaction.clearOutput()
        #expect(redaction.lastRunInputs == nil,
                "discarding the output drops the inputs that describe it")
    }

    @Test("Both document boundaries clear the value")
    func clearedAtDocumentBoundaries() {
        let redaction = RedactionState()
        redaction.recordLastRunInputs(.fixture(ocrSkippedPages: [1]))
        #expect(redaction.lastRunInputs != nil)
        redaction.clearForNewDocument()
        #expect(redaction.lastRunInputs == nil)

        redaction.recordLastRunInputs(.fixture(ocrSkippedPages: [1]))
        #expect(redaction.lastRunInputs != nil)
        redaction.clearAll()
        #expect(redaction.lastRunInputs == nil)
    }

    @Test("A later run's value replaces the previous one whole — no field survives from the old run")
    func laterRunReplacesWhole() {
        let redaction = RedactionState()
        redaction.recordLastRunInputs(.fixture(
            deselection: RedactionState.DeselectionSnapshot(
                items: [scanResult(0, selected: false)], totalCount: 2),
            ocrSkippedPages: [3],
            degradeFailures: ["NameGazetteer"]))
        #expect(redaction.lastRunInputs?.deselection != nil)

        redaction.recordLastRunInputs(.fixture(perPageModes: [.searchableRedaction]))

        #expect(redaction.lastRunInputs?.perPageModes == [.searchableRedaction])
        #expect(redaction.lastRunInputs?.deselection == nil)
        #expect(redaction.lastRunInputs?.ocrSkippedPages == [])
        #expect(redaction.lastRunInputs?.degradeFailures == nil)
    }

    @Test("redactionFinished records the value beside the re-published output")
    func redactionFinishedRecordsTheValue() throws {
        let coordinator = makeCoordinator()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("last_run_inputs_\(UUID().uuidString).pdf")
        try Data("output".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let inputs = RedactionState.LastRunInputs.fixture(
            perPageModes: [.secureRasterization], ocrSkippedPages: [1])

        coordinator.apply(.outputRegistered(url))
        coordinator.apply(.redactionFinished(outputURL: url, inputs: inputs))

        #expect(coordinator.redactionState.outputURL == url)
        #expect(coordinator.redactionState.lastRunInputs == inputs)
    }

    @Test("The value is Equatable and Sendable — it crosses from the run to the state as a plain value")
    func valueSemantics() {
        let a = RedactionState.LastRunInputs.fixture(ocrSkippedPages: [1])
        let b = RedactionState.LastRunInputs.fixture(ocrSkippedPages: [1])
        let c = RedactionState.LastRunInputs.fixture(ocrSkippedPages: [2])
        #expect(a == b)
        #expect(a != c)
        let sendable: any Sendable = a
        #expect((sendable as? RedactionState.LastRunInputs) == a)
    }
}

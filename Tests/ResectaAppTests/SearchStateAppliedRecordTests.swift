import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The applied-search record the apply seam stamps on every search-origin
// audit entry now covers the Scan interface too: a `.piiScan` session
// records the categories it ran (the effective set — an empty selection
// means every category), the session's options, the configuration the run
// compiled at kickoff (the preset thresholds and the user terms) and the
// same coverage facts as a typed search. The Detection Sweep re-runs the
// scan on the output from this record.

@Suite("Applied-search record for a Scan session", .tags(.search))
@MainActor
struct SearchStateAppliedRecordTests {

    private func scanResult(_ index: Int, selected: Bool = true) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1 * CGFloat(index), y: 0.2, width: 0.1, height: 0.03),
            matchedText: "match-\(index)", contextSnippet: "…match-\(index)…",
            source: .textLayer, term: "Name", isSelected: selected,
            piiCategory: .name, piiConfidence: 0.9)
    }

    private var configuration: ScanRunConfiguration {
        ScanRunConfiguration(
            thresholdVector: PresetThresholdVector(thresholdsByWireName: ["ssn": 0.5, "name": 0.7]),
            alwaysFlag: [UserTerm(pattern: "ACME-4471", isRegex: false)],
            neverFlag: [UserTerm(pattern: "Sample", isRegex: false)])
    }

    @Test("A Scan session records its effective categories, options, kickoff configuration and coverage facts")
    func scanSessionRecords() {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.enabledPIICategories = [.ssn, .name]
        state.options.includeOCR = false
        state.results = [scanResult(0), scanResult(1), scanResult(2, selected: false)]
        state.resultsAtCap = true
        state.lastRunScanConfiguration = configuration

        let record = state.appliedSearchRecord()

        #expect(record?.query.kind == .piiScan(categories: [.ssn, .name]))
        #expect(record?.query.options == state.options)
        #expect(record?.scanConfiguration == configuration)
        #expect(record?.foundCount == 3, "every result, selected or not")
        #expect(record?.foundHitCap == true)
        #expect(record?.ocrSkippedPages == state.ocrSkippedPages)
        #expect(record?.regexTimeoutPages == state.regexTimeoutPages)
        #expect(record?.unscannedPageCount == state.capUnscannedPageCount)
    }

    @Test("An empty category selection records every category — the run that happened")
    func emptySelectionMeansAllCategories() {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.enabledPIICategories = []
        state.results = [scanResult(0)]
        state.lastRunScanConfiguration = ScanRunConfiguration(thresholdVector: nil)

        let record = state.appliedSearchRecord()

        #expect(record?.query.kind == .piiScan(categories: state.effectiveScanCategories))
        #expect(record?.query.kind == .piiScan(categories: Set(PIICategory.allCases)))
        #expect(record?.scanConfiguration == ScanRunConfiguration(thresholdVector: nil))
    }

    @Test("A Scan session that never ran records nothing")
    func scanSessionWithoutARun() {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.results = [scanResult(0)]
        #expect(state.lastRunScanConfiguration == nil)
        #expect(state.appliedSearchRecord() == nil)
    }

    @Test("A typed session's record is unchanged: no scan configuration")
    func typedSessionUnchanged() {
        let state = SearchState()
        state.searchModeType = .text
        state.queryText = "wren"
        state.results = [scanResult(0)]
        // A configuration left over from an earlier kickoff never rides a
        // typed record.
        state.lastRunScanConfiguration = configuration

        let record = state.appliedSearchRecord()

        #expect(record?.query.kind == .text("wren"))
        #expect(record?.scanConfiguration == nil)
        #expect(record?.foundCount == 1)
    }

    @Test("The kickoff configuration clears with the session")
    func configurationClearsWithSession() {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.lastRunScanConfiguration = configuration
        state.clear()
        #expect(state.lastRunScanConfiguration == nil)
    }
}

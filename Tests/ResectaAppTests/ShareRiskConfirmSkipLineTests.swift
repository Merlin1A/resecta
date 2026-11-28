import Testing
import Foundation
@testable import ResectaApp
import RedactionEngine

// Pins the fact line of the skipped share confirm: the line says why
// verification has no result, one line per skip reason.
//
// Source-of-truth helper:
//   • DocumentEditorView.shareRiskConfirmSkipFactLine(reason:) — the line the
//     skipped share confirm shows for a report skipped by that reason.
//
// The gate that decides when the skipped confirm appears is pinned in
// SkippedShareGateTests (VerificationResultsShareGateTests.swift).

@Suite("Skipped share confirm fact line")
@MainActor
struct ShareRiskConfirmSkipLineTests {
    @Test("Skip-fact line names why verification has no result, one line per reason")
    func skipFactLineNamesTheReason() {
        let table: [(VerificationReport.SkipReason, String)] = [
            (.autoVerifyOff, "Verification did not run on this PDF."),
            (.error, "Verification could not finish on this PDF."),
            (.cancelled, "Verification stopped early on this PDF."),
        ]
        #expect(table.count == 3)
        #expect(Set(table.map(\.1)).count == 3)
        for (reason, line) in table {
            #expect(DocumentEditorView.shareRiskConfirmSkipFactLine(reason: reason) == line, "\(reason)")
        }
    }

    @Test("A skipped report given no reason reads the off-in-Settings line, not the could-not-finish line")
    func skipFactLineForADefaultSkippedReport() {
        let report = VerificationReport.skipped
        #expect(report.skipReason == .autoVerifyOff)
        #expect(DocumentEditorView.shareRiskConfirmSkipFactLine(reason: report.skipReason)
            == "Verification did not run on this PDF.")
    }
}

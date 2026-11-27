import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The share confirm's words: the sheet's lines name each check by its
// title, the outcome and the pages; never an engine sentence, never
// matched text. (Share's spoken hint is pinned with the actions.)

@Suite("Share confirm copy", .tags(.display))
@MainActor
struct ShareRiskConfirmCopyTests {

    typealias Fixtures = VerificationDebugFixtures

    @Test("The FAIL/ATTENTION family's lines: title, outcome, pages, the short titles, then the checks that did not run in full")
    func atRiskLines() {
        #expect(DocumentEditorView.atRiskItemLines(report: Fixtures.searchableAttentionMixed)
                == ["Boxed Text in the File: needs review on\u{00A0}page\u{00A0}2",
                    "Text Recognition of Each Page: could not verify on\u{00A0}page\u{00A0}3",
                    "Fonts in the Searchable Copy: could not verify on\u{00A0}page\u{00A0}3"],
                "the same report's could-not-verify checks follow the at-risk ones")
        #expect(DocumentEditorView.atRiskItemLines(report: Fixtures.searchableAttentionFull)
                == ["Boxed Text in the File: needs review on pages 2\u{00A0}and\u{00A0}3",
                    "Boxed Text in Drawing Commands: needs review on\u{00A0}page\u{00A0}2"]
                    + DocumentEditorView.couldNotVerifyItemLines(report: Fixtures.searchableAttentionFull))
        #expect(DocumentEditorView.atRiskItemLines(report: Fixtures.pageCountGate)
                == ["Page Count: failed"] + DocumentEditorView.couldNotVerifyItemLines(report: Fixtures.pageCountGate))
        #expect(DocumentEditorView.atRiskItemLines(report: Fixtures.secureFail)
                == ["Leftover Text & Markup: failed on\u{00A0}page\u{00A0}1"]
                    + DocumentEditorView.couldNotVerifyItemLines(report: Fixtures.secureFail))
        for line in DocumentEditorView.atRiskItemLines(report: Fixtures.secureAllFailed) {
            #expect(line.count <= 90, "\(line)")
        }
    }

    @Test("The incomplete family lists the could-not-verify and the skipped checks; no masthead sentence")
    func incompleteLines() {
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Fixtures.searchableSkipInduced)
                == ["Character Count: skipped", "Kept Text Unchanged: skipped"])
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Fixtures.searchableAttentionMixed)
                == ["Text Recognition of Each Page: could not verify on\u{00A0}page\u{00A0}3",
                    "Fonts in the Searchable Copy: could not verify on\u{00A0}page\u{00A0}3"])
        let kind = ShareRiskConfirmKind.incompleteWarn(Fixtures.searchableSkipInduced)
        #expect(kind.title == "Share with incomplete checks?")
        #expect(kind.listHeader == "These checks did not run in full:")
        #expect(!kind.itemLines.contains(VerificationResultsView.mastheadSubtitle(
            report: Fixtures.searchableSkipInduced) ?? ""))
    }

    @Test("No confirm line carries the user's text")
    func confirmLinesAreContentFree() {
        let lines = DocumentEditorView.atRiskItemLines(report: Fixtures.searchableAttentionLong)
            + DocumentEditorView.atRiskItemLines(report: Fixtures.searchableRecheckReview)
        for line in lines {
            for term in ["Northwest", "Margaret", "Delia", "\\d{4}", "Brien"] {
                #expect(!line.contains(term), "\(line)")
            }
        }
    }

    // MARK: - The purged-output route

    @Test("A purged output fails the export through exporting, never the illegal verified → failed pair")
    func purgedOutputRoutesThroughExporting() {
        #expect(!DocumentState.legalTransitions.contains(.init(.verified, .failed)))
        let state = DocumentState()
        state.phase = .verified(report: Fixtures.secureAllPass)
        DocumentEditorView.failExportForPurgedOutput(documentState: state)
        guard case .failed(.exportError(.filePurged), .editing) = state.phase else {
            Issue.record("expected the purged failure returning to editing, got \(state.phaseKind)")
            return
        }
    }
}

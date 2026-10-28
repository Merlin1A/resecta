import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Share asks first when the Detection Sweep reports possible items on the
// output or the original's filled form values were not carried into it —
// on any verdict, a passing one included. A fifth confirm family, ordered
// after the other four; its lines ride every family's sheet. Real
// `DocumentState`, the real gate and completion, the seeded reports.

@Suite("Share asks before sending a PDF with possible items left")
@MainActor
struct PossibleItemsConfirmTests {

    private typealias Editor = DocumentEditorView
    private typealias Fixtures = VerificationDebugFixtures

    private func kindID(_ report: VerificationReport, _ doc: DocumentState, concealed: [Int] = []) -> String? {
        Editor.shareConfirmKind(report: report, documentState: doc, concealedPages: concealed)?.id
    }

    private func verified(_ report: VerificationReport) -> DocumentState {
        let doc = DocumentState()
        doc.phase = .verified(report: report)
        return doc
    }

    @Test("A passing report whose sweep left possible items asks; a clean pass shares at once")
    func sweepNoteAsks() {
        #expect(kindID(Fixtures.secureScreenshot, verified(Fixtures.secureScreenshot)) == "possibleItems")
        #expect(kindID(Fixtures.secureAllPass, verified(Fixtures.secureAllPass)) == nil)
    }

    @Test("Filled form values not carried over ask on a clean pass")
    func formValuesAsk() {
        let doc = verified(Fixtures.secureAllPass)
        doc.sourceFilledFormFieldCount = 4
        #expect(kindID(Fixtures.secureAllPass, doc) == "possibleItems")
    }

    @Test("Ordered last: covered text and the other families present first, and carry the lines")
    func orderedLast() {
        let doc = verified(Fixtures.secureScreenshot)
        #expect(kindID(Fixtures.secureScreenshot, doc, concealed: [0]) == "concealedAnnotations")
        #expect(kindID(Fixtures.secureFail, verified(Fixtures.secureFail)) == "failOrAttention")
        #expect(!Editor.possibleItemLines(report: Fixtures.secureScreenshot, formFieldCount: 0).isEmpty)
    }

    @Test("The lines: the sweep's own sentence under its title, then the form values' results sentence")
    func lines() throws {
        let sweep = try #require(Fixtures.secureScreenshot.layers.first(where: VerificationRowModel.hasItemsRemaining))
        #expect(Editor.possibleItemLines(report: Fixtures.secureScreenshot, formFieldCount: 4) == [
            "Detection Sweep: \(VerificationRowModel.sweepRemainingCaption(sweep))",
            ResultsFinding.filledFormValuesNotCarried(count: 4).sentence,
        ])
        #expect(Editor.possibleItemLines(report: Fixtures.secureAllPass, formFieldCount: 0).isEmpty)
    }

    @Test("Its own title and identifier, no list header; the slide completes it and a completed send re-arms it")
    func familyAndLifetime() throws {
        let kind = ShareRiskConfirmKind.possibleItems(Fixtures.secureScreenshot)
        #expect(kind.title == "Share with possible items left?")
        #expect(kind.accessibilityIdentifier == "sharePossibleItemsConfirm")
        #expect(kind.listHeader == nil)

        let saved = Editor.shareRiskConfirmHaptic
        Editor.shareRiskConfirmHaptic = {}
        defer { Editor.shareRiskConfirmHaptic = saved }
        let doc = verified(Fixtures.secureScreenshot)
        var exported = 0
        Editor.completeShareRiskConfirm(kind: kind, documentState: doc, beginExport: { _ in exported += 1 })
        #expect(exported == 1)
        #expect(kindID(Fixtures.secureScreenshot, doc) == nil)
        Editor.handleShareSheetCompletion(completed: true, documentState: doc,
                                          announceShared: {}, recordSuccessfulExport: {})
        #expect(kindID(Fixtures.secureScreenshot, doc) == "possibleItems")
    }
}

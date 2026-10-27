import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// A completed send spends the share confirm for that send only: the next
// Share of the same results asks again, whichever family presented. The
// risk the confirm names is per recipient, so a second recipient gets the
// same question. Real `DocumentState`, the real Share-tap gate
// (`shareConfirmKind`), the real completion (`completeShareRiskConfirm`)
// and the share sheet's completion seam (`handleShareSheetCompletion`).

@Suite("Share confirm re-arms after every send")
@MainActor
struct ShareConfirmRearmTests {

    private static func layer(_ status: VerificationStatus) -> LayerResult {
        LayerResult(name: "Character Count", symbolName: "number", status: status,
                    shortDescription: "", detailDescription: "", pageReferences: nil, durationSeconds: 0)
    }

    private static let failReport = VerificationReport(
        layers: [layer(.fail("x"))], overallStatus: .fail("x"), durationSeconds: 0)
    private static let incompleteWarnReport = VerificationReport(
        layers: [layer(.skipped)], overallStatus: .warn("x"), durationSeconds: 0)
    private static let passReport = VerificationReport(
        layers: [layer(.pass)], overallStatus: .pass, durationSeconds: 0)

    /// The family the Share tap routes to for the live report, or nil.
    private func kindID(_ doc: DocumentState, concealed: [Int]) -> String? {
        guard case .verified(let report) = doc.phase else { return nil }
        return DocumentEditorView.shareConfirmKind(
            report: report, documentState: doc, concealedPages: concealed)?.id
    }

    /// Share → the confirm → the slide (the real completion) → the share
    /// sheet reports a completed send. Returns how often the send was
    /// announced and recorded.
    private func confirmThenSend(_ doc: DocumentState, concealed: [Int]) throws -> (announced: Int, recorded: Int) {
        let savedHaptic = DocumentEditorView.shareRiskConfirmHaptic
        DocumentEditorView.shareRiskConfirmHaptic = {}
        defer { DocumentEditorView.shareRiskConfirmHaptic = savedHaptic }
        guard case .verified(let report) = doc.phase else {
            Issue.record("expected a verified report")
            return (0, 0)
        }
        let kind = try #require(DocumentEditorView.shareConfirmKind(
            report: report, documentState: doc, concealedPages: concealed))
        var exported = 0
        DocumentEditorView.completeShareRiskConfirm(kind: kind, documentState: doc, beginExport: { _ in exported += 1 })
        #expect(exported == 1)
        #expect(kindID(doc, concealed: concealed) == nil, "the confirm is spent for the send it confirmed")
        var announced = 0, recorded = 0
        DocumentEditorView.handleShareSheetCompletion(
            completed: true, documentState: doc,
            announceShared: { announced += 1 }, recordSuccessfulExport: { recorded += 1 })
        return (announced, recorded)
    }

    @Test("Reported issues: after a completed send, Share asks again; the send is announced and recorded once")
    func failAsksAgain() throws {
        let doc = DocumentState()
        doc.phase = .verified(report: Self.failReport)
        let counts = try confirmThenSend(doc, concealed: [])
        #expect(counts.announced == 1)
        #expect(counts.recorded == 1)
        #expect(kindID(doc, concealed: []) == "failOrAttention")
    }

    @Test("Verification skipped: after a completed send, Share asks again")
    func skippedAsksAgain() throws {
        let doc = DocumentState()
        doc.phase = .verified(report: .skipped(reason: .autoVerifyOff))
        _ = try confirmThenSend(doc, concealed: [])
        #expect(kindID(doc, concealed: []) == "skipped")
    }

    @Test("Incomplete checks: after a completed send, Share asks again")
    func incompleteWarnAsksAgain() throws {
        let doc = DocumentState()
        doc.phase = .verified(report: Self.incompleteWarnReport)
        _ = try confirmThenSend(doc, concealed: [])
        #expect(kindID(doc, concealed: []) == "incompleteWarn")
    }

    @Test("Covered text on a passing report: after a completed send, Share asks again")
    func concealedAsksAgain() throws {
        let doc = DocumentState()
        doc.phase = .verified(report: Self.passReport)
        _ = try confirmThenSend(doc, concealed: [0])
        #expect(kindID(doc, concealed: [0]) == "concealedAnnotations")
    }
}

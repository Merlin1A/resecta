import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// A share whose copy could not be written never started a send, so it used
// no acknowledgement: the editor shows the failure, and the results it
// returns to ask before sharing again, exactly as before the first tap.
@Suite("Share copy write failure")
@MainActor
struct ShareCopyWriteFailureTests {

    struct WriteFailed: Error {}

    @Test("A failed write of the share copy returns to results that ask again before sharing")
    func failedWriteArmsTheConfirmsAgain() throws {
        let document = DocumentState()
        document.phase = .verified(report: VerificationDebugFixtures.secureFail)
        document.overrideVerificationFailure()
        document.acknowledgeIncompleteWarnShare()
        document.acknowledgePossibleItemsShare()
        guard case .verified(let acknowledged) = document.phase else {
            Issue.record("not on the results"); return
        }
        #expect(acknowledged.userOverrodeFailure)
        #expect(DocumentEditorView.shareConfirmKind(
            report: acknowledged, documentState: document, concealedPages: []) == nil,
                "the acknowledgement covers this send")
        document.transition(to: .exporting)

        let copy = DocumentEditorView.writeShareCopy(
            report: acknowledged, documentState: document, write: { throw WriteFailed() })

        #expect(copy == nil)
        guard case .failed(let error, .verified(let returned)) = document.phase else {
            Issue.record("a failed write did not show the failure over the results: \(document.phaseKind)"); return
        }
        guard case .exportError(.writeFailed) = error else {
            Issue.record("showed \(error)"); return
        }
        #expect(returned.userOverrodeFailure == false)
        #expect(returned.userAcknowledgedSkippedShare == false)
        #expect(document.failShareAcknowledged == false)
        #expect(document.skippedShareAcknowledged == false)
        #expect(document.incompleteWarnShareAcknowledged == false)
        #expect(document.concealedAnnotationsShareAcknowledged == false)
        #expect(document.possibleItemsShareAcknowledged == false)
        let kind = DocumentEditorView.shareConfirmKind(
            report: returned, documentState: document, concealedPages: [])
        guard case .failOrAttention? = kind else {
            Issue.record("the next Share tap does not ask again: \(String(describing: kind))"); return
        }
    }

    @Test("The app names the failed share-copy write in one place, inside the function that owns it")
    func failedWriteHasOneOwner() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("AppError+Display.swift") }
        #expect(files.count > 100, "the source tree was not found")
        var places: [String] = []
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("exportError(.writeFailed)") {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                places.append((file as NSString).lastPathComponent)
            }
        }
        #expect(places == ["DocumentEditorView+Export.swift"], "\(places)")

        let export = try String(
            contentsOf: sources.appendingPathComponent("Views/DocumentEditorView+Export.swift"), encoding: .utf8)
        let start = try #require(export.range(of: "static func writeShareCopy("))
        let end = try #require(export.range(of: "\n    }\n", range: start.upperBound..<export.endIndex))
        #expect(export[start.lowerBound..<end.upperBound].contains("exportError(.writeFailed)"),
                "the failed write is shown from inside the function")
    }
}

import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// A share whose sheet never appears must not strand the editor on the
// exporting card. One path returns it to the results, whatever noticed the
// failure: no presenter at all, the watchdog armed after `present`, or the
// exporting card's Cancel. The share copy is deleted and the share-risk
// confirms are re-armed, as for a share the user cancelled.
@Suite("Share sheet watchdog")
@MainActor
struct ShareSheetWatchdogTests {

    private func exportingDocument() -> DocumentState {
        let document = DocumentState()
        document.phase = .verified(report: VerificationDebugFixtures.secureAllPass)
        document.overrideVerificationFailure()
        precondition(document.failShareAcknowledged, "the confirm was spent")
        document.transition(to: .exporting)
        return document
    }

    private func shareCopy() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share_watchdog_\(UUID().uuidString).pdf")
        try Data("copy".utf8).write(to: url)
        return url
    }

    @Test("An abandoned share returns to the results, deletes the copy and re-arms the confirms")
    func abandonReturnsToTheResults() throws {
        let document = exportingDocument()
        let copy = try shareCopy()

        let abandoned = DocumentEditorView.abandonShare(
            copy: copy, report: VerificationDebugFixtures.secureAllPass, documentState: document)

        #expect(abandoned)
        #expect(document.phaseKind == .verified)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(document.failShareAcknowledged == false)
    }

    @Test("A share that already finished is left alone")
    func abandonAfterTheShareFinishedDoesNothing() throws {
        let document = DocumentState()
        document.phase = .verified(report: VerificationDebugFixtures.secureAllPass)
        let copy = try shareCopy()
        defer { try? FileManager.default.removeItem(at: copy) }

        #expect(!DocumentEditorView.abandonShare(
            copy: copy, report: VerificationDebugFixtures.secureAllPass, documentState: document))
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test("The watchdog recovers when the sheet never appeared")
    func watchdogRecoversAnUnpresentedSheet() async {
        var recovered = false
        let task = DocumentEditorView.armShareSheetWatchdog(
            delay: .milliseconds(50), isPresented: { false }, recover: { recovered = true })
        await task.value
        #expect(recovered)
    }

    @Test("The watchdog stays quiet when the sheet is up")
    func watchdogQuietWhenPresented() async {
        var recovered = false
        let task = DocumentEditorView.armShareSheetWatchdog(
            delay: .milliseconds(50), isPresented: { true }, recover: { recovered = true })
        await task.value
        #expect(!recovered)
    }
}

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
        let attempt = UUID()
        document.liveShareAttempt = attempt

        let abandoned = DocumentEditorView.abandonShare(
            copy: copy, report: VerificationDebugFixtures.secureAllPass, attempt: attempt,
            documentState: document)

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
            copy: copy, report: VerificationDebugFixtures.secureAllPass, attempt: UUID(),
            documentState: document))
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test("The first share's watchdog leaves a second share started within its delay alone")
    func staleWatchdogLeavesTheNextShareAlone() throws {
        let report = VerificationDebugFixtures.secureAllPass
        let document = exportingDocument()
        let copy = try shareCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        let first = UUID()
        document.liveShareAttempt = first
        // Share 1: the user closes the sheet at once.
        DocumentEditorView.finishShare(
            completed: false, copy: copy, report: report, attempt: first,
            documentState: document, announceShared: {}, recordSuccessfulExport: {})
        // Share 2, inside share 1's watchdog delay: a fresh copy at the same path.
        document.transition(to: .exporting)
        try Data("second".utf8).write(to: copy)
        let second = UUID()
        document.liveShareAttempt = second

        // Share 1's watchdog fires: its sheet is gone, so it tries to abandon.
        let abandoned = DocumentEditorView.abandonShare(
            copy: copy, report: report, attempt: first, documentState: document)

        #expect(!abandoned, "a watchdog acts only on its own share")
        #expect(document.phaseKind == .exporting, "share 2 is still on screen")
        #expect(FileManager.default.fileExists(atPath: copy.path), "share 2's copy is still there")
        #expect(document.liveShareAttempt == second)
    }

    @Test("A completion that names an earlier share changes nothing")
    func staleCompletionChangesNothing() throws {
        let document = exportingDocument()
        let copy = try shareCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        document.liveShareAttempt = UUID()

        let finished = DocumentEditorView.finishShare(
            completed: true, copy: copy, report: VerificationDebugFixtures.secureAllPass,
            attempt: UUID(), documentState: document,
            announceShared: { Issue.record("announced for another share") },
            recordSuccessfulExport: { Issue.record("recorded for another share") })

        #expect(!finished)
        #expect(document.phaseKind == .exporting)
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

    @Test("A cancelled watchdog does not recover")
    func cancelledWatchdogStaysQuiet() async {
        var recovered = false
        let task = DocumentEditorView.armShareSheetWatchdog(
            delay: .seconds(5), isPresented: { false }, recover: { recovered = true })
        task.cancel()
        await task.value
        #expect(!recovered)
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

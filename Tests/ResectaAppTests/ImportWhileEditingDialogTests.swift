import Testing
@testable import ResectaApp

// UXC-31 (RB-40) — dialog-grammar normalization. The D12
// import-while-editing confirmation previously read as a statement
// ("You have a document open") with a Title-Case destructive button
// ("Import New"); this pins the app-wide dominant grammar instead:
// sentence-case QUESTION title + bare-verb destructive button.

@Suite("Import-while-editing dialog copy (UXC-31/RB-40)")
@MainActor
struct ImportWhileEditingDialogTests {

    @Test("Title is a sentence-case question naming what the action does")
    func titlePinned() {
        #expect(RedactWorkspaceView.importWhileEditingTitle == "Replace the open document?")
    }

    @Test("Destructive button is the bare verb, matching the dominant dialog grammar")
    func confirmButtonPinned() {
        #expect(RedactWorkspaceView.importWhileEditingConfirmButton == "Replace")
    }
}

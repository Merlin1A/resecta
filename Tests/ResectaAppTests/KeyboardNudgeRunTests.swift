import Testing
import Foundation
@testable import ResectaApp

// A run of arrow-key nudges on one selection is one undo step: a nudge
// continues the run when it moves the same selection within the window.
@Suite("Keyboard nudge run", .tags(.overlay))
@MainActor
struct KeyboardNudgeRunTests {

    @Test("The same selection within the window continues the run")
    func sameSelectionContinues() {
        let ids: Set<UUID> = [UUID()]
        let start = Date(timeIntervalSince1970: 100)
        let run = DocumentEditorKeyboard.NudgeRun(selection: ids, at: start)
        #expect(DocumentEditorKeyboard.nudgeContinuesRun(
            previous: run, selection: ids, now: start.addingTimeInterval(0.3)))
    }

    @Test("A new selection, a pause past the window, or no run starts a new step")
    func otherwiseANewStep() {
        let ids: Set<UUID> = [UUID()]
        let start = Date(timeIntervalSince1970: 100)
        let run = DocumentEditorKeyboard.NudgeRun(selection: ids, at: start)
        #expect(!DocumentEditorKeyboard.nudgeContinuesRun(
            previous: run, selection: [UUID()], now: start.addingTimeInterval(0.3)))
        #expect(!DocumentEditorKeyboard.nudgeContinuesRun(
            previous: run, selection: ids, now: start.addingTimeInterval(DocumentEditorKeyboard.nudgeRunWindow + 0.1)))
        #expect(!DocumentEditorKeyboard.nudgeContinuesRun(
            previous: nil, selection: ids, now: start))
    }
}

import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// A drop refused on the results screen or an error screen names the way
// back that screen offers, by its button's own title — not "the editor"
// on a screen whose only button is Choose Another File or Return to
// Results.

@Suite("Drop refusal: the way back is named")
@MainActor
struct ImportRefusalMessageTests {

    private func report() -> VerificationReport {
        VerificationDebugFixtures.all.values.first!
    }

    @Test("The results screen names Keep Editing")
    func resultsScreen() {
        let documentState = DocumentState()
        documentState.phase = .verified(report: report())
        #expect(documentState.importRefusalMessage(with: RedactionState())
                == "Cannot import from this screen. Tap Keep Editing first.")
    }

    @Test("An error screen names its own button: Return to Editor, Return to Results, Choose Another File, Re-open Document")
    func errorScreens() {
        let documentState = DocumentState()
        let redactionState = RedactionState()
        documentState.phase = .failed(error: .importError(.unsupportedFormat), returnPhase: .editing)
        #expect(documentState.importRefusalMessage(with: redactionState)
                == "Cannot import from this screen. Tap Return to Editor first.")
        documentState.phase = .failed(error: .importError(.unsupportedFormat), returnPhase: .empty)
        #expect(documentState.importRefusalMessage(with: redactionState)
                == "Cannot import from this screen. Tap Choose Another File first.")
        documentState.phase = .failed(error: .redactionError(.reconstructionFailed), returnPhase: .verified(report: report()))
        #expect(documentState.importRefusalMessage(with: redactionState)
                == "Cannot import from this screen. Tap Return to Results first.")
        documentState.phase = .failed(error: .exportError(.filePurged), returnPhase: .empty)
        #expect(documentState.importRefusalMessage(with: redactionState)
                == "Cannot import from this screen. Tap Re-open Document first.")
    }

    @Test("The sentence follows the failed screen's button title")
    func sentenceFollowsTheButton() {
        for action in [FailedStateView.PrimaryAction.reopenDocument, .chooseAnotherFile, .returnToEditor, .returnToResults] {
            let label = FailedStateView.primaryActionLabel(action)
            #expect(DocumentState.importBlockedOnThisScreenMessage(wayBack: label).contains("Tap \(label) first."))
        }
    }
}

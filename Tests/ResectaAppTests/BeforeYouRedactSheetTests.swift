import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// The stop at Redact's sheet: its choices, what each answer does, when the
// editor's slot shows it, and its height. Each expectation is copied from
// the rule's table, never worked out from the code under test.

@Suite("Before You Redact")
@MainActor
struct BeforeYouRedactSheetTests {

    typealias Sheet = BeforeYouRedactSheet

    @Test("Exactly one capsule is teal in every state of the stop sheet, and it is never Redact Anyway")
    func oneTealCapsule() {
        // A recognition-off row with the re-run offered: three capsules.
        #expect(Sheet.choices(offersSearchThesePages: true) == [
            Sheet.Choice(capsule: .searchThesePages, style: .tealSolid),
            Sheet.Choice(capsule: .redactAnyway, style: .outlined),
            Sheet.Choice(capsule: .cancel, style: .plain),
        ])
        // Any other state: two capsules.
        #expect(Sheet.choices(offersSearchThesePages: false) == [
            Sheet.Choice(capsule: .redactAnyway, style: .outlined),
            Sheet.Choice(capsule: .cancel, style: .tealSolid),
        ])
        for offers in [true, false] {
            let choices = Sheet.choices(offersSearchThesePages: offers)
            #expect(choices.filter { $0.style == .tealSolid }.count == 1)
            #expect(!choices.contains(Sheet.Choice(capsule: .redactAnyway, style: .tealSolid)))
        }
    }

    @Test("Each answer does only what it promises; a swipe down and Go to page are Cancel")
    func answers() {
        typealias E = Sheet.Effects
        let table: [(BeforeYouRedactAnswer, E)] = [
            (.redactAnyway, E(records: true, clearsCase: true, entersRun: true, opensSearch: false, showsPage: nil)),
            (.searchThesePages, E(records: false, clearsCase: true, entersRun: false, opensSearch: true, showsPage: nil)),
            (.cancel, E(records: false, clearsCase: true, entersRun: false, opensSearch: false, showsPage: nil)),
            (.swipedDown, E(records: false, clearsCase: true, entersRun: false, opensSearch: false, showsPage: nil)),
            (.goToPage(2), E(records: false, clearsCase: true, entersRun: false, opensSearch: false, showsPage: 2)),
        ]
        #expect(table.count == 5)
        for (answer, expected) in table {
            #expect(Sheet.effects(of: answer) == expected, "\(answer)")
        }
    }

    @Test("The slot shows the stop only while editing")
    func onlyWhileEditing() {
        let phases: [DocumentState.PhaseKind] =
            [.empty, .importing, .editing, .detecting, .redacting, .verifying, .verified, .exporting, .failed]
        var shown: [(DocumentState.PhaseKind, Bool)] = []
        for phase in phases {
            for awaits in [true, false]
            where DocumentEditorView.sheetSlotShowsStop(stopAwaitsAnswer: awaits, phaseKind: phase) {
                shown.append((phase, awaits))
            }
        }
        #expect(phases.count * 2 == 18)
        #expect(shown.count == 1)
        #expect(shown.first?.0 == .editing && shown.first?.1 == true)
    }

    @Test("The editor counts the stop as presenting, and its Cancel leaves no case awaiting")
    func stopCountsAsPresenting() {
        let coordinator = makeLoadedCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState
        #expect(!DocumentEditorView.editorSlotIsPresenting(documentState: documentState, redactionState: redactionState))
        documentState.redactRefusalAwaitingAnswer = .pagesNotRead([RedactStop.Page(page: 0, reason: .line(.recognitionOff))])
        #expect(DocumentEditorView.editorSlotIsPresenting(documentState: documentState, redactionState: redactionState))
        DocumentEditorView.applyStopAnswer(.cancel, documentState: documentState, redactionState: redactionState,
                                           coordinator: coordinator, documentOverride: nil)
        #expect(documentState.redactRefusalAwaitingAnswer == nil)
        #expect(redactionState.redactStopAnswered.isEmpty)
        #expect(!DocumentEditorView.editorSlotIsPresenting(documentState: documentState, redactionState: redactionState))
    }

    @Test("The stop's height follows its content, and it opens at full height at the accessibility sizes")
    func height() {
        #expect(Sheet.stopSheetDetent(contentHeight: 420, availableHeight: 800, isAccessibilitySize: false) == .height(420))
        #expect(Sheet.stopSheetDetent(contentHeight: 900, availableHeight: 800, isAccessibilitySize: false) == .large)
        #expect(Sheet.stopSheetDetent(contentHeight: 420, availableHeight: 800, isAccessibilitySize: true) == .large)
    }
}

import SwiftUI
import UIKit

// The first-time line in the editor: when it is due and shows
// (`FirstDocumentHintRules`), the first action that ends it, and the line
// drawn in the bottom slot at the brief message's size rule.

extension DocumentEditorView {

    /// The sheets and dialogs over the editor, each from its own source.
    var firstDocumentHintCovers: FirstDocumentHintRules.Covers {
        FirstDocumentHintRules.Covers(
            editorSheet: sheetSlotIsPresenting,
            settings: showSettings,
            password: passwordSheetUp,
            dropReplace: dropDialogUp,
            closeDialog: doneConfirmationPresented.wrappedValue)
    }

    /// Whether the line holds the slot: due, and no message at the slot.
    var firstDocumentHintShows: Bool {
        FirstDocumentHintRules.shows(
            due: FirstDocumentHintRules.isDue(
                done: firstDocumentHintDone, phaseKind: documentState.phaseKind, covers: firstDocumentHintCovers),
            messageAtSlot: toastManager.receiptAtSlot)
    }

    var firstDocumentHintSnapshot: FirstDocumentHintRules.Snapshot {
        FirstDocumentHintRules.Snapshot(
            editing: documentState.phaseKind == .editing,
            covered: firstDocumentHintCovers.any,
            activeTool: activeTool,
            addToSelection: isMultiSelectActive,
            selection: redactionState.selectedRegionIDs,
            regionVersion: redactionState.regionVersion,
            page: documentState.currentPageIndex)
    }

    /// The first action sets the flag, whether or not the line is on screen.
    func firstDocumentHintAct(_ action: FirstDocumentHintRules.Action) {
        guard !firstDocumentHintDone,
              FirstDocumentHintRules.ends(action, voiceOverRunning: UIAccessibility.isVoiceOverRunning)
        else { return }
        FirstDocumentHintStore.standard.markDone()
        firstDocumentHintDone = true
    }

    /// Spoken once, when it first shows, through the queue that speaks
    /// lines one after another.
    func firstDocumentHintShown() {
        guard !firstDocumentHintSpoken else { return }
        firstDocumentHintSpoken = true
        toastManager.announce(FirstDocumentHintWords.spoken)
    }

    /// The line in the slot's place, at the size its rule gives it.
    var firstDocumentHintLine: some View {
        FirstDocumentHintView(personSize: dynamicTypeSize)
            .dynamicTypeSize(FirstDocumentHintView.drawSize(personSize: dynamicTypeSize, canvas: firstDocumentHintCanvas))
            .padding(.bottom, Self.bottomSlotFootPadding + parkedChromeLayout.hintCapsuleLift)
    }
}

/// The editor's observers for the first action: the window's first touch
/// while editing, and the state changes between two updates.
struct FirstDocumentHintObservers: ViewModifier {
    let done: Bool
    let editing: Bool
    let shows: Bool
    let snapshot: FirstDocumentHintRules.Snapshot
    let act: (FirstDocumentHintRules.Action) -> Void
    let shown: () -> Void

    func body(content: Content) -> some View {
        content
            .background {
                if !done && editing {
                    EditorFirstTouchInstaller { act(.touch) }
                }
            }
            .onChange(of: snapshot) { old, new in
                if let action = FirstDocumentHintRules.action(from: old, to: new) { act(action) }
            }
            .onChange(of: shows, initial: true) { _, showing in
                if showing { shown() }
            }
    }
}

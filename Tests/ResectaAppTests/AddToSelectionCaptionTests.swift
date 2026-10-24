import Testing
import Foundation
@testable import ResectaApp

// With Add to Selection on, the canvas's bottom capsule says so — with the
// selection's count once there is one — and carries a Done button that turns
// the mode off. At accessibility sizes the words shorten. The capsule host
// shows one capsule at a time: the drawing caption while the Rectangle tool
// is on, the Add to Selection capsule while that mode is on, only while
// editing.

@Suite("Add to Selection capsule")
struct AddToSelectionCaptionTests {

    @Test("The caption names the mode, then the count")
    func caption() {
        #expect(DocumentEditorView.addModeCaption(selectedCount: 0, accessibilitySize: false)
                == "Adding to selection — tap regions")
        #expect(DocumentEditorView.addModeCaption(selectedCount: 1, accessibilitySize: false)
                == "Adding to selection · 1 selected")
        #expect(DocumentEditorView.addModeCaption(selectedCount: 2, accessibilitySize: false)
                == "Adding to selection · 2 selected")
    }

    @Test("At accessibility sizes the caption shortens")
    func shortCaption() {
        #expect(DocumentEditorView.addModeCaption(selectedCount: 0, accessibilitySize: true) == "Tap regions to add")
        #expect(DocumentEditorView.addModeCaption(selectedCount: 2, accessibilitySize: true) == "2 selected")
    }

    @Test("VoiceOver reads the capsule as one sentence")
    func accessibilityLabel() {
        #expect(DocumentEditorView.addModeAccessibilityLabel(selectedCount: 0)
                == "Adding to selection. Tap regions to add them.")
        #expect(DocumentEditorView.addModeAccessibilityLabel(selectedCount: 2)
                == "Adding to selection, 2 selected")
    }

    @Test("One capsule at a time: the drawing caption for the tool, the Add to Selection capsule for the mode, only while editing")
    func oneCapsule() {
        #expect(DocumentEditorView.bottomCapsule(activeTool: .rectangle, addToSelection: false, phaseKind: .editing)
                == .drawing)
        #expect(DocumentEditorView.bottomCapsule(activeTool: nil, addToSelection: true, phaseKind: .editing)
                == .addToSelection)
        #expect(DocumentEditorView.bottomCapsule(activeTool: nil, addToSelection: false, phaseKind: .editing) == nil)
        #expect(DocumentEditorView.bottomCapsule(activeTool: nil, addToSelection: true, phaseKind: .redacting) == nil)
        #expect(DocumentEditorView.bottomCapsule(activeTool: .rectangle, addToSelection: false, phaseKind: .verified) == nil)
    }
}

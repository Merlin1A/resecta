import Testing
@testable import ResectaApp

// The editor toolbar's accessibility labels. iOS 27 drops a toolbar
// button's accessibility value and hint, so there the label carries them:
// the Rectangle tool's drawing mode, and any non-empty hint after ", ".
// Earlier iOS keeps the plain label; the value and hint say the rest.

@Suite("Editor toolbar accessibility labels")
@MainActor
struct ToolbarAccessibilityLabelTests {

    private var onIOS27: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    @Test("An empty hint leaves the label alone on every iOS")
    func emptyHint() {
        #expect(DocumentEditorToolbar.labelWithHint("Undo", hint: "") == "Undo")
    }

    @Test("A hint follows the label on iOS 27 only")
    func hintFollowsLabel() {
        let hint = DocumentState.RedactRefusal.noRegions.hint
        let label = DocumentEditorToolbar.labelWithHint("Redact", hint: hint)
        #expect(label == (onIOS27 ? "Redact, Draw regions or apply Scan or Search results first" : "Redact"))
    }

    @Test("The Rectangle tool's VoiceOver hint follows its label on iOS 27 only")
    func rectangleUnderVoiceOver() {
        let label = DocumentEditorToolbar.drawToolAccessibilityLabel(active: false, voiceOverRunning: true)
        #expect(label == (onIOS27 ? "Rectangle, Drawing needs direct touch. Use Search or Scan." : "Rectangle"))
    }

    @Test("The Rectangle tool's label carries drawing mode on iOS 27 only")
    func rectangleState() {
        #expect(DocumentEditorToolbar.drawToolAccessibilityLabel(active: false, voiceOverRunning: false) == "Rectangle")
        let on = DocumentEditorToolbar.drawToolAccessibilityLabel(active: true, voiceOverRunning: false)
        #expect(on == (onIOS27 ? "Rectangle, Drawing mode active" : "Rectangle"))
    }
}

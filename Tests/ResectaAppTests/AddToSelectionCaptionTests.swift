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

    private static func occupant(activeTool: DocumentEditorView.DrawingTool?, addToSelection: Bool,
                                 phaseKind: DocumentState.PhaseKind) -> BottomSlotOccupant? {
        DocumentEditorView.bottomSlotOccupant(
            phaseKind: phaseKind, messageShowing: false, selectionNewerThanMessage: false, firstTimeLineDue: false,
            selectedCount: 0, addToSelection: addToSelection, activeTool: activeTool)
    }

    @Test("One capsule at a time: the drawing caption for the tool, the Add to Selection capsule for the mode, only while editing")
    func oneCapsule() {
        #expect(Self.occupant(activeTool: .rectangle, addToSelection: false, phaseKind: .editing)
                == .drawingCaption)
        #expect(Self.occupant(activeTool: nil, addToSelection: true, phaseKind: .editing)
                == .selection(adding: true))
        #expect(Self.occupant(activeTool: nil, addToSelection: false, phaseKind: .editing) == nil)
        #expect(Self.occupant(activeTool: nil, addToSelection: true, phaseKind: .redacting) == nil)
        #expect(Self.occupant(activeTool: .rectangle, addToSelection: false, phaseKind: .verified) == nil)
    }

    @Test("The capsules' text stops growing at Accessibility 1, so a capsule never covers the page")
    func capsuleTextCeiling() {
        #expect(DocumentEditorView.capsuleTypeSizeCeiling == .accessibility1)
    }

    /// A repository file read relative to this test's own path.
    private static func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The slot draws its words in the support grey and Done in the text-tier teal")
    func slotColours() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/DocumentEditorView+Caption.swift")
        #expect(source.contains("ResectaTokens.SemanticColor.supportText"))
        #expect(source.contains("ResectaTokens.BrandTeal.text"))
        #expect(source.contains(".dynamicTypeSize(...Self.capsuleTypeSizeCeiling)"))
        #expect(source.contains("accessibilityIdentifier(\"addModeDoneButton\")"))
        #expect(source.contains("\"Turns off Add to Selection.\""))
        #expect(!source.contains(".foregroundStyle(.secondary)"))
    }
}

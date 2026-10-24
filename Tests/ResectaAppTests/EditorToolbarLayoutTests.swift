import Testing
import SwiftUI
@testable import ResectaApp

// The editor toolbar's layout on iPhone: which controls sit in the bar and
// in which section of the … menu, by text size and undo history. The bar
// holds Undo, Redact and … at the default sizes; at the largest sizes Redact
// folds into the … menu first and Undo never folds. Settings always lives in
// the … menu, after the selection actions and before Home.

@Suite("Editor toolbar layout")
struct EditorToolbarLayoutTests {

    private typealias C = EditorToolbarLayout.Control

    @Test("Default sizes: Undo, Redact and … in the bar; the … menu lists the selection actions, then Switch Mode and Settings, then Home")
    func defaultSizes() {
        for size in [DynamicTypeSize.large, .xLarge, .xxLarge] {
            let layout = EditorToolbarLayout(dynamicTypeSize: size, canUndo: true, canRedo: false)
            #expect(layout.trailing == [C.undo, .redact, .overflow], "at \(size)")
            #expect(layout.overflowSections == [
                [.selectRegions, .addToSelection, .delete, .markWholePage],
                [.switchMode, .settings],
                [.home],
            ], "at \(size)")
        }
    }

    @Test("The largest sizes: Redact folds into the … menu first; Undo stays in the bar")
    func largestSizesFoldRedactFirst() {
        for size in [DynamicTypeSize.xxxLarge, .accessibility1, .accessibility3, .accessibility5] {
            let layout = EditorToolbarLayout(dynamicTypeSize: size, canUndo: true, canRedo: true)
            #expect(layout.trailing == [C.undo, .overflow], "at \(size)")
            #expect(layout.overflowSections[1] == [C.redact, .switchMode, .settings], "at \(size)")
            #expect(layout.overflowSections.flatMap { $0 }.filter { $0 == .undo }.isEmpty,
                    "Undo never folds, at \(size)")
        }
    }

    @Test("Settings is never in the bar")
    func settingsNeverInTheBar() {
        for size in DynamicTypeSize.allCases {
            let layout = EditorToolbarLayout(dynamicTypeSize: size, canUndo: false, canRedo: false)
            #expect(!layout.trailing.contains(.settings), "at \(size)")
            #expect(layout.overflowSections.flatMap { $0 }.contains(.settings), "at \(size)")
        }
    }

    @Test("The Undo control: a tap undoes when there is a step; with only a redo it opens its menu; with neither it is off")
    func undoControlMode() {
        #expect(EditorToolbarLayout(dynamicTypeSize: .large, canUndo: true, canRedo: true).undoMode == .tapUndoesHoldOpensMenu)
        #expect(EditorToolbarLayout(dynamicTypeSize: .large, canUndo: true, canRedo: false).undoMode == .tapUndoesHoldOpensMenu)
        #expect(EditorToolbarLayout(dynamicTypeSize: .large, canUndo: false, canRedo: true).undoMode == .tapOpensMenu)
        #expect(EditorToolbarLayout(dynamicTypeSize: .large, canUndo: false, canRedo: false).undoMode == .unavailable)
    }

    @Test("The Undo control's hint follows its mode")
    func undoHints() {
        #expect(EditorToolbarLayout.undoHint(for: .tapUndoesHoldOpensMenu) == "Touch and hold for Undo and Redo.")
        #expect(EditorToolbarLayout.undoHint(for: .tapOpensMenu) == "Shows Undo and Redo.")
        #expect(EditorToolbarLayout.undoHint(for: .unavailable) == "")
    }

    @Test("The bar leaves no room for the document's name in compact editing, so the inline title is hidden there")
    func inlineTitle() {
        #expect(!EditorToolbarLayout.showsInlineTitle(compact: true, editing: true))
        #expect(EditorToolbarLayout.showsInlineTitle(compact: true, editing: false))
        #expect(EditorToolbarLayout.showsInlineTitle(compact: false, editing: true))
    }
}

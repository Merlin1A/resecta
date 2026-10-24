import SwiftUI

// The editor toolbar's layout on iPhone, as a pure value: which controls sit
// in the bar and in which section of the … menu, by text size and undo
// history. One responsibility; `DocumentEditorToolbar` reads it.
//
// At the default sizes the trailing side is three pieces — the Undo
// control, Redact and the system … — with a fixed spacer between them
// (measured at 390 pt, Large: every control fits in the bar with room to
// spare between the leading group and Undo). At the largest sizes the bar
// cannot hold all three, so Redact folds into the … menu first and Undo
// never folds. Settings always lives in the … menu.

struct EditorToolbarLayout: Equatable {

    /// The controls the layout places.
    enum Control: Hashable {
        case undo, redact, overflow
        case selectRegions, addToSelection, delete, markWholePage
        case switchMode, settings
        case home
    }

    /// How the Undo control answers a tap.
    enum UndoMode: Equatable {
        /// A tap undoes; a touch and hold opens Undo and Redo.
        case tapUndoesHoldOpensMenu
        /// Nothing to undo but something to redo: a tap opens the menu.
        case tapOpensMenu
        /// Nothing either way: the control is off.
        case unavailable
    }

    /// The bar's trailing side, leading to trailing.
    let trailing: [Control]
    /// The … menu's sections, top to bottom.
    let overflowSections: [[Control]]
    let undoMode: UndoMode

    init(dynamicTypeSize: DynamicTypeSize, canUndo: Bool, canRedo: Bool) {
        let redactFolds = dynamicTypeSize >= .xxxLarge
        trailing = redactFolds ? [.undo, .overflow] : [.undo, .redact, .overflow]
        overflowSections = [
            [.selectRegions, .addToSelection, .delete, .markWholePage],
            (redactFolds ? [.redact] : []) + [.switchMode, .settings],
            [.home],
        ]
        undoMode = Self.undoMode(canUndo: canUndo, canRedo: canRedo)
    }

    static func undoMode(canUndo: Bool, canRedo: Bool) -> UndoMode {
        if canUndo { return .tapUndoesHoldOpensMenu }
        return canRedo ? .tapOpensMenu : .unavailable
    }

    /// The Undo control's VoiceOver hint for its mode.
    static func undoHint(for mode: UndoMode) -> String {
        switch mode {
        case .tapUndoesHoldOpensMenu: "Touch and hold for Undo and Redo."
        case .tapOpensMenu: "Shows Undo and Redo."
        case .unavailable: ""
        }
    }

    /// In compact editing the bar leaves the inline title a strip narrower
    /// than any document name (36 pt at 390 pt, Large), so the title is
    /// hidden there rather than drawn clipped.
    static func showsInlineTitle(compact: Bool, editing: Bool) -> Bool {
        !(compact && editing)
    }
}

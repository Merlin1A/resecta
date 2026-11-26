import Foundation

// The first document's line: one stored flag, set by the person's first
// action in the editor, and the pure rules for when the line is due, when it
// shows and what counts as that first action. People who update from an
// earlier version see the line once, on their next document: no earlier key
// records that a document was ever opened.

/// The one stored value: whether the person has acted in the editor.
nonisolated struct FirstDocumentHintStore {
    /// Set by the first action; never cleared outside the test launch.
    static let doneKey = "firstDocumentHint.done.v1"

    let defaults: UserDefaults

    /// The store over the app's own defaults.
    static var standard: FirstDocumentHintStore {
        FirstDocumentHintStore(defaults: .standard)
    }

    var isDone: Bool {
        defaults.bool(forKey: Self.doneKey)
    }

    func markDone() {
        defaults.set(true, forKey: Self.doneKey)
    }

    /// Only the test launch clears it (the DEBUG launch handler in `ResectaApp`).
    func clear() {
        defaults.removeObject(forKey: Self.doneKey)
    }
}

enum FirstDocumentHintRules {

    /// What ends the line: a touch, or one of the editor's state changes.
    enum Action: CaseIterable, Sendable {
        case touch
        case toolChosen
        case addToSelection
        case selectionChanged
        case boxesChanged
        case pageTurned
        case sheetOpened
        case leftEditing
    }

    /// The sheets and dialogs that can be up over the editor.
    struct Covers: Equatable, Sendable {
        /// The editor's own slot: Search, or the canvas's rationale sheet.
        var editorSheet = false
        var settings = false
        /// The password sheet of a locked import.
        var password = false
        /// The dialog for a drop over an open document that holds work.
        var dropReplace = false
        /// The dialog that asks to close the document.
        var closeDialog = false

        var any: Bool {
            editorSheet || settings || password || dropReplace || closeDialog
        }
    }

    /// The editor's state as the first action reads it.
    struct Snapshot: Equatable {
        var editing: Bool
        var covered: Bool
        var activeTool: DocumentEditorView.DrawingTool?
        var addToSelection: Bool
        var selection: Set<UUID>
        var regionVersion: Int
        var page: Int
    }

    /// Due while the flag is unset, the document is being edited and no
    /// sheet or dialog is up.
    static func isDue(done: Bool, phaseKind: DocumentState.PhaseKind, covers: Covers) -> Bool {
        !done && phaseKind == .editing && !covers.any
    }

    /// While it is due it shows, unless a message holds the slot; then it
    /// waits for the message to leave.
    static func shows(due: Bool, messageAtSlot: Bool) -> Bool {
        due && !messageAtSlot
    }

    /// With VoiceOver running a touch is exploring, not acting: only the
    /// state changes count.
    static func ends(_ action: Action, voiceOverRunning: Bool) -> Bool {
        action != .touch || !voiceOverRunning
    }

    /// The state change between two snapshots that counts as an action, if
    /// any. Only a change made while editing counts: a document's arrival
    /// sets the page, the boxes and the tools in the same update that
    /// enters editing, and none of that is the person's doing. Leaving
    /// editing counts, and so does a sheet or dialog coming up.
    static func action(from old: Snapshot, to new: Snapshot) -> Action? {
        guard old.editing else { return nil }
        guard new.editing else { return .leftEditing }
        if !old.covered && new.covered { return .sheetOpened }
        if old.activeTool != new.activeTool { return .toolChosen }
        if old.addToSelection != new.addToSelection { return .addToSelection }
        if old.selection != new.selection { return .selectionChanged }
        if old.regionVersion != new.regionVersion { return .boxesChanged }
        if old.page != new.page { return .pageTurned }
        return nil
    }
}

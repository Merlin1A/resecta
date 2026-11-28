import Foundation

/// The band's notes about the loaded document: whether the person closed
/// each, and the count of files dropped together. One value, so a new
/// document (`ImportService.apply`) and Start Over
/// (`DocumentState.resetForStartOver`) reset them together. Each "closed" is
/// written only by its close control and by those two resets; the count also
/// by a drop's arrival (`RedactWorkspaceView.noteDroppedFiles`).
nonisolated struct LoadNotes: Sendable, Equatable {
    /// The import annotation notice was closed for this document.
    var annotationNoticeDismissed = false
    /// The image note was closed for this document.
    var imagePagesNoteDismissed = false
    /// The note on a password-protected source was closed for this document.
    var sourceProtectionNoteDismissed = false
    /// Files dropped together when only the first was opened; set after that
    /// document arrived; nil once closed.
    var droppedFilesNoteCount: Int?
}

extension DocumentState {
    /// True once the user dismisses the import annotation notice for
    /// the current document. Reset to false on every import.
    var annotationNoticeDismissed: Bool {
        get { loadNotes.annotationNoticeDismissed }
        set { loadNotes.annotationNoticeDismissed = newValue }
    }

    /// True once the user closes the image note for the current document.
    var imagePagesNoteDismissed: Bool {
        get { loadNotes.imagePagesNoteDismissed }
        set { loadNotes.imagePagesNoteDismissed = newValue }
    }

    /// True once the user closes the password-protected source's note for
    /// the current document.
    var sourceProtectionNoteDismissed: Bool {
        get { loadNotes.sourceProtectionNoteDismissed }
        set { loadNotes.sourceProtectionNoteDismissed = newValue }
    }

    /// Files dropped together when only the first was opened; set after that
    /// document arrived; nil once closed.
    var droppedFilesNoteCount: Int? {
        get { loadNotes.droppedFilesNoteCount }
        set { loadNotes.droppedFilesNoteCount = newValue }
    }
}

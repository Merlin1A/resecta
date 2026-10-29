import Foundation

// What the editor's doors read while a run owns the session. A full run
// holds its task from the Redact tap, but the phase reads `.editing`
// until the run-entry capture is done and the run reaches `.redacting`.
// These are the one home for "a run owns the session": Search, Scan, the
// canvas, the iPhone bar, the keyboard and the background pause read them
// by name, never the bare phase.

extension DocumentState {
    /// A run is pending: it holds its task while the phase still reads
    /// `.editing` (the run-entry capture, before `.redacting`).
    var isRunPending: Bool {
        phaseKind == .editing && activePipelineTask != nil
    }

    /// The phase the editor's chrome shows: a pending run reads as
    /// `.redacting`, so the toolbar offers Stop, the progress card covers
    /// the canvas and leaving the app pauses the run from the Redact tap.
    var runChromePhaseKind: PhaseKind {
        isRunPending ? .redacting : phaseKind
    }

    /// Region edits are open: the phase admits them and no run is pending.
    var regionEditsOpen: Bool {
        canMutateRegions && !isRunPending
    }

    /// The canvas is locked: disabled, blurred and under the progress card.
    var canvasLocked: Bool {
        runChromePhaseKind != .editing
    }
}

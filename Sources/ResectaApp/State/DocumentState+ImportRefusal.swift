import Foundation
import RedactionEngine

// The import refusals, moved out of `DocumentState.swift` (a pure move): the
// toast copy for a refused drop, and the refusal read from the phase.
extension DocumentState {

    /// Toast copy for drop/file rejection while the pipeline is
    /// active. Mechanism-description language — names what the app
    /// declined to do plus a recovery hint.
    static let importBlockedDuringPipelineMessage =
        "Cannot import while processing. Try again after the current step finishes."

    /// Toast copy for a drop on the results or error screen, which admit no
    /// import: what the app declined to do plus the way back that screen
    /// offers, by its button's own title.
    static func importBlockedOnThisScreenMessage(wayBack: String) -> String {
        "Cannot import from this screen. Tap \(wayBack) first."
    }

    /// The results screen's way back to the editor.
    static let keepEditingTitle = "Keep Editing"

    /// The message for a refused drop, or nil when the import may start:
    /// the results or error screen, else a run in progress.
    func importRefusal(door: ImportDoor? = nil) -> MessageID? {
        if canStartImport { return nil }
        switch phase {
        case .verified:
            return .importBlockedOnThisScreen(wayBack: Self.keepEditingTitle)
        case .failed(let error, let returnPhase):
            return .importBlockedOnThisScreen(
                wayBack: FailedStateView.primaryActionLabel(
                    FailedStateView.primaryAction(error: error, returnPhase: returnPhase), door: door))
        default:
            return .importBlockedDuringRun
        }
    }

    /// The refused drop's sentence, or nil when the import may start.
    func importRefusalMessage(door: ImportDoor? = nil) -> String? {
        importRefusal(door: door).map { MessageCatalog.row(for: $0).text }
    }

    /// Toast copy for a dropped file that is not a PDF (an image payload,
    /// refused at the drop door). It is the unsupported-format message the
    /// Files import shows, so both refusals read the same words.
    static let importRefusedNotPDFMessage =
        PipelineError.importError(.unsupportedFormat).localizedRecovery
}

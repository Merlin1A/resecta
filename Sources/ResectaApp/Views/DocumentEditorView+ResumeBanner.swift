import SwiftUI
import RedactionEngine

// The paused notice: a run left unfinished when the app went to the
// background. The editor's band (`+TopBanner`) shows it while the pause
// holds and the editor is editing; `documentOverride` forwards to the
// document's state (`+ModeOverride`) and is read from here.

extension DocumentEditorView {

    // MARK: - The paused notice

    /// The paused notice's words.
    static let pausedMessage = "Processing was paused. Your drawn regions are preserved."
    /// The paused notice's action.
    static let pausedRestartLabel = "Restart"

    /// The paused notice's words, from its row.
    var pausedNoticeContent: NoticeContent {
        NoticeContent(id: .pausedRun, closes: true, identifier: "pausedNotice")
    }

    /// The notice the editor shows after a run was paused by a
    /// backgrounding (cancel-from-redacting or -verifying): offers the
    /// pipeline again.
    /// It is a record of a run that did not finish, so neither a timer nor
    /// its leaving the screen ends it: the pause ends when the notice is
    /// closed, when a full run starts (`runFullPipeline`, after its refusal
    /// check), or when the document is closed or replaced. A refused
    /// Restart leaves it up. Shown by the band, only while editing.
    var resumeBannerOverlay: some View {
        NoticeView(
            content: pausedNoticeContent,
            onAction: {
                coordinator.runFullPipeline(documentOverride: documentOverride)
            },
            onClose: {
                Self.clearBackgroundPause(documentState)
            },
            placement: .band
        )
    }

    /// What the notice's close clears: the pause flag and the phase it was
    /// paused from, the same pair a full run's start clears. Left set, the
    /// notice shows again whenever the editor is in `.editing`. Static so
    /// the pin is testable without a SwiftUI host.
    static func clearBackgroundPause(_ documentState: DocumentState) {
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil
    }
}

import Foundation

// The concealing-annotations share confirm's acknowledgement
// (`ConcealingAnnotations`; `DocumentEditorView.shareConfirmKind`). The flag
// is stored on `DocumentState` beside the three share-risk acknowledgements
// and follows their lifetime: `rearmShareRiskConfirms()` re-arms it when the
// user backs out of the share sheet, and a genuinely fresh report resets it
// in `transition(to:)`. No report-side mirror (same as the incomplete-WARN
// flag).
extension DocumentState {

    /// Mark the concealing-annotations line acknowledged for this send
    /// attempt — any confirm family that showed it.
    func acknowledgeConcealedAnnotationsShare() {
        concealedAnnotationsShareAcknowledged = true
    }
}

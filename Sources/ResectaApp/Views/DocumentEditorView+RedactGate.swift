import SwiftUI

// The Redact entry's gate. Disabled means cannot: no region to redact, or
// a run that cannot start. Selected matches not yet applied still refuse
// the run (`DocumentState.redactRefusal(with:)`, the rule the run funnel
// reads, with its notice), but they leave the button available: a tap
// raises the search sheet to where the matches are and the funnel says
// why. The button and its ⇧⌘R share the predicate, the route and the hint.

extension DocumentEditorView {

    /// What a tap on Redact does.
    enum RedactTapRoute: Equatable {
        /// Start the run.
        case run
        /// Raise the search sheet; the funnel refuses with the selections'
        /// notice.
        case raiseSheetAndExplain
    }

    static func redactButtonDisabled(documentState: DocumentState, redactionState: RedactionState) -> Bool {
        !redactionState.hasEffectiveRegions || !documentState.canStartPipeline
    }

    static func redactTapRoute(documentState: DocumentState, redactionState: RedactionState) -> RedactTapRoute {
        documentState.redactRefusal(with: redactionState) == .selectedMatches ? .raiseSheetAndExplain : .run
    }

    var redactButtonDisabled: Bool {
        Self.redactButtonDisabled(documentState: documentState, redactionState: redactionState)
    }

    var redactButtonHint: String {
        documentState.redactRefusal(with: redactionState)?.hint ?? ""
    }
}

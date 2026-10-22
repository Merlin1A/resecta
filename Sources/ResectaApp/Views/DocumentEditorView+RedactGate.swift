import SwiftUI

// The Redact entry's gate: the button and its ⇧⌘R shortcut share one
// `.disabled` predicate and one hint, both read from
// `DocumentState.redactRefusal(with:)` — the rule the run funnel reads too.

extension DocumentEditorView {

    var redactButtonDisabled: Bool {
        documentState.redactRefusal(with: redactionState) != nil
    }

    var redactButtonHint: String {
        documentState.redactRefusal(with: redactionState)?.hint ?? ""
    }
}

import SwiftUI

// The Redact entry's gate: the button and its ⇧⌘R shortcut share one
// `.disabled` predicate and one hint. Pure statics carry the rule so a test
// reads it without a SwiftUI host; the two instance properties bind the
// hub's state to them. The gates: an effective region exists, the
// pipeline-start predicate holds (`DocumentState.canStartPipeline(with:)`),
// and the live search session holds no selections the user has not applied.

extension DocumentEditorView {

    /// The hint while selected matches are unapplied: Redact would tear the
    /// session down and drop them.
    static let selectedMatchesHint = "Apply or clear the selected matches first"

    /// The hint while no region is effective.
    static let noRegionsHint = "Draw regions or apply Scan or Search results first"

    /// True while the live search session holds selections the user has
    /// not applied — touched by hand, or an auto-selected set never
    /// reviewed: the one predicate the sheet's own dismiss gates read.
    static func redactBlockedBySelections(_ search: SearchState?) -> Bool {
        search?.requiresDismissConfirmation ?? false
    }

    /// The `.disabled` predicate: any gate holds.
    static func redactDisabled(
        hasEffectiveRegions: Bool, canStartPipeline: Bool, blockedBySelections: Bool
    ) -> Bool {
        !hasEffectiveRegions || !canStartPipeline || blockedBySelections
    }

    /// The accessibility hint: the selected matches first, then the missing
    /// regions, else none.
    static func redactHint(hasEffectiveRegions: Bool, blockedBySelections: Bool) -> String {
        if blockedBySelections { return selectedMatchesHint }
        return hasEffectiveRegions ? "" : noRegionsHint
    }

    var redactButtonDisabled: Bool {
        Self.redactDisabled(
            hasEffectiveRegions: redactionState.hasEffectiveRegions,
            canStartPipeline: documentState.canStartPipeline(with: redactionState),
            blockedBySelections: Self.redactBlockedBySelections(redactionState.activeSearch))
    }

    var redactButtonHint: String {
        Self.redactHint(
            hasEffectiveRegions: redactionState.hasEffectiveRegions,
            blockedBySelections: Self.redactBlockedBySelections(redactionState.activeSearch))
    }
}

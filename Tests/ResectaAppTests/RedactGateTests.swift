import Testing
import Foundation
@testable import ResectaApp

// The Redact entry's gate (the button and ⇧⌘R share it): no effective
// region, the pipeline-start predicate false, or a live search session
// holding selections the user has not applied — Redact would tear the
// session down and drop them, so it is unavailable with a hint until they
// are applied or cleared. Pure statics; no SwiftUI host.

@Suite("Redact gate", .tags(.search))
@MainActor
struct RedactGateTests {

    @Test("No live session, or an untouched one, does not block Redact")
    func untouchedSessionDoesNotBlock() {
        #expect(!DocumentEditorView.redactBlockedBySelections(nil))
        #expect(!DocumentEditorView.redactBlockedBySelections(SearchState()))
    }

    @Test("Selections the user touched, or an auto-selected set never reviewed, block Redact")
    func pendingSelectionsBlock() {
        let touched = SearchState()
        touched.userModifiedSelections = true
        #expect(DocumentEditorView.redactBlockedBySelections(touched))
        let preselected = SearchState()
        preselected.hasUnreviewedPreselection = true
        #expect(DocumentEditorView.redactBlockedBySelections(preselected))
    }

    @Test("The disabled predicate: every gate holds alone")
    func disabledPredicate() {
        #expect(!DocumentEditorView.redactDisabled(
            hasEffectiveRegions: true, canStartPipeline: true, blockedBySelections: false))
        #expect(DocumentEditorView.redactDisabled(
            hasEffectiveRegions: false, canStartPipeline: true, blockedBySelections: false))
        #expect(DocumentEditorView.redactDisabled(
            hasEffectiveRegions: true, canStartPipeline: false, blockedBySelections: false))
        #expect(DocumentEditorView.redactDisabled(
            hasEffectiveRegions: true, canStartPipeline: true, blockedBySelections: true))
    }

    @Test("The hint names the selected matches first, then the missing regions, else nothing")
    func hint() {
        #expect(DocumentEditorView.redactHint(hasEffectiveRegions: true, blockedBySelections: true)
                == "Apply or clear the selected matches first")
        #expect(DocumentEditorView.redactHint(hasEffectiveRegions: false, blockedBySelections: true)
                == "Apply or clear the selected matches first")
        #expect(DocumentEditorView.redactHint(hasEffectiveRegions: false, blockedBySelections: false)
                == "Draw regions or apply Scan or Search results first")
        #expect(DocumentEditorView.redactHint(hasEffectiveRegions: true, blockedBySelections: false) == "")
    }
}

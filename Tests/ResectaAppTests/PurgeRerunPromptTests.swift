import Testing
import SwiftUI
import Foundation
import RedactionEngine
@testable import ResectaApp

// Package E (quality-pass-2026-05) — KI-4 proactive purge re-run prompt.
//
// The scene-phase observer in DocumentEditorView surfaces a `.warning`
// toast when iOS reclaims the pipeline's temp output PDF while the app
// is backgrounded. The observer's gate is factored into
// `DocumentEditorView.shouldShowPurgeRerunToast(...)` so the conditions
// are testable without a SwiftUI host. The toast copy is pinned at
// `DocumentEditorView.purgeRerunToastMessage`.
//
// Contract pinned here:
// 1. Fires on `.background → .active` only — not on `.inactive → .active`.
// 2. Fires only when the editor is on `.verified(report)`.
// 3. Fires only when the output file does NOT exist (purge happened).
// 4. Mechanism-description copy (no banned vocabulary from ARCH §1.3).

@Suite("KI-4 proactive purge re-run toast (Package E)")
@MainActor
struct PurgeRerunPromptTests {

    // Reusable verified-phase fixture. The report contents are irrelevant
    // to the gate — only the case discriminator matters.
    private var verifiedPhase: DocumentState.Phase {
        .verified(report: .skipped)
    }

    // MARK: - Transition gate

    @Test("Fires on .background → .active")
    func firesOnBackgroundToActive() {
        #expect(DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: .background,
            newPhase: .active,
            documentPhase: verifiedPhase,
            outputFileExists: false
        ) == true)
    }

    @Test("Does NOT fire on .inactive → .active (app-switcher / control center)")
    func doesNotFireOnInactiveToActive() {
        #expect(DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: .inactive,
            newPhase: .active,
            documentPhase: verifiedPhase,
            outputFileExists: false
        ) == false)
    }

    @Test("Does NOT fire on .background → .inactive (mid-resume)")
    func doesNotFireOnBackgroundToInactive() {
        #expect(DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: .background,
            newPhase: .inactive,
            documentPhase: verifiedPhase,
            outputFileExists: false
        ) == false)
    }

    @Test("Does NOT fire on .active → .background (leaving foreground)")
    func doesNotFireOnActiveToBackground() {
        #expect(DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: .active,
            newPhase: .background,
            documentPhase: verifiedPhase,
            outputFileExists: false
        ) == false)
    }

    // MARK: - Phase gate

    @Test("Does NOT fire when phase is .editing")
    func doesNotFireOutsideVerified_editing() {
        #expect(DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: .background,
            newPhase: .active,
            documentPhase: .editing,
            outputFileExists: false
        ) == false)
    }

    @Test("Does NOT fire when phase is .empty")
    func doesNotFireOutsideVerified_empty() {
        #expect(DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: .background,
            newPhase: .active,
            documentPhase: .empty,
            outputFileExists: false
        ) == false)
    }

    @Test("Does NOT fire when phase is .failed")
    func doesNotFireOutsideVerified_failed() {
        let phase: DocumentState.Phase = .failed(
            error: .exportError(.filePurged),
            returnPhase: .empty
        )
        #expect(DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: .background,
            newPhase: .active,
            documentPhase: phase,
            outputFileExists: false
        ) == false)
    }

    // MARK: - File-existence gate

    @Test("Does NOT fire when output file still exists")
    func doesNotFireWhenOutputPresent() {
        #expect(DocumentEditorView.shouldShowPurgeRerunToast(
            oldPhase: .background,
            newPhase: .active,
            documentPhase: verifiedPhase,
            outputFileExists: true
        ) == false)
    }

    // MARK: - Toast copy contract

    @Test("Toast copy names the mechanism and the action")
    func toastCopyMechanismAndAction() {
        let msg = DocumentEditorView.purgeRerunToastMessage
        // Mechanism named ("reclaimed", "in the background").
        #expect(msg.contains("reclaimed"))
        #expect(msg.localizedCaseInsensitiveContains("background"))
        // Action named ("Re-run").
        #expect(msg.contains("Re-run"))
    }

    @Test("Toast copy avoids ARCH §1.3 / §19 banned vocabulary")
    func toastCopyBannedVocabulary() {
        let msg = DocumentEditorView.purgeRerunToastMessage.lowercased()
        // Outcome-promise vocabulary banned by ARCH §1.3 and the audit-lint
        // M-1 regex. Mirrors the safer pattern enforced upstream. Each
        // sentinel string carries the `LegalPhrases:safe` override marker
        // so the M-1 scanner accepts these test-only literals.
        #expect(!msg.contains("guarantee"))   // LegalPhrases:safe
        #expect(!msg.contains("ensure"))      // LegalPhrases:safe
        #expect(!msg.contains("impossible"))  // LegalPhrases:safe
        #expect(!msg.contains("perfectly"))   // LegalPhrases:safe
        #expect(!msg.contains("flawlessly"))  // LegalPhrases:safe
        #expect(!msg.contains("100%"))        // LegalPhrases:safe
    }
}

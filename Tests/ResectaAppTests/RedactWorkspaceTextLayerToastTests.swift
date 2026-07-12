import Testing
import Foundation
@testable import ResectaApp

// CAT-278 (C-J2) — the text-layer toast must fire once per import, on the
// import-completion transition (.importing -> .editing), for EVERY import path.
// Original gap: the Home -> redact load (AppCoordinator.openRedactWithDocument)
// runs its import AFTER the workspace view mounts, so the in-view post-import
// calls never covered it. Centralizing on the phase transition covers all paths;
// these pin the transition rule — pipeline returns to .editing and import
// failures must NOT re-fire the toast.

@Suite("Text-layer toast import-completion gate (CAT-278)")
@MainActor
struct RedactWorkspaceTextLayerToastTests {

    @Test("fires on import completion (.importing -> .editing)")
    func firesOnImportCompletion() {
        #expect(RedactWorkspaceView.shouldCheckTextLayerOnImportCompletion(
            from: .importing, to: .editing) == true)
    }

    @Test("does not fire on pipeline returns to .editing")
    func doesNotFireOnPipelineReturn() {
        #expect(RedactWorkspaceView.shouldCheckTextLayerOnImportCompletion(
            from: .detecting, to: .editing) == false)
        #expect(RedactWorkspaceView.shouldCheckTextLayerOnImportCompletion(
            from: .redacting, to: .editing) == false)
        #expect(RedactWorkspaceView.shouldCheckTextLayerOnImportCompletion(
            from: .verifying, to: .editing) == false)
        #expect(RedactWorkspaceView.shouldCheckTextLayerOnImportCompletion(
            from: .verified, to: .editing) == false)
    }

    @Test("does not fire on import failure or non-editing targets")
    func doesNotFireOnFailureOrOtherTargets() {
        #expect(RedactWorkspaceView.shouldCheckTextLayerOnImportCompletion(
            from: .importing, to: .failed) == false)
        #expect(RedactWorkspaceView.shouldCheckTextLayerOnImportCompletion(
            from: .empty, to: .editing) == false)
        #expect(RedactWorkspaceView.shouldCheckTextLayerOnImportCompletion(
            from: .importing, to: .importing) == false)
    }
}

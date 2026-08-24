import Testing
import Foundation
@testable import ResectaApp

// 1.1.0 Home swap (UXC-41) — the iPhone editor overflow menu's Home entry (in place
// of the former file-import entry) closes the document through the
// verification-screen Done path: `performDoneCloseSession()` behind the
// shared "Close this document?" dialog. Two pure seams are pinned here
// without a SwiftUI host:
//
//  1. `homeNeedsCloseConfirm(hasDrawnRegions:hasPendingTriage:)` — the
//     confirm gate: drawn/applied regions (Done's GATE-3 gate) OR a staged
//     Scan review awaiting the user. Neither → Home closes directly.
//  2. `closeDialogMessage(phaseKind:)` — the shared dialog's message: the
//     `.verified` literal stays byte-identical to the GATE-3 copy pinned by
//     `VerificationActionBarDoneConfirmationTests`; every other phase reads
//     the D12 Replace dialog's second sentence, byte-identical to the
//     literal in `RedactWorkspaceView.swift` (asserted by value against the
//     source file — the string is deliberately NOT hoisted across files).

@Suite("Document editor Home close (1.1.0 Home swap, UXC-41)")
@MainActor
struct DocumentEditorHomeCloseTests {

    // MARK: - Confirm gate truth table

    @Test("No regions, no pending review → Home closes directly")
    func noWorkClosesDirectly() {
        #expect(DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: false, hasPendingTriage: false) == false)
    }

    @Test("Drawn regions alone → confirm")
    func regionsAloneConfirm() {
        #expect(DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: true, hasPendingTriage: false) == true)
    }

    @Test("Pending review alone → confirm")
    func pendingReviewAloneConfirms() {
        #expect(DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: false, hasPendingTriage: true) == true)
    }

    @Test("Regions and a pending review → confirm")
    func bothConfirm() {
        #expect(DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: true, hasPendingTriage: true) == true)
    }

    // MARK: - Dialog message

    @Test(".verified keeps the pinned GATE-3 verification-results literal")
    func verifiedMessageIsPinnedLiteral() {
        #expect(DocumentEditorView.closeDialogMessage(phaseKind: .verified)
                == "Drawn regions and verification results will be cleared.")
    }

    @Test("Every other phase reads the detection-results sentence")
    func otherPhasesReadDetectionSentence() {
        let expected = "Drawn regions and detection results will be cleared."
        let others: [DocumentState.PhaseKind] = [
            .empty, .importing, .editing, .detecting,
            .redacting, .verifying, .exporting, .failed,
        ]
        for phase in others {
            #expect(DocumentEditorView.closeDialogMessage(phaseKind: phase) == expected,
                    "phase \(phase) must read the detection-results sentence")
        }
    }

    @Test("The editing message is byte-identical to the D12 Replace dialog sentence in RedactWorkspaceView")
    func editingMessageMatchesD12Literal() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/RedactWorkspaceView.swift")
        let sentence = DocumentEditorView.closeDialogMessage(phaseKind: .editing)
        #expect(
            source.contains("Importing a new file will replace the current document. \(sentence)\""),
            "RedactWorkspaceView's D12 Replace message must end with the exact sentence the Home close dialog reads"
        )
    }

    /// Mirrors `HonestySurfacesTests.loadRepoFile`.
    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}

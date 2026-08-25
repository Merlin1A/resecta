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

    // MARK: - REV-05 route (RB-85): a presented sheet parks before the dialog

    @Test("REV-05: no confirm owed → close directly, sheet presented or not")
    func noConfirmClosesDirectlyRegardlessOfSheet() {
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: false, sheetPresented: false)
                == .closeDirectly)
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: false, sheetPresented: true)
                == .closeDirectly)
    }

    @Test("REV-05: confirm owed with the sheet slot idle → the dialog")
    func confirmWithIdleSlotPresentsDialog() {
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: true, sheetPresented: false)
                == .presentDialog)
    }

    @Test("REV-05: confirm owed while the slot presents → park the sheet, dialog from onDismiss")
    func confirmWithPresentedSheetParksFirst() {
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: true, sheetPresented: true)
                == .parkSheetThenDialog)
    }

    @Test("REV-05: a parked review re-presents only while still pending, with the slot idle, in an editing session")
    func parkedReviewRepresentGate() {
        #expect(DocumentEditorView.homeCloseShouldRepresentReview(
            parkedReview: true, hasPendingTriage: true, sheetPresented: false, phaseKind: .editing))
        #expect(!DocumentEditorView.homeCloseShouldRepresentReview(
            parkedReview: false, hasPendingTriage: true, sheetPresented: false, phaseKind: .editing),
                "nothing was parked")
        #expect(!DocumentEditorView.homeCloseShouldRepresentReview(
            parkedReview: true, hasPendingTriage: false, sheetPresented: false, phaseKind: .editing),
                "the staged set is gone (Close ran clearAll)")
        #expect(!DocumentEditorView.homeCloseShouldRepresentReview(
            parkedReview: true, hasPendingTriage: true, sheetPresented: true, phaseKind: .editing),
                "a sheet is already up")
        let notEditing: [DocumentState.PhaseKind] = [
            .empty, .importing, .detecting, .redacting,
            .verifying, .verified, .exporting, .failed,
        ]
        for phase in notEditing {
            #expect(!DocumentEditorView.homeCloseShouldRepresentReview(
                parkedReview: true, hasPendingTriage: true, sheetPresented: false, phaseKind: phase),
                    "phase \(phase) is not an editing session")
        }
    }

    @Test("REV-05 wiring: the sheet slot hands off to the dialog on dismissal, the dialog presents through the restoring binding, Close drops the parked state (source pin)")
    func rev05WiringSourcePin() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        guard let slot = source.range(of: ".sheet(item: Binding<ActiveSheet?>("),
              let content = source.range(of: ") { sheet in",
                                         range: slot.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate the editor sheet slot")
            return
        }
        let slotCall = source[slot.upperBound..<content.lowerBound]
        #expect(slotCall.contains("onDismiss: {"), "the sheet slot must carry the onDismiss hand-off")
        #expect(slotCall.contains("guard homeCloseAwaitsSheetDismissal else { return }"))
        #expect(slotCall.contains("showDoneConfirmation = true"))

        #expect(source.contains("isPresented: doneConfirmationPresented,"),
                "the close dialog must present through doneConfirmationPresented")
        #expect(!source.contains("isPresented: $showDoneConfirmation"),
                "no direct $showDoneConfirmation presentation may remain")

        guard let close = source.range(of: "private func performDoneCloseSession() {"),
              let sec1 = source.range(of: "coordinator.downgradeTempProtectionOnSessionClose()",
                                      range: close.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate performDoneCloseSession")
            return
        }
        let prologue = source[close.upperBound..<sec1.lowerBound]
        #expect(prologue.contains("homeCloseAwaitsSheetDismissal = false"))
        #expect(prologue.contains("homeCloseParkedReview = false"))
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

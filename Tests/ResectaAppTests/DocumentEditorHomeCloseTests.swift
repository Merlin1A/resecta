import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine
import CoreGraphics

// The 1.1.0 Home swap — the iPhone editor overflow menu's Home entry (in place
// of the former file-import entry) closes the document through the
// verification-screen Done path: `performDoneCloseSession()` behind the
// shared "Close this document?" dialog. Two pure seams are pinned here
// without a SwiftUI host:
//
//  1. `homeNeedsCloseConfirm(hasDrawnRegions:hasUnappliedSelections:)`
//     — the confirm gate: drawn/applied regions (Done's own confirm gate)
//     or search selections not yet applied. None → Home closes directly.
//  2. `closeDialogMessage(phaseKind:)` — the shared dialog's message: the
//     `.verified` literal stays byte-identical to the copy pinned by
//     `VerificationActionBarDoneConfirmationTests`; every other phase reads
//     the detection-results sentence.

@Suite("Document editor Home close (1.1.0 Home swap)")
@MainActor
struct DocumentEditorHomeCloseTests {

    // MARK: - Confirm gate truth table

    @Test("No regions, nothing unapplied → Home closes directly")
    func noWorkClosesDirectly() {
        #expect(DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: false, hasUnappliedSelections: false) == false)
    }

    @Test("Drawn regions alone → confirm")
    func regionsAloneConfirm() {
        #expect(DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: true, hasUnappliedSelections: false) == true)
    }

    @Test("Unapplied search selections alone → confirm")
    func unappliedSelectionsAloneConfirm() {
        #expect(DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: false, hasUnappliedSelections: true) == true)
    }

    @Test("Home reads the selections rule Redact reads: touched selections owe a confirm, an untouched search does not")
    func homeReadsTheSelectionsRule() {
        let redactionState = RedactionState()
        #expect(DocumentState.hasUnappliedSelections(redactionState) == false)
        let untouched = SearchState(defaults: makeScratchDefaults().0)
        redactionState.activeSearch = untouched
        #expect(DocumentState.hasUnappliedSelections(redactionState) == false)
        let touched = SearchState(defaults: makeScratchDefaults().0)
        touched.userModifiedSelections = true
        touched.results = [SearchResult(
            pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha", contextSnippet: "…alpha…", source: .textLayer, term: "alpha", isSelected: true)]
        redactionState.activeSearch = touched
        let needsConfirm = DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: false, hasUnappliedSelections: DocumentState.hasUnappliedSelections(redactionState))
        #expect(needsConfirm)
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: needsConfirm, sheetPresented: true)
                == .parkSheetThenDialog)
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: needsConfirm, sheetPresented: false)
                == .presentDialog)
    }

    // MARK: - Dialog message

    @Test(".verified keeps the pinned verification-results literal")
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


    // MARK: - A presented sheet parks before the dialog

    @Test("No confirm owed → close directly, sheet presented or not")
    func noConfirmClosesDirectlyRegardlessOfSheet() {
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: false, sheetPresented: false)
                == .closeDirectly)
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: false, sheetPresented: true)
                == .closeDirectly)
    }

    @Test("Confirm owed with the sheet slot idle → the dialog")
    func confirmWithIdleSlotPresentsDialog() {
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: true, sheetPresented: false)
                == .presentDialog)
    }

    @Test("Confirm owed while the slot presents → park the sheet, dialog from onDismiss")
    func confirmWithPresentedSheetParksFirst() {
        #expect(DocumentEditorView.homeCloseRoute(needsConfirm: true, sheetPresented: true)
                == .parkSheetThenDialog)
    }

    @Test("Wiring: the sheet slot hands off to the dialog on dismissal, the dialog presents through the restoring binding, Close drops the parked state (source pin)")
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

        // The teardown lives in the Home extension file (internal there:
        // the hub's dialog and the extension's Home route both call it).
        let home = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView+Home.swift")
        guard let close = home.range(of: "func performDoneCloseSession() {"),
              let sec1 = home.range(of: "documentState.resetForStartOver(",
                                    range: close.upperBound..<home.endIndex)
        else {
            Issue.record("Could not locate performDoneCloseSession")
            return
        }
        let prologue = home[close.upperBound..<sec1.lowerBound]
        #expect(prologue.contains("homeCloseAwaitsSheetDismissal = false"))
    }

    // MARK: - Done / Home close through the one reset

    @Test("The Done/Home teardown cancels first, then runs the one reset and hand-copies no field (source pin)")
    func doneCloseUsesTheOneReset() throws {
        let home = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView+Home.swift")
        guard let close = home.range(of: "func performDoneCloseSession() {"),
              let end = home.range(of: "\n    }\n", range: close.upperBound..<home.endIndex)
        else {
            Issue.record("Could not locate performDoneCloseSession")
            return
        }
        let body = home[close.upperBound..<end.lowerBound]
        let cancel = try #require(body.range(of: "documentState.cancelActivePipeline(redactionState: redactionState)"))
        let reset = try #require(body.range(of:
            "documentState.resetForStartOver(redactionState: redactionState, coordinator: coordinator)"))
        #expect(cancel.lowerBound < reset.lowerBound, "cancel comes first")
        #expect(!body.contains("documentState.sourceDocument = nil"), "no hand copy of the reset")
        #expect(!body.contains("transition(to: .empty)"), "the reset makes the exit transition")
    }

    @Test("The one reset clears the import notice's form-field count with the rest")
    func resetClearsFormFieldCount() {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.phase = .editing
        coord.documentState.sourceFilledFormFieldCount = 3
        coord.documentState.resetForStartOver(
            redactionState: coord.redactionState, coordinator: coord)
        #expect(coord.documentState.sourceFilledFormFieldCount == 0)
        #expect(coord.documentState.phaseKind == .empty)
    }

    // MARK: - A parked search session comes back on Cancel

    @Test("A parked search session re-presents only with the slot idle in an editing session")
    func parkedSearchRestoreGate() {
        #expect(DocumentEditorView.homeCloseShouldRestoreSearch(sheetPresented: false, phaseKind: .editing, sameDocument: true))
        #expect(!DocumentEditorView.homeCloseShouldRestoreSearch(sheetPresented: true, phaseKind: .editing, sameDocument: true),
                "a sheet is already up")
        #expect(!DocumentEditorView.homeCloseShouldRestoreSearch(sheetPresented: false, phaseKind: .editing, sameDocument: false),
                "the document was replaced behind the dialog: the parked results name the old one's pages")
        let notEditing: [DocumentState.PhaseKind] = [
            .empty, .importing, .detecting, .redacting,
            .verifying, .verified, .exporting, .failed,
        ]
        for phase in notEditing {
            #expect(!DocumentEditorView.homeCloseShouldRestoreSearch(sheetPresented: false, phaseKind: phase, sameDocument: true),
                    "phase \(phase) is not an editing session")
        }
    }

    @Test("Wiring: the park keeps the session whole, Cancel's binding restores it, Close drops it, the sheet's teardown spares it (source pin)")
    func parkedSearchWiringSourcePin() throws {
        let home = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView+Home.swift")
        #expect(home.contains("parkedEditorSearch = search"), "the park keeps the session")
        #expect(home.contains("func restoreParkedSearchIfNeeded()"))
        #expect(home.contains("redactionState.activeSearch = parked"), "Cancel re-presents the same session")
        let binding = try #require(home.range(of: "var doneConfirmationPresented: Binding<Bool> {"))
        #expect(home[binding.upperBound...].contains("restoreParkedSearchIfNeeded()"),
                "the dialog's binding restores it")
        let close = try #require(home.range(of: "func performDoneCloseSession() {"))
        let reset = try #require(home.range(of: "documentState.resetForStartOver(", range: close.upperBound..<home.endIndex))
        #expect(home[close.upperBound..<reset.lowerBound].contains("parkedEditorSearch = nil"), "Close drops it")
        let hub = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        #expect(hub.contains("@State var parkedEditorSearch: SearchState?"))
        let sheet = try loadRepoFile("Sources/ResectaApp/Views/SearchAndRedactSheet.swift")
        #expect(sheet.contains("parkedForHomeClose"), "the sheet's teardown spares a parked session")
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

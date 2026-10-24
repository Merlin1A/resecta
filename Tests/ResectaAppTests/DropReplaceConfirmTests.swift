import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// A document dropped over an open one that holds work — drawn regions or
// selected matches not yet applied — asks before replacing it, with the
// Close dialog's own rule and sentence. Cancel keeps the open document;
// Replace imports the dropped one. A drop over an editor holding no work
// replaces at once, as before. While the editor's sheet is up the dialog
// cannot present over it, so such a drop is refused with the import gate's
// sentence and the open document is kept.

@MainActor
@Suite("Drop over an open document")
struct DropReplaceConfirmTests {

    private static func makeWorkspace(_ name: String) -> RedactWorkspace {
        let defaults = UserDefaults(suiteName: "DropReplaceConfirmTests.\(name)")!
        defaults.removePersistentDomain(forName: "DropReplaceConfirmTests.\(name)")
        let termsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-replace-\(UUID().uuidString).json")
        return RedactWorkspace(
            settingsState: SettingsState(defaults: defaults),
            userTermsStore: UserTermsStore(fileURL: termsURL, legacyDefaults: defaults))
    }

    /// An editing workspace with a two-page document open.
    private static func editingWorkspace(_ name: String) -> RedactWorkspace {
        let workspace = makeWorkspace(name)
        workspace.documentState.sourceDocument = makeMultiPagePDFDocument(pages: 2)
        workspace.documentState.phase = .editing
        return workspace
    }

    private static func box() -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05),
                        source: .manual)
    }

    private static func touchedSearch() -> SearchState {
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.results = [SearchResult(
            pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha", contextSnippet: "…alpha…", source: .textLayer, term: "alpha", isSelected: true)]
        return search
    }

    // MARK: - The rule

    @Test("The confirm is owed exactly when the Close dialog's is: a region, or selections not yet applied")
    func confirmReadsTheCloseRule() {
        let workspace = Self.editingWorkspace("rule")
        let documentState = workspace.documentState
        let redactionState = workspace.redactionState
        #expect(!RedactWorkspaceView.dropNeedsConfirm(documentState: documentState, redactionState: redactionState))
        redactionState.addRegion(Self.box(), page: 1, undoManager: nil)
        #expect(RedactWorkspaceView.dropNeedsConfirm(documentState: documentState, redactionState: redactionState))

        let selecting = Self.editingWorkspace("rule-selections")
        selecting.redactionState.activeSearch = Self.touchedSearch()
        #expect(RedactWorkspaceView.dropNeedsConfirm(
            documentState: selecting.documentState, redactionState: selecting.redactionState))
    }

    @Test("No open document owes no confirm")
    func noDocumentNoConfirm() {
        let workspace = Self.makeWorkspace("empty")
        #expect(!RedactWorkspaceView.dropNeedsConfirm(
            documentState: workspace.documentState, redactionState: workspace.redactionState))
        #expect(RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil) == .importNow)
    }

    // MARK: - The door

    @Test("At the door: work held → confirm; no work → import at once; the gate's refusals stand")
    func admission() {
        let workspace = Self.editingWorkspace("admission")
        #expect(RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil) == .importNow)
        workspace.redactionState.addRegion(Self.box(), page: 0, undoManager: nil)
        #expect(RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil) == .confirmReplace)
        workspace.documentState.phase = .verified(report: .skipped)
        let gate = workspace.documentState.importRefusalMessage(door: nil)
        #expect(gate != nil)
        #expect(RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil)
                == .refuse(gate ?? ""))
    }

    @Test("With the editor's sheet up, a drop that owes the confirm is refused with the import gate's sentence")
    func sheetUpRefuses() {
        let workspace = Self.editingWorkspace("sheet")
        workspace.redactionState.activeSearch = Self.touchedSearch()
        guard case .refuse(let message) = RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil)
        else {
            Issue.record("a drop over the presented sheet must be refused")
            return
        }
        #expect(message == RedactWorkspaceView.dropOverSheetMessage)
        #expect(message.hasPrefix("Cannot import from this screen."))
    }

    // MARK: - The dialog's words

    @Test("The dialog asks with the deleted replace dialog's words and the Close dialog's sentence")
    func dialogWords() {
        #expect(RedactWorkspaceView.dropReplaceTitle == "Replace the open document?")
        #expect(RedactWorkspaceView.dropReplaceButton == "Replace")
        #expect(RedactWorkspaceView.dropReplaceMessage == DocumentEditorView.closeDialogMessage(phaseKind: .editing))
    }

    // MARK: - Cancel and Replace, through the real objects

    @Test("Cancel keeps the open document and its regions; Replace imports the dropped document")
    func cancelKeepsReplaceImports() async throws {
        let workspace = Self.editingWorkspace("replace")
        let original = try #require(workspace.documentState.sourceDocument)
        workspace.redactionState.addRegion(Self.box(), page: 0, undoManager: nil)
        let dropped = DroppedDocument(payload: .bytes(try #require(makeMultiPagePDFDocument(pages: 3).dataRepresentation())))
        #expect(RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil) == .confirmReplace)

        // The door holds the drop for the dialog: until Replace, and on
        // Cancel, the open document and its regions are untouched.
        #expect(workspace.documentState.sourceDocument === original)
        #expect(workspace.redactionState.regions[0]?.count == 1)

        // Replace: the held drop is imported through the drop door.
        await RedactWorkspaceView.importDrop(dropped, workspace: workspace)
        #expect(workspace.documentState.sourceDocument !== original)
        #expect(workspace.documentState.pageCount == 3)
        #expect((workspace.redactionState.regions[0] ?? []).isEmpty)
    }
}

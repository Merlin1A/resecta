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
        let gate = workspace.documentState.importRefusal(door: nil)
        #expect(gate != nil)
        #expect(RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil)
                == gate.map(RedactWorkspaceView.DropAdmission.refuse))
    }

    @Test("With the editor's sheet up, a drop that owes the confirm is refused with the import gate's sentence")
    func sheetUpRefuses() {
        let workspace = Self.editingWorkspace("sheet")
        workspace.redactionState.activeSearch = Self.touchedSearch()
        guard case .refuse(let id) = RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil)
        else {
            Issue.record("a drop over the presented sheet must be refused")
            return
        }
        #expect(id == RedactWorkspaceView.dropOverSheetRefusal)
        #expect(MessageCatalog.row(for: id).text.hasPrefix("Cannot import from this screen."))
    }

    @Test("A drop refused over the stop at Redact names its Cancel")
    func stopRefusalNamesCancel() {
        #expect(RedactWorkspaceView.dropOverStopRefusal == .importBlockedOnThisScreen(wayBack: "Cancel"))
        #expect(DocumentState.importBlockedOnThisScreenMessage(wayBack: BeforeYouRedactSheet.cancelTitle)
                == "Cannot import from this screen. Tap Cancel first.")
    }

    @Test("With the stop at Redact up, a drop that owes the confirm is refused, not asked")
    func stopUpRefuses() {
        let workspace = Self.editingWorkspace("stop")
        workspace.redactionState.regions[0] = [Self.box()]
        workspace.documentState.redactRefusalAwaitingAnswer =
            .pagesNotRead([RedactStop.Page(page: 1, reason: .line(.recognitionOff))])
        #expect(workspace.redactionState.activeSearch == nil)
        guard case .refuse(let id) = RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil)
        else {
            Issue.record("a drop over the stop at Redact must be refused")
            return
        }
        #expect(id == RedactWorkspaceView.dropOverStopRefusal)
        workspace.documentState.redactRefusalAwaitingAnswer = nil
        #expect(RedactWorkspaceView.dropAdmission(
            documentState: workspace.documentState, redactionState: workspace.redactionState, door: nil) == .confirmReplace)
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

    // MARK: - The dropped-files note

    /// One page, encrypted with a user and an owner password.
    private static func lockedPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let aux: [CFString: Any] = [kCGPDFContextUserPassword: "user", kCGPDFContextOwnerPassword: "owner"]
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!,
                            mediaBox: &box, aux as CFDictionary)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 72, y: 72, width: 100, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    @Test("A drop of several files raises its note after the new document arrives, and only then")
    func droppedFilesNoteOnArrival() async throws {
        let pdf = try #require(makeMultiPagePDFDocument(pages: 3).dataRepresentation())

        // Three files dropped: the first opens, and the note holds the count.
        let three = Self.makeWorkspace("dropped-three")
        await RedactWorkspaceView.importDrop(DroppedDocument(payload: .bytes(pdf)), droppedCount: 3, workspace: three)
        #expect(three.documentState.pageCount == 3)
        #expect(three.documentState.droppedFilesNoteCount == 3)

        // One file: no note.
        let one = Self.makeWorkspace("dropped-one")
        await RedactWorkspaceView.importDrop(DroppedDocument(payload: .bytes(pdf)), droppedCount: 1, workspace: one)
        #expect(one.documentState.pageCount == 3)
        #expect(one.documentState.droppedFilesNoteCount == nil)

        // Bytes that are not a document, over an open document holding a
        // note of 2: nothing arrived, so the open document's note stands.
        let open = Self.editingWorkspace("dropped-refused")
        open.documentState.droppedFilesNoteCount = 2
        await RedactWorkspaceView.importDrop(DroppedDocument(payload: .bytes(Data("not a document".utf8))),
                                             droppedCount: 3, workspace: open)
        #expect(open.documentState.droppedFilesNoteCount == 2)

        // A locked document: no note yet; the hold carries the count to the
        // password's arrival.
        let locked = Self.makeWorkspace("dropped-locked")
        await RedactWorkspaceView.importDrop(DroppedDocument(payload: .bytes(Self.lockedPDF())),
                                             droppedCount: 3, workspace: locked)
        #expect(locked.documentState.droppedFilesNoteCount == nil)
        #expect(locked.lockedImport?.droppedCount == 3)
    }
}

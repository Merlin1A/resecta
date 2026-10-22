import Testing
import Foundation
import PDFKit
@testable import ResectaApp

// The import-completion toasts (the text-layer notice, the encrypted-source
// line) fire once per import, when a new document is loaded, for EVERY
// import path. Original gap: the Home -> redact load
// (AppCoordinator.openRedactWithDocument) runs its import AFTER the workspace
// view mounts, so the in-view post-import calls never covered it. Keying on
// the document swap covers all paths; a cancelled import over an open
// document, an import failure and a pipeline returning to the editor leave
// the document as it was and must NOT re-fire the toasts.

@Suite("Import-completion toast gate")
@MainActor
struct RedactWorkspaceTextLayerToastTests {

    @Test("fires when a document arrives in an empty workspace")
    func firesOnFirstImport() {
        #expect(RedactWorkspaceView.isDocumentSwap(from: nil, to: makeTestPDFDocument()))
    }

    @Test("fires when a new document replaces the open one")
    func firesOnReplacement() {
        #expect(RedactWorkspaceView.isDocumentSwap(from: makeTestPDFDocument(), to: makeTestPDFDocument()))
    }

    @Test("does not fire when the open document stays — a cancelled import over it, or a pipeline return")
    func doesNotFireWhenTheDocumentStays() {
        let open = makeTestPDFDocument()
        #expect(!RedactWorkspaceView.isDocumentSwap(from: open, to: open))
    }

    @Test("does not fire when the document is closed")
    func doesNotFireOnClose() {
        #expect(!RedactWorkspaceView.isDocumentSwap(from: makeTestPDFDocument(), to: nil))
        #expect(!RedactWorkspaceView.isDocumentSwap(from: nil, to: nil))
    }
}

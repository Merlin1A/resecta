import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// The editor's link policy: link annotations inside an imported document
// are not followed, and data detectors are off. The coordinator is the
// PDFView's delegate; its link hook does nothing. The end-to-end pin (a
// tap on a link annotation leaves the app in front and does not launch
// Safari, with the drawing tool off and on) is DocumentLinkUITests.

@Suite("Document link policy")
@MainActor
struct DocumentLinkPolicyTests {

    @Test("The coordinator becomes the view's delegate and implements the link hook")
    func coordinatorIsDelegateAndImplementsLinkHook() {
        let coordinator = PDFViewCoordinator()
        let pdfView = PDFView()

        coordinator.applyLinkPolicy(to: pdfView)

        #expect(pdfView.delegate as AnyObject === coordinator,
                "PDFKit follows link annotations itself unless a delegate is installed")
        // PDFKit only consults the delegate for a link when the optional
        // method is actually implemented; an inherited default would not do.
        #expect(coordinator.responds(to: #selector(PDFViewDelegate.pdfViewWillClick(onLink:with:))))
    }

    @Test("Data detectors are off for every document the coordinator assigns")
    func dataDetectorsAreOffAfterAssignment() throws {
        let coordinator = PDFViewCoordinator()
        let pdfView = PDFView()
        coordinator.applyLinkPolicy(to: pdfView)

        let first = try #require(PDFDocument(data: makeTestPDFData()))
        coordinator.assign(first, to: pdfView)
        #expect(pdfView.document === first)
        #expect(pdfView.enableDataDetectors == false)
        #expect(pdfView.delegate as AnyObject === coordinator)

        // A second document (the updateUIView path after a new import)
        // arrives with its own default and is pinned the same way.
        let second = try #require(PDFDocument(data: makeTestPDFData()))
        coordinator.assign(second, to: pdfView)
        #expect(pdfView.document === second)
        #expect(pdfView.enableDataDetectors == false)

        // The view property reads the current document's flag: putting
        // the first document back reads the value written for it.
        coordinator.assign(first, to: pdfView)
        #expect(pdfView.enableDataDetectors == false)
    }

    @Test("The coordinator's assignment turns detectors off whatever a direct assignment left")
    func coordinatorAssignmentOverridesDirectAssignment() throws {
        let pdfView = PDFView()
        let document = try #require(PDFDocument(data: makeTestPDFData()))

        // A direct assignment leaves the document at PDFKit's own default
        // (measured ON on iOS 26.4; the platform's to change, so not
        // asserted here). The coordinator's assignment is the app's pin.
        pdfView.document = document
        PDFViewCoordinator().assign(document, to: pdfView)
        #expect(pdfView.enableDataDetectors == false)
    }

    @Test("The link hook does nothing: no crash, document and redaction state untouched")
    func linkHookIsInert() {
        let coordinator = PDFViewCoordinator()
        let documentState = DocumentState()
        let redactionState = RedactionState()
        coordinator.documentState = documentState
        coordinator.redactionState = redactionState
        documentState.sourceDocument = PDFDocument(data: makeTestPDFData())
        documentState.phase = .editing
        documentState.currentPageIndex = 0
        redactionState.addRegion(
            RedactionRegion(id: UUID(),
                normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
                source: .manual),
            page: 0, undoManager: nil)
        redactionState.selectedRegionIDs = []

        let phaseBefore = documentState.phaseKind
        let pageBefore = documentState.currentPageIndex
        let regionVersionBefore = redactionState.regionVersion
        let regionCountBefore = redactionState.regions.values.reduce(0) { $0 + $1.count }
        let selectionBefore = redactionState.selectedRegionIDs

        let pdfView = PDFView()
        coordinator.applyLinkPolicy(to: pdfView)
        coordinator.assign(documentState.sourceDocument, to: pdfView)
        coordinator.pdfViewWillClick(onLink: pdfView, with: URL(string: "http://link.invalid/")!)

        #expect(documentState.phaseKind == phaseBefore)
        #expect(documentState.currentPageIndex == pageBefore)
        #expect(documentState.sourceDocument != nil)
        #expect(redactionState.regionVersion == regionVersionBefore)
        #expect(redactionState.regions.values.reduce(0) { $0 + $1.count } == regionCountBefore)
        #expect(redactionState.selectedRegionIDs == selectionBefore)
    }
}

import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §5.1–§5.2: Import validation and loading tests.

@Suite("ImportService", .tags(.importFlow))
@MainActor
struct ImportServiceTests {

    // MARK: - Successful Import

    @Test("Valid PDF data transitions to editing")
    func validPDFTransitionsToEditing() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        let pdfData = makeTestPDFData()

        await ImportService.importDocument(
            data: pdfData, suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceDocument != nil)
    }

    @Test("Import sets currentPageIndex to zero")
    func importSetsCurrentPageToZero() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makeTestPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.currentPageIndex == 0)
    }

    @Test("Import clears lastUsedPipelineMode")
    func importClearsLastUsedPipelineMode() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing
        doc.lastUsedPipelineMode = .secureRasterization

        await ImportService.importDocument(
            data: makeTestPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.lastUsedPipelineMode == nil)
    }

    @Test("Import clears old regions")
    func importClearsOldRegions() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // Pre-populate regions
        redaction.addRegion(
            RedactionRegion(id: UUID(),
                normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
                source: .manual),
            page: 0, undoManager: nil)

        doc.phase = .editing
        await ImportService.importDocument(
            data: makeTestPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(redaction.regions.isEmpty || redaction.regions.values.allSatisfy { $0.isEmpty })
    }

    @Test("Multi-page PDF sets correct page count")
    func multiPagePDFSetsCorrectPageCount() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makeMultiPagePDFData(pages: 3), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.pageCount == 3)
    }

    @Test("Import detects text layer per page")
    func importDetectsTextLayerPerPage() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makeTextPDFData(text: "Hello World sensitive content here"),
            suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        // Text layer status should be populated for each page
        #expect(doc.textLayerStatus.count == doc.pageCount)
    }

    @Test("Image import has no text layer status entries")
    func imageImportHasNoTextLayerStatus() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makeJPEGImageData(), suggestedType: "jpg",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(doc.textLayerStatus.isEmpty)
    }

    // MARK: - Image Import

    @Test("JPEG image data converts to single-page PDF")
    func jpegImageConvertsToSinglePagePDF() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makeJPEGImageData(), suggestedType: "jpg",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(doc.pageCount == 1)
    }

    @Test("PNG image data converts to single-page PDF")
    func pngImageConvertsToSinglePagePDF() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makePNGImageData(), suggestedType: "png",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(doc.pageCount == 1)
    }

    // MARK: - Validation Failures

    @Test("Corrupt data transitions to failed")
    func corruptDataTransitionsToFailed() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])

        await ImportService.importDocument(
            data: garbage, suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .failed)
    }

    @Test("Too-large data transitions to failed with tooLarge error")
    func tooLargeDataTransitionsToFailed() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // 51 MB — exceeds the 50 MB limit in ImportService
        let oversized = Data(count: 51 * 1024 * 1024)

        await ImportService.importDocument(
            data: oversized, suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .failed)
        if case .failed(let error, _) = doc.phase {
            if case .importError(.tooLarge) = error {
                // Expected
            } else {
                Issue.record("Expected .importError(.tooLarge), got \(error)")
            }
        }
    }

    @Test("Unsupported format transitions to failed")
    func unsupportedFormatTransitionsToFailed() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // Valid data but not an image or PDF
        let textData = Data("Hello, world!".utf8)

        await ImportService.importDocument(
            data: textData, suggestedType: "txt",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .failed)
    }

    @Test("PDF magic bytes override suggestedType")
    func magicBytesOverridesSuggestedType() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        let pdfData = makeTestPDFData()

        // Pass suggestedType as "txt" but data starts with %PDF
        await ImportService.importDocument(
            data: pdfData, suggestedType: "txt",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing, "PDF magic bytes should override suggestedType")
    }

    // MARK: - Return Phase

    @Test("Import from editing uses editing return phase on failure")
    func importFromEditingUsesEditingReturnPhase() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing // Already in editing

        await ImportService.importDocument(
            data: Data([0xDE, 0xAD]), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        if case .failed(_, let returnPhase) = doc.phase {
            if case .editing = returnPhase {
                // Expected
            } else {
                Issue.record("Expected .editing return phase, got \(returnPhase)")
            }
        } else {
            Issue.record("Expected .failed phase")
        }
    }

    @Test("Import from empty uses empty return phase on failure")
    func importFromEmptyUsesEmptyReturnPhase() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // Default phase is .empty

        await ImportService.importDocument(
            data: Data([0xDE, 0xAD]), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        if case .failed(_, let returnPhase) = doc.phase {
            if case .empty = returnPhase {
                // Expected
            } else {
                Issue.record("Expected .empty return phase, got \(returnPhase)")
            }
        } else {
            Issue.record("Expected .failed phase")
        }
    }

    @Test("Over-500-page PDF rejected as too large")
    func tooManyPagesRejected() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        let data = makeMultiPagePDFData(pages: 501)

        await ImportService.importDocument(
            data: data, suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .failed)
        if case .failed(let error, _) = doc.phase {
            if case .importError(.tooLarge) = error {
                // Expected — page count exceeds 500
            } else {
                Issue.record("Expected .importError(.tooLarge), got \(error)")
            }
        }
    }

    @Test("Oversized image rejected with invalidPageDimensions")
    func oversizedImageRejected() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // Create an image with one dimension exceeding 5000
        let size = CGSize(width: 5001, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let data = renderer.jpegData(withCompressionQuality: 0.5) { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        await ImportService.importDocument(
            data: data, suggestedType: "jpg",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .failed)
        if case .failed(let error, _) = doc.phase {
            if case .importError(.invalidPageDimensions) = error {
                // Expected
            } else {
                Issue.record("Expected .importError(.invalidPageDimensions), got \(error)")
            }
        }
    }

    @Test("Import preserves old document until validation succeeds")
    func importPreservesOldStateUntilValidation() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        // Load a valid document first
        await ImportService.importDocument(
            data: makeTestPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)
        let originalDocument = doc.sourceDocument
        #expect(originalDocument != nil)

        // Attempt to load corrupt data — original document should be preserved
        // because clearForNewDocument only runs after validation passes
        await ImportService.importDocument(
            data: Data([0xDE, 0xAD]), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .failed)
        // Source document is still the original one
        #expect(doc.sourceDocument === originalDocument)
    }

    // MARK: - CAT-274 / CAT-402 / CAT-403: import clears stale review state

    /// A successful import runs `clearForNewDocument()`, which must drop the
    /// prior document's pending detection-review state so a replacement never
    /// inherits triage selections (wrong-coordinate stamping — CAT-274), a
    /// stale degraded banner (CAT-402), or a blank rationale sheet (CAT-403).
    @Test("Import clears pending triage, selections, degraded flag, rationale request")
    func testImportClearsPendingTriage() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing
        // Stale review state left over from a prior document.
        redaction.pendingTriage = [0: [DetectionResult.mock()]]
        redaction.triageSelections = [UUID(): true]
        redaction.autoDetectionDegraded = true
        redaction.pendingCanvasRationaleRequest = UUID()

        await ImportService.importDocument(
            data: makeTestPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(redaction.pendingTriage == nil)                  // CAT-274
        #expect(redaction.triageSelections.isEmpty)              // CAT-274
        #expect(redaction.autoDetectionDegraded == false)        // CAT-402
        #expect(redaction.pendingCanvasRationaleRequest == nil)  // CAT-403
    }

    /// The drag-drop import path consults the composed `canStartImport(with:)`
    /// gate (the file/photo pickers stage the D12 confirmation instead). The
    /// gate must reject while a detection review is pending, while leaving the
    /// document-only `canStartImport` property ignorant of `RedactionState`.
    @Test("Drop-path import gate rejects while a detection review is pending")
    func testDropHandlerRejectsDuringTriage() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing

        // No triage → admitted.
        #expect(doc.canStartImport(with: redaction) == true)

        // Pending triage → rejected; document-only gate stays true (ignorant).
        redaction.pendingTriage = [0: [DetectionResult.mock()]]
        #expect(doc.canStartImport(with: redaction) == false)
        #expect(doc.canStartImport == true)

        // A phase that forbids import → rejected regardless of triage.
        redaction.pendingTriage = nil
        doc.phase = .importing
        #expect(doc.canStartImport(with: redaction) == false)
    }
}

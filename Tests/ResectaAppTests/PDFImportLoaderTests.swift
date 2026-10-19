import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// The PDF loader driven as a pure function: bytes in, a parsed document
// plus its facts out, or a throw from the existing import-failure
// taxonomy. No DocumentState or RedactionState is in scope.

@Suite("PDF import loader", .tags(.importFlow))
struct PDFImportLoaderTests {

    private func load(
        _ data: Data,
        limits: ImportLimits = .standard,
        door: ImportDoor = .files
    ) async throws -> LoadedDocument {
        try await PDFImportLoader().load(
            .bytes(data, declaredType: "pdf", door: door), password: nil, limits: limits)
    }

    /// The import failure a load threw, spelled the way the cases are, or
    /// "none" when the load succeeded.
    private func refusalName(_ data: Data, limits: ImportLimits = .standard) async -> String {
        do {
            _ = try await load(data, limits: limits)
            return "none"
        } catch let error as PipelineError {
            if case .importError(let failure) = error {
                return String(describing: failure)
            }
            return "other"
        } catch {
            return "other"
        }
    }

    /// A one-page PDF whose page is `size` points.
    private func makePDFData(pageSize size: CGSize) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { ctx in
            ctx.beginPage()
        }
    }

    // MARK: - Facts

    @Test("A text PDF yields its document and facts")
    func textPDFYieldsFacts() async throws {
        let loaded = try await load(makeTextPDFData(text: "Hello loader"))
        #expect(loaded.document.document.pageCount == 1)
        #expect(loaded.facts.origin == .pdf)
        #expect(loaded.facts.textLayerStatus.count == 1)
        #expect(loaded.facts.hasHiddenOCG == false)
        #expect(loaded.facts.annotationFindings.isEmpty)
        #expect(loaded.facts.filledFormFieldCount == 0)
        #expect(loaded.facts.wasEncrypted == false)
        #expect(loaded.facts.hadRestrictions == false)
        #expect(loaded.facts.summary
                == ImportFacts.Summary(origin: .pdf, wasEncrypted: false, hadRestrictions: false))
    }

    @Test("A multi-page PDF reports one text-layer status per page")
    func multiPageStatusPerPage() async throws {
        let loaded = try await load(makeMultiPagePDFData(pages: 3))
        #expect(loaded.document.document.pageCount == 3)
        #expect(loaded.facts.textLayerStatus.count == 3)
    }

    // MARK: - Refusals, in the stage order

    @Test("Bytes PDFKit cannot open are refused as corrupt")
    func garbageIsCorrupt() async {
        #expect(await refusalName(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])) == "corrupt")
    }

    @Test("A page count past the cap is refused as too large")
    func pageCountPastTheCap() async {
        // The production cap, then a smaller cap on a small fixture.
        #expect(await refusalName(makeMultiPagePDFData(pages: 501)).hasPrefix("tooLarge"))
        let threePages = makeMultiPagePDFData(pages: 3)
        #expect(await refusalName(threePages, limits: ImportLimits(maxPages: 2)).hasPrefix("tooLarge"))
        #expect(await refusalName(threePages, limits: ImportLimits(maxPages: 3)) == "none")
    }

    @Test("A page side past the cap is refused as invalid page dimensions")
    func pageSidePastTheCap() async {
        let wide = makePDFData(pageSize: CGSize(width: 5_001, height: 100))
        #expect(await refusalName(wide) == "invalidPageDimensions(pageIndex: 0)")
        // A letter page under a smaller cap.
        let letter = makePDFData(pageSize: CGSize(width: 612, height: 792))
        #expect(await refusalName(letter, limits: ImportLimits(maxPagePoints: 500))
                == "invalidPageDimensions(pageIndex: 0)")
        #expect(await refusalName(letter) == "none")
    }

    // MARK: - The caps

    @Test("The standard limits are the production caps")
    func standardLimits() {
        #expect(ImportLimits.standard.maxBytes == 50 * 1024 * 1024)
        #expect(ImportLimits.standard.maxPages == 500)
        #expect(ImportLimits.standard.maxPagePoints == 5_000)
        #expect(ImportLimits() == ImportLimits.standard)
    }
}

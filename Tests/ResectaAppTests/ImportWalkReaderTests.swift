import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The import's walk reader — the raw bytes through CoreGraphics — driven as
// a function of the bytes, and the two import outcomes that depend on it.
// A reader that cannot open, cannot unlock, reads no catalog or disagrees
// with PDFKit on the page count refuses the import: the walks would answer
// "clean" for what they could not see.

@Suite("Import walk reader", .tags(.importFlow))
@MainActor
struct ImportWalkReaderTests {

    // MARK: - Fixtures

    /// One page with a filled box, encrypted with the given passwords.
    private static func encryptedPDF(_ aux: [CFString: Any]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!,
                            mediaBox: &box, aux as CFDictionary)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 72, y: 72, width: 100, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static var ownerOnly: [CFString: Any] { [kCGPDFContextOwnerPassword: "owner"] }
    private static var userAndOwner: [CFString: Any] {
        [kCGPDFContextUserPassword: "user", kCGPDFContextOwnerPassword: "owner"]
    }

    /// Raw bytes whose trailer points at a catalog object the file never
    /// defines, with the xref offsets computed in bytes.
    private static func catalogless() -> Data {
        var body = "%PDF-1.4\n"
        var offsets: [Int: Int] = [:]
        let objects: [(Int, String)] = [
            (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>"),
            (4, "<< /Length 0 >>\nstream\n\nendstream"),
        ]
        for (id, content) in objects {
            offsets[id] = body.utf8.count
            body += "\(id) 0 obj\n\(content)\nendobj\n\n"
        }
        let xrefOffset = body.utf8.count
        var xref = "xref\n0 5\n0000000000 65535 f \n"
        for id in 1...4 {
            if let offset = offsets[id] {
                xref += String(format: "%010d 00000 n \n", offset)
            } else {
                xref += "0000000000 00000 f \n"
            }
        }
        body += xref + "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(body.utf8)
    }

    /// The import failure a call threw, spelled the way the cases are, or
    /// "none" / "other".
    private func refusalName(_ body: () throws -> Bool) -> String {
        do {
            _ = try body()
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

    private func readerFacts(_ data: Data) -> String {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return "no document" }
        return "isEncrypted=\(document.isEncrypted) isUnlocked=\(document.isUnlocked) catalog=\(document.catalog != nil) pages=\(document.numberOfPages)"
    }

    // MARK: - The reader stage on its own

    @Test("Bytes CoreGraphics cannot open are refused as corrupt")
    func unopenableBytesRefused() {
        #expect(refusalName {
            try ImportService.inspectWalkReader(
                data: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03]), expectedPageCount: 1)
        } == "corrupt")
    }

    @Test("A user-password document is refused at the reader as corrupt")
    func userPasswordDocumentRefusedAtTheReader() {
        let data = Self.encryptedPDF(Self.userAndOwner)
        print("[walk reader] user+owner: \(readerFacts(data))")
        #expect(refusalName { try ImportService.inspectWalkReader(data: data, expectedPageCount: 1) } == "corrupt")
    }

    @Test("A catalog-less document is refused at the reader as corrupt")
    func cataloglessDocumentRefusedAtTheReader() {
        let data = Self.catalogless()
        print("[walk reader] catalog-less: \(readerFacts(data))")
        #expect(refusalName { try ImportService.inspectWalkReader(data: data, expectedPageCount: 1) } == "corrupt")
    }

    @Test("A page count the reader disagrees on is refused as corrupt")
    func pageCountDisagreementRefused() {
        #expect(refusalName {
            try ImportService.inspectWalkReader(data: makeTestPDFData(), expectedPageCount: 2)
        } == "corrupt")
        #expect(refusalName {
            try ImportService.inspectWalkReader(data: makeTestPDFData(), expectedPageCount: 1)
        } == "none")
    }

    // MARK: - Through the import

    @Test("An owner-password-only document still imports and records the encrypted source")
    func ownerOnlyDocumentStillImports() async throws {
        let data = Self.encryptedPDF(Self.ownerOnly)
        print("[walk reader] owner-only: \(readerFacts(data))")
        let loaded = try await PDFImportLoader().load(
            .bytes(data, declaredType: "pdf", door: .files), limits: .standard)
        #expect(loaded.facts.wasEncrypted == true)
        #expect(loaded.document.document.pageCount == 1)

        let doc = DocumentState()
        let redaction = RedactionState()
        let outcome = await ImportService.importDocument(
            data: data, suggestedType: "pdf", documentState: doc, redactionState: redaction)
        #expect(outcome == .completed)
        #expect(doc.phaseKind == .editing)
    }

    @Test("A user-password document is refused as password-protected before the reader runs")
    func userPasswordDocumentRefusedAsPasswordProtected() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        let outcome = await ImportService.importDocument(
            data: Self.encryptedPDF(Self.userAndOwner), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)
        #expect(outcome == .refused)
        if case .failed(let error, _) = doc.phase {
            if case .importError(.passwordProtected) = error {
                // Expected: PDFKit's lock gate fires first.
            } else {
                Issue.record("Expected .importError(.passwordProtected), got \(error)")
            }
        } else {
            Issue.record("Expected .failed phase")
        }
    }

    @Test("A catalog-less document is refused through the import")
    func cataloglessDocumentRefusedThroughTheImport() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        let outcome = await ImportService.importDocument(
            data: Self.catalogless(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)
        #expect(outcome == .refused)
        #expect(doc.sourceDocument == nil)
    }
}

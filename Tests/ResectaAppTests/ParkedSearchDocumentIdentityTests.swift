import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The identity a parked search session is matched against on restore: the
// document state's per-import token, not the object's address — once the
// old document is freed, a new document can take the same address. The
// fixture frees a document and allocates replacements until one lands on
// the freed address (it usually does within a few tries); the rule under
// test is that a different document never reads as the parked one.

@Suite("A parked search session's document identity")
@MainActor
struct ParkedSearchDocumentIdentityTests {

    private func pdfData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
            ctx.beginPage()
            ("Parked" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
    }

    @Test("A new document at the freed document's address does not read as the parked one")
    func freedAddressReuseDoesNotMatch() throws {
        let data = pdfData()
        let documentState = DocumentState()
        documentState.sourceDocument = try #require(PDFDocument(data: data))
        let oldAddress = ObjectIdentifier(documentState.sourceDocument!)
        let parked = documentState.sourceDocumentToken   // what the park records
        documentState.sourceDocument = nil

        var reused = false
        for _ in 0..<500 {
            documentState.sourceDocument = PDFDocument(data: data)
            if ObjectIdentifier(documentState.sourceDocument!) == oldAddress { reused = true; break }
        }
        // Whether or not the allocator handed the address back, the new
        // document carries a new token and never reads as the parked one.
        #expect(documentState.sourceDocumentToken != parked,
                reused ? "the freed address was reused and the token still tells the documents apart" : "a different document, a different token")
    }

    @Test("The token changes with the document, not with a re-assignment of the same one")
    func tokenFollowsTheDocument() throws {
        let documentState = DocumentState()
        let first = try #require(PDFDocument(data: pdfData()))
        documentState.sourceDocument = first
        let token = documentState.sourceDocumentToken
        documentState.sourceDocument = first
        #expect(documentState.sourceDocumentToken == token, "the same document keeps its token")
        documentState.sourceDocument = PDFDocument(data: pdfData())
        #expect(documentState.sourceDocumentToken != token, "a new document gets a new token")
        documentState.sourceDocument = nil
        #expect(documentState.sourceDocumentToken != token, "no document is not the old one")
    }
}

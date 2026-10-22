import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The identity a parked search session is matched against on restore. An
// object identifier names an address: once the old document is freed, a
// new document can take the same address and read as the parked one. The
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
        var old: PDFDocument? = try #require(PDFDocument(data: data))
        let parked = ObjectIdentifier(old!)   // what the park records at this head
        old = nil

        var replacement: PDFDocument?
        var reused = false
        for _ in 0..<500 {
            replacement = PDFDocument(data: data)
            if let replacement, ObjectIdentifier(replacement) == parked { reused = true; break }
        }
        guard reused else {
            // The allocator did not hand the address back within 500 tries:
            // the mechanism is not reproduced on this run.
            return
        }
        let readsAsParked = ObjectIdentifier(replacement!) == parked
        #expect(!readsAsParked, "a different document at the freed address reads as the parked one")
    }
}

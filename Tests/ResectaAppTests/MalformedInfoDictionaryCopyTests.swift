import Foundation
import PDFKit
import RedactionEngine
import Testing
@testable import ResectaApp

// The per-consumer search copy (`DocumentState.makeSearchCopy`) writes the
// live document out and reads it back. A file whose `/Info` dictionary
// carries keys PDFKit cannot turn into strings opens and passes import, but
// that write raises an Objective-C exception Swift cannot intercept — the app
// aborted the first time such a document was searched. The copy now runs
// the write through the engine's guard and returns nil, which the search
// path already reports as a mechanism toast. The fixture is the 165-byte
// minimised reproduction from the seeded import drivers (the engine's
// `MalformedInfoDictionaryTests` pins the same bytes).
@Suite("Malformed /Info dictionary — the search copy")
struct MalformedInfoDictionaryCopyTests {
    static let malformedInfoPDF = Data(base64Encoded:
        "JVBERi0KMSAwIG9iajw8Ly8vUGFyZW50IDIgMCBSLyA0IDAgUi8gMz4+CjIgMCBvYmo8PC9bXS9Db3VudCAxL0tpZHNbMSAwIFJdPj4K"
        + "OCAwIG9iajw8Ly8vUGFnZXMgMiAwIFI+Pgo5IDAgb2JqPDwvKCkvxCgnKT4+CnRyYWlsZXI8PC8gMi9Sb290IDggMCBSL0luZm8gOSAwIFIvWzw+XT4+")!

    @Test("The search copy of a document with an unreadable /Info key is nil, not a crash")
    func searchCopyIsNil() throws {
        let doc = try #require(PDFDocument(data: Self.malformedInfoPDF))
        #expect(DocumentState.makeSearchCopy(of: SendablePDFDocument(doc)) == nil)
    }
}

import Foundation
import PDFKit
import PDFKitGuard
import Testing
@testable import RedactionEngine

// A PDF whose `/Info` dictionary carries keys PDFKit cannot turn into
// strings (an empty name and an unreadable one) opens in PDFKit, but writing
// it back out — `dataRepresentation()` — raises an Objective-C exception
// that Swift cannot intercept, and the process aborts. The verification data
// loader's non-file fallback is that write. These pin the guard: the
// document reads as "could not load", nothing aborts.
//
// The 165-byte file is the minimised reproduction from the seeded import
// drivers (sha256 56a3b175…1da4bc1): `trailer<</Root 8 0 R/Info 9 0 R>>`
// with `9 0 obj<</()/\xC4(')>>`. Before the guard, every test in this file
// crashed the test runner instead of failing.
@Suite("Malformed /Info dictionary — the guarded data representation")
struct MalformedInfoDictionaryTests {
    static let malformedInfoPDF = Data(base64Encoded:
        "JVBERi0KMSAwIG9iajw8Ly8vUGFyZW50IDIgMCBSLyA0IDAgUi8gMz4+CjIgMCBvYmo8PC9bXS9Db3VudCAxL0tpZHNbMSAwIFJdPj4K"
        + "OCAwIG9iajw8Ly8vUGFnZXMgMiAwIFI+Pgo5IDAgb2JqPDwvKCkvxCgnKT4+CnRyYWlsZXI8PC8gMi9Sb290IDggMCBSL0luZm8gOSAwIFIvWzw+XT4+")!

    @Test("The fixture is the 165-byte reproduction and PDFKit opens it")
    func fixtureOpens() throws {
        #expect(Self.malformedInfoPDF.count == 165)
        let doc = try #require(PDFDocument(data: Self.malformedInfoPDF))
        #expect(doc.documentURL == nil, "a data-backed document takes the non-file fallback")
    }

    @Test("The guarded write returns nil instead of raising")
    func guardedWriteReturnsNil() throws {
        let doc = try #require(PDFDocument(data: Self.malformedInfoPDF))
        #expect(RSGuardedDataRepresentation(doc) == nil)
    }

    @Test("The guarded write still returns the bytes of a well-formed document")
    func guardedWriteReturnsBytes() throws {
        let page = PDFPage()
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let data = try #require(RSGuardedDataRepresentation(doc))
        #expect(data.starts(with: Array("%PDF".utf8)))
        #expect(PDFDocument(data: data)?.pageCount == 1)
    }

    @Test("The verification data loader reads the document as could-not-load")
    func loaderReturnsNil() throws {
        let doc = try #require(PDFDocument(data: Self.malformedInfoPDF))
        #expect(VerificationEngine().loadPDFData(doc) == nil)
    }
}

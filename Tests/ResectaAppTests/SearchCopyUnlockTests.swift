import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The search copy of a document that was unlocked with a password. The
// bytes PDFKit emits for an unlocked 128-bit (R3/R4) document are still
// encrypted, so the copy opens locked and would read no text: it is unlocked
// with the session's password, and a copy that stays locked is an error
// (nil → the "could not prepare" toast), never zero matches. A 256-bit (R6)
// document's bytes come out decrypted.

@Suite("Search copy of an unlocked document", .tags(.importFlow))
struct SearchCopyUnlockTests {

    static func bytes(_ name: String) throws -> Data {
        try Data(contentsOf: ImportLockedDocumentTests.directory.appendingPathComponent(name))
    }

    private func unlocked(_ name: String) throws -> SendablePDFDocument {
        let doc = try #require(PDFDocument(data: try Self.bytes(name)))
        #expect(doc.unlock(withPassword: "user"))
        return SendablePDFDocument(doc)
    }

    @Test("A 128-bit document's copy stays locked without the password: the copy is an error, not an empty search",
          arguments: ["r3-rc4-128.pdf", "r4-aes-128.pdf"])
    func lockedCopyWithoutPasswordIsNil(name: String) throws {
        let source = try unlocked(name)
        let bare = try #require(DocumentState.makeSearchCopy(of: source))
        #expect(bare.document.isLocked, "the emitted bytes keep their encryption")
        #expect(SearchCopy.make(of: source, unlockingWith: DocumentPasswordHolder()) == nil)
    }

    @Test("With the session's password the copy opens and reads the text",
          arguments: ["r3-rc4-128.pdf", "r4-aes-128.pdf"])
    func copyOpensWithThePassword(name: String) throws {
        let holder = DocumentPasswordHolder()
        holder.set("user")
        let copy = try #require(SearchCopy.make(of: try unlocked(name), unlockingWith: holder))
        #expect(!copy.document.isLocked)
        #expect(copy.document.page(at: 0)?.string?.contains("ENCRYPTED SEED 7731") == true)
    }

    @Test("A 256-bit document's copy comes out decrypted and needs no password")
    func aes256CopyIsDecrypted() throws {
        let copy = try #require(SearchCopy.make(of: try unlocked("r6-aes-256.pdf"), unlockingWith: DocumentPasswordHolder()))
        #expect(!copy.document.isLocked)
        #expect(!copy.document.isEncrypted)
        #expect(copy.document.page(at: 0)?.string?.contains("ENCRYPTED SEED 7731") == true)
    }

    @Test("A plain document's copy is untouched by the holder")
    func plainCopy() throws {
        let holder = DocumentPasswordHolder()
        holder.set("unused")
        let source = SendablePDFDocument(try #require(PDFDocument(data: makeTextPDFData(text: "Plain copy"))))
        let copy = try #require(SearchCopy.make(of: source, unlockingWith: holder))
        #expect(copy.document.page(at: 0)?.string?.contains("Plain copy") == true)
    }

    @Test("A wrong password in the holder leaves the copy locked: nil")
    func wrongPasswordLeavesNil() throws {
        let holder = DocumentPasswordHolder()
        holder.set("wrong")
        #expect(SearchCopy.make(of: try unlocked("r4-aes-128.pdf"), unlockingWith: holder) == nil)
    }
}

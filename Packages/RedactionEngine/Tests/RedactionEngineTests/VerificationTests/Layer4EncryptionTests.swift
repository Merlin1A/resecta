import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// Layer 4 and an encrypted output. `/Encrypt` sits in the file trailer, never
// in the document catalog, so the structural check reads the document's
// encryption state itself: an encrypted output FAILs whether or not it opens
// without a password (an owner password alone leaves it readable by anyone,
// with its permissions and its encryption dictionary intact). The writer
// never encrypts; a file that is encrypted did not come from it.

@Suite("Layer 4: encrypted output", .tags(.security))
struct Layer4EncryptionTests {

    /// One page with a filled box; the auxiliary dictionary carries the
    /// passwords.
    private static func pdf(_ aux: [CFString: Any]) -> Data {
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

    /// Layer 4 on a document opened by URL (the verification path reads the
    /// file's own bytes).
    private func layer4(_ data: Data) async throws -> LayerResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("l4_encrypt_\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        return await layer4(doc)
    }

    private func layer4(_ doc: PDFDocument) async -> LayerResult {
        let engine = VerificationEngine()
        return await engine.runLayer(
            .structureCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: doc.pageCount, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: Array(repeating: nil, count: doc.pageCount),
            perPageModes: Array(repeating: .secureRasterization, count: doc.pageCount),
            appliedSearches: [])
    }

    private func message(_ r: LayerResult) -> String {
        switch r.status {
        case .fail(let m), .warn(let m), .info(let m), .attention(let m): m
        case .pass, .skipped: ""
        }
    }

    @Test("An owner-password-only output (opens without a password) FAILs Layer 4")
    func ownerPasswordOnlyFails() async throws {
        let r = try await layer4(Self.pdf(Self.ownerOnly))
        #expect(r.status.isFail, "got \(r.status)")
        #expect(message(r) == "Encrypt found in document")
        #expect(!r.couldNotVerify)
    }

    @Test("A user-password output FAILs Layer 4")
    func userPasswordFails() async throws {
        let r = try await layer4(Self.pdf(Self.userAndOwner))
        #expect(r.status.isFail, "got \(r.status)")
        #expect(message(r) == "Encrypt found in document")
    }

    @Test("An unencrypted output passes Layer 4")
    func unencryptedPasses() async throws {
        let r = try await layer4(Self.pdf([:]))
        #expect(r.status == .pass, "got \(r.status)")
    }

    /// Without a file URL the layer reads the document's own serialization;
    /// an encrypted document must still never read PASS.
    @Test("An encrypted document without a file URL never passes Layer 4")
    func encryptedWithoutURLNeverPasses() async throws {
        let doc = try #require(PDFDocument(data: Self.pdf(Self.ownerOnly)))
        #expect(doc.documentURL == nil)
        let r = await layer4(doc)
        #expect(r.status != .pass, "an encrypted document read PASS: \(r.status)")
    }
}

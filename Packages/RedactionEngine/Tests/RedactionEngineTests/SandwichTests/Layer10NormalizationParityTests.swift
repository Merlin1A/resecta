import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Layer 10 (operator re-extraction) scans the decoded operator text in the
// search path's normalized form as well as as decoded — the mirror of Layer
// 3's decoded pass — so a compatibility-form residue outside the byte
// automaton's own variant set (the term as typed, its normalized form, its
// ligature-composed form) is reported by both string-search layers. The
// fixture is `TestFixtures.compatFormResiduePDF`: the term spelled with the
// ordinal indicator ª for its `a` (WinAnsi 0xAA in the operand, which the
// operator decoder reads as U+00AA and NFKC folds to `a`).

@Suite("Layer 10 normalization parity", .tags(.security))
struct Layer10NormalizationParityTests {
    private let term = SensitiveTerm(text: "plant-engcompat-01", requiresTokenBoundary: false)

    private func layer10(
        _ data: Data, prefix: String
    ) async throws -> (status: VerificationStatus, pages: [Int]?, terms: [String]?, url: URL) {
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: prefix)
        let result = await SandwichVerification().verifyTextOperatorSemantics(
            outputDocument: SendablePDFDocument(doc), sensitiveTerms: [term])
        return (result.status, result.pageReferences, result.reviewTermTexts, url)
    }

    @Test("A compatibility-form spelling outside the automaton's variant set is reported by Layer 10")
    func compatibilityFormIsReported() async throws {
        let r = try await layer10(TestFixtures.compatFormResiduePDF(burned: nil), prefix: "l10_compat_")
        defer { try? FileManager.default.removeItem(at: r.url) }
        #expect(r.status.isAttention, "got \(r.status)")
        if case .attention(let msg) = r.status {
            #expect(msg == "Text matching your redactions is readable in page 1 content (1 instance)", "\(msg)")
        }
        #expect(r.pages == [0])
        #expect(r.terms == ["plant-engcompat-01"])
    }

    @Test("Layer 3 reports the same residue from PDFKit's decoded text (the mirror's other half)")
    func layer3ReportsTheSameResidue() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.compatFormResiduePDF(burned: nil), prefix: "l3_compat_")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await VerificationEngine().runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [term],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        #expect(result.status.isAttention, "got \(result.status)")
        if case .attention(let msg) = result.status {
            #expect(msg.contains("readable on page 1 (1 instance)"), "\(msg)")
        }
    }

    @Test("A page carrying both spellings counts the larger scan, never the sum")
    func countIsTheLargerScan() async throws {
        // The plain spelling matches the as-decoded scan (1); the normalized
        // scan sees both spellings (2); the page reports 2, not 3.
        let r = try await layer10(TestFixtures.compatFormResiduePDF(burned: "plant-engcompat-01"),
                                  prefix: "l10_compat_both_")
        defer { try? FileManager.default.removeItem(at: r.url) }
        #expect(r.status.isAttention, "got \(r.status)")
        if case .attention(let msg) = r.status {
            #expect(msg.hasSuffix("(2 instances)"), "\(msg)")
        }
    }

    @Test("ASCII operator text is scanned once; the verdict and count are unchanged")
    func asciiPageUnchanged() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.whiteOnWhiteTextPDF(), prefix: "l10_ascii_")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await SandwichVerification().verifyTextOperatorSemantics(
            outputDocument: SendablePDFDocument(doc),
            sensitiveTerms: [SensitiveTerm(text: "PLANT-ENGWOW-01", requiresTokenBoundary: false)])
        #expect(result.status.isAttention, "got \(result.status)")
        if case .attention(let msg) = result.status {
            #expect(msg.hasSuffix("(1 instance)"), "\(msg)")
        }
    }
}

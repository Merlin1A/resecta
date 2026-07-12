import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// PD-3 (SV-5): token-boundary matching for boundary-required sensitive
// terms, the two-sided complete-token rule in Layer 3's structural pass,
// and the Layer 3 structural/decoded combined verdict.

extension VerificationStatus {
    /// Strict clean pass (VerificationStatus has no public isPass —
    /// production folds tiers via isFail/isWarn/isInfo).
    fileprivate var isPass: Bool { if case .pass = self { true } else { false } }
}

@Suite("SensitiveTermAutomaton token boundaries (PD-3)")
struct SensitiveTermAutomatonTests {

    private func matches(
        term: String, requiresTokenBoundary: Bool, in text: String
    ) -> [AhoCorasickMatch] {
        let automaton = SensitiveTermAutomaton(validTerms: [
            SensitiveTerm(text: term, requiresTokenBoundary: requiresTokenBoundary)
        ])
        return automaton.tokenFilteredMatches(in: Data(text.utf8))
    }

    @Test("Boundary term embedded in a word is dropped; plain term still matches")
    func embeddedMatchDropped() {
        // The sample-doc false-positive class: "pos" inside "Deposits".
        #expect(matches(term: "pos", requiresTokenBoundary: true,
                        in: "Deposits this period").isEmpty)
        #expect(!matches(term: "pos", requiresTokenBoundary: false,
                         in: "Deposits this period").isEmpty)
    }

    @Test("Boundary term as a complete token matches, including case variants")
    func completeTokenKept() {
        #expect(!matches(term: "pos", requiresTokenBoundary: true,
                         in: "POS PURCHASE 4471").isEmpty)
        #expect(!matches(term: "Delia", requiresTokenBoundary: true,
                         in: "holder: Delia, primary").isEmpty)
    }

    @Test("Rejection is two-sided: leading or trailing alphanumeric kills the hit")
    func twoSidedRejection() {
        #expect(matches(term: "Delia", requiresTokenBoundary: true,
                        in: "XDelia rest").isEmpty)
        #expect(matches(term: "Delia", requiresTokenBoundary: true,
                        in: "start DeliaX").isEmpty)
        #expect(matches(term: "Delia", requiresTokenBoundary: true,
                        in: "9Delia9").isEmpty)
    }

    @Test("Buffer start and end count as boundaries")
    func bufferEdgesAreBoundaries() {
        #expect(!matches(term: "Delia", requiresTokenBoundary: true,
                         in: "Delia opened the account").isEmpty)
        #expect(!matches(term: "Delia", requiresTokenBoundary: true,
                         in: "account holder Delia").isEmpty)
    }

    @Test("0x1F operand separators qualify as boundaries (Layer 10 accumulator shape)")
    func separatorAdjacency() {
        // Layer 10 joins decoded operands with 0x1F — the corrupt holder
        // line surfaces the name as its own operand. The leak signal must
        // survive boundary filtering.
        var accumulator = Data("Sablebrook\u{1F}".utf8)
        accumulator.append(Data("Delia".utf8))
        accumulator.append(Data("\u{1F}R.\u{1F}Hartwell".utf8))
        let automaton = SensitiveTermAutomaton(validTerms: [
            SensitiveTerm(text: "Delia", requiresTokenBoundary: true),
            SensitiveTerm(text: "Hartwell", requiresTokenBoundary: true),
        ])
        let hits = automaton.tokenFilteredMatches(in: accumulator)
        #expect(hits.count == 2,
                "0x1F-adjacent complete tokens must both match; got \(hits.count)")
    }

    @Test("Non-ASCII adjacent bytes qualify as boundaries (ASCII-only rule)")
    func nonASCIIAdjacency() {
        // "é" encodes as two UTF-8 bytes ≥ 0x80 — non-alphanumeric-ASCII,
        // so a term right after it is token-bounded by the byte rule.
        #expect(!matches(term: "Delia", requiresTokenBoundary: true,
                         in: "é" + "Delia done").isEmpty)
    }

    @Test("Mixed term set: only the boundary-required term is filtered")
    func mixedTermSet() {
        let automaton = SensitiveTermAutomaton(validTerms: [
            SensitiveTerm(text: "pos", requiresTokenBoundary: true),
            SensitiveTerm(text: "Deposits", requiresTokenBoundary: false),
        ])
        let hits = automaton.tokenFilteredMatches(in: Data("Deposits this period".utf8))
        // "Deposits" matches as a plain term; the embedded "pos" hit is
        // dropped. Distinct (position, length) pairs pin exactly one
        // physical occurrence.
        #expect(AhoCorasick.uniqueOccurrenceCount(hits) == 1)
        #expect(hits.allSatisfy { $0.length == "Deposits".utf8.count })
    }
}

@Suite("Layer 10 boundary-aware term search (PD-3)")
struct Layer10BoundaryTests {
    private let verifier = SandwichVerification()

    /// Raw single-Tj content stream — the shape of Resecta's own writer
    /// output, whose operands are whole run groups (Layer 10's only
    /// production input). A UIKit-rendered fixture kern-splits words into
    /// TJ fragments, whose 0x1F operand joins read as token boundaries —
    /// foreign-shaped input the layer never verifies; the filter errs
    /// toward flagging there.
    private func runLayer10(
        text: String, terms: [SensitiveTerm]
    ) async throws -> (VerificationStatus, URL) {
        let stream = "BT /F1 12 Tf 72 700 Td (\(text)) Tj ET"
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: "l10_boundary_")
        let status = await verifier.verifyTextOperatorSemantics(
            outputDocument: SendablePDFDocument(doc), sensitiveTerms: terms).status
        return (status, url)
    }

    @Test("Boundary name term does not flag an unrelated containing word")
    func embeddedWordDoesNotFlag() async throws {
        let (status, url) = try await runLayer10(
            text: "Deposits this period 1240.00",
            terms: [SensitiveTerm(text: "pos", requiresTokenBoundary: true)])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(status.isPass,
                "embedded 'pos' inside 'Deposits' must not flag; got \(status)")
    }

    @Test("Plain term keeps substring semantics on the same text")
    func plainTermStillSubstringMatches() async throws {
        let (status, url) = try await runLayer10(
            text: "Deposits this period 1240.00",
            terms: [SensitiveTerm(text: "pos")])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(status.isAttention,
                "plain terms keep substring matching (residual tier); got \(status)")
    }

    @Test("Boundary term still flags a standalone leak (case variant)")
    func standaloneLeakStillCaught() async throws {
        let (status, url) = try await runLayer10(
            text: "POS PURCHASE 4471",
            terms: [SensitiveTerm(text: "pos", requiresTokenBoundary: true)])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(status.isAttention,
                "standalone complete-token occurrence must flag (residual tier); got \(status)")
    }
}

@Suite("Layer 3 two-sided token rule + combined verdict (PD-3)")
struct Layer3BoundaryAndMaskingTests {
    private let engine = VerificationEngine()

    private func runLayer3(
        _ doc: PDFDocument, terms: [SensitiveTerm]
    ) async -> LayerResult {
        await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: terms,
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
    }

    @Test("A term trailing a longer name token is a fragment WARN, not a FAIL")
    func trailingFragmentDemotedToWarn() async throws {
        // The sample-doc Layer 3 false positive: "Name" inside "/FontName "
        // was a complete token under the one-sided (following-byte) rule.
        // Two-sided: 't' precedes the match → fragment.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/FontName (x)"),
            prefix: "l3_twosided_")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await runLayer3(doc, terms: [SensitiveTerm(text: "Name")])
        #expect(!result.status.isFail,
                "match embedded at a token tail must not FAIL; got \(result.status)")
        #expect(result.status.isWarn,
                "fragment collision keeps the WARN tier; got \(result.status)")
    }

    @Test("A genuine delimiter-bounded token still FAILs")
    func delimiterBoundedTokenStillFails() async throws {
        // '/' is a PDF delimiter — a literal /Name name-object is a
        // complete token on both sides.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Marker /Name"),
            prefix: "l3_nametoken_")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await runLayer3(doc, terms: [SensitiveTerm(text: "Name")])
        #expect(result.status.isFail,
                "delimiter-bounded structural token must FAIL; got \(result.status)")
    }

    @Test("Boundary-required term embedded in a word produces no structural verdict at all")
    func boundaryTermEmbeddedIsDropped() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (Deliaville)"),
            prefix: "l3_boundary_drop_")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await runLayer3(
            doc, terms: [SensitiveTerm(text: "Delia", requiresTokenBoundary: true)])
        #expect(result.status.isPass,
                "embedded hit of a boundary term is dropped before classification; got \(result.status)")
    }

    @Test("Boundary-required term as a standalone literal still FAILs (leak coverage)")
    func boundaryTermStandaloneStillFails() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (Delia)"),
            prefix: "l3_boundary_keep_")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await runLayer3(
            doc, terms: [SensitiveTerm(text: "Delia", requiresTokenBoundary: true)])
        #expect(result.status.isFail,
                "standalone occurrence of a boundary term must FAIL; got \(result.status)")
    }

    @Test("Structural FAIL no longer masks the decoded-text pass: one combined verdict")
    func structuralAndDecodedCombine() async throws {
        // One document carrying BOTH surfaces: an Info-dict literal (outside
        // any stream → structural pass) and drawn page text (inside the
        // content stream → excluded from the structural pass, surfaced by
        // the PDFKit-decoded SVT-3 pass).
        let stream = "BT /F1 12 Tf 100 700 Td (Delia Hartwell) Tj ET"
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
            PDFObject(id: 6, content: "<< /X (SECRETTOKEN99) >>"),
        ], rootId: 1, infoId: 6)
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: "l3_masking_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        #expect(page.string?.contains("Delia Hartwell") == true,
                "fixture must expose the drawn text to PDFKit decoding")

        let result = await runLayer3(doc, terms: [
            SensitiveTerm(text: "SECRETTOKEN99"),
            SensitiveTerm(text: "Delia Hartwell"),
        ])
        #expect(result.status.isFail, "combined verdict must FAIL; got \(result.status)")
        if case .fail(let message) = result.status {
            #expect(message.contains("structural data"),
                    "structural verdict must be reported; got: \(message)")
            #expect(message.contains("still readable"),
                    "decoded verdict must be reported alongside; got: \(message)")
        }
        #expect(result.pageReferences == [0],
                "combined verdict carries the decoded pass's page list")
    }

    @Test("Decoded-only residual keeps its page-scoped shape after the combine")
    func decodedOnlyFailUnchanged() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.textLayerPDF(text: "statement for Delia Hartwell"),
            prefix: "l3_decoded_only_")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await runLayer3(
            doc, terms: [SensitiveTerm(text: "Delia Hartwell")])
        #expect(result.status.isAttention)
        if case .attention(let message) = result.status {
            #expect(message.contains("still readable"), "got: \(message)")
            #expect(!message.contains("structural data"),
                    "no structural verdict on this fixture; got: \(message)")
        }
        #expect(result.pageReferences == [0])
        #expect(result.reviewTermTexts == ["Delia Hartwell"],
                "display-only term texts must ride beside the residual verdict")
    }
}

@Suite("SensitiveTermAutomaton match → source-term mapping")
struct SensitiveTermMappingTests {

    @Test("Case and encoding variants of one term collapse to its display text")
    func caseVariantsCollapse() {
        let automaton = SensitiveTermAutomaton(validTerms: [
            SensitiveTerm(text: "Delia", requiresTokenBoundary: true),
        ])
        // Mixed-case survivor: matched via a case-variant pattern, must map
        // back to the single source display text.
        let matches = automaton.tokenFilteredMatches(in: Data("header DELIA and delia".utf8))
        #expect(!matches.isEmpty)
        #expect(automaton.matchedTermTexts(matches) == ["Delia"])
    }

    @Test("Multiple terms report deduplicated texts in first-match order")
    func multiTermOrder() {
        let automaton = SensitiveTermAutomaton(validTerms: [
            SensitiveTerm(text: "alpha"),
            SensitiveTerm(text: "9042"),
        ])
        let matches = automaton.tokenFilteredMatches(
            in: Data("x 9042 then alpha then 9042 again".utf8))
        #expect(automaton.matchedTermTexts(matches) == ["9042", "alpha"])
    }

    @Test("Boundary-embedded matches contribute no term text")
    func embeddedMatchesDropped() {
        let automaton = SensitiveTermAutomaton(validTerms: [
            SensitiveTerm(text: "pos", requiresTokenBoundary: true),
        ])
        let matches = automaton.tokenFilteredMatches(in: Data("Deposits".utf8))
        #expect(matches.isEmpty)
        #expect(automaton.matchedTermTexts(matches).isEmpty)
    }
}

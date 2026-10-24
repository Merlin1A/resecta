import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

extension VerificationEngineTests {

    // MARK: - Layer 1: Text Extraction on clean output

    @Test("Layer 1 passes on image-only PDF with no text")
    func layer1PassesCleanPDF() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .textExtraction, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass)
    }

    // MARK: - Layer 3: Binary String Search

    @Test("Layer 3 reports a sensitive term embedded in the PDF bytes")
    func layer3FindsSensitiveTerm() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        // Manually check if the term "gray" appears in the PDF bytes
        // (it might since we draw gray). Use a term we KNOW is in the bytes.
        let engine = VerificationEngine()

        // Use a term that won't be in a clean PDF
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["NONEXISTENT_TERM_12345"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass, "Non-existent term should not be found")
    }

    @Test("Layer 3 warns when all sensitive terms are shorter than 3 characters")
    func layer3WarnsShortTerms() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["ab", "xy"].map { SensitiveTerm(text: $0) },  // All < 3 chars — should warn
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "Should warn when all terms are too short to search")
    }

    @Test("Layer 3 reports INFO when no sensitive terms provided")
    func layer3InfoOnEmptyTerms() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [],  // No terms — expected for manual-only redaction
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // A manual-only redaction ran no string search — NOT APPLICABLE
        // (masthead unaffected), not a "No issues found" PASS.
        #expect(result.status.isNotApplicable,
                "Empty sensitive terms → NOT APPLICABLE, not PASS; got \(result.status)")
        if case .notApplicable(let msg) = result.status {
            #expect(msg.contains("string search did not run"), "got: \(msg)")
        }
    }

    @Test("Layer 3 searches 3-character terms (abbreviations like SSN, DOB)")
    func layer3Searches3CharTerms() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        // "zzq" is 3 chars — should now be searched (not skipped).
        // It won't be found in a clean PDF, so result is still .pass.
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["zzq"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass, "3-char term searched but not found → pass")
    }

    // MARK: - Layer 3: Case folding, normalization & count honesty

    @Test("Layer 3 FAILs when a case variant of the term leaks into structural bytes, counted once")
    func layer3CaseVariantLeakCountedOnce() async throws {
        // The user's query is contributed as typed ("acme"); the document's
        // Title Case occurrence ("Acme") leaking into structural bytes must
        // still FAIL — and one physical occurrence must report one match,
        // not one per encoding/case pattern variant.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (Acme)"),
            prefix: "case_variant_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["acme"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "Title Case leak of a lowercase query must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("(1 match(es))"),
                    "one physical occurrence must count once; got: \(msg)")
        }
    }

    @Test("Layer 3 flags a case variant in decoded page text (residual tier)")
    func layer3CaseVariantInDecodedPage() async throws {
        // Same case-variant leak, but living only inside a text-show stream:
        // the structural pass excludes stream ranges, so the decoded
        // page.string re-scan must surface it.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermInTextStream(term: "Acme"),
            prefix: "case_decoded_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["acme"].map { SensitiveTerm(text: $0) },
            pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction])
        #expect(result.status.isAttention,
                "decoded-page case-variant leak must flag (residual tier); got \(result.status)")
        #expect(result.reviewTermTexts == ["acme"],
                "display-only term texts carry the source term for the results UI")
    }

    @Test("Layer 3 FAILs on a decomposed term whose composed form is in the bytes")
    func layer3NFCNormalizedTermMatch() async throws {
        // Term typed decomposed (e + combining acute); the fixture carries
        // the composed UTF-8 byte shape. NFC normalization must bridge them.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (Andr\u{00E9})"),
            prefix: "nfc_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["Andre\u{0301}"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "decomposed term must match composed output bytes; got \(result.status)")
    }

    @Test("Layer 3 searches a 2-character CJK name")
    func layer3TwoCharCJKTermSearched() async throws {
        // "李明" is only 2 characters but a complete full name — the length
        // filter must admit it, and its structural leak must FAIL.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (\u{674E}\u{660E})"),
            prefix: "cjk_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["\u{674E}\u{660E}"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "2-character CJK name must be searched and FAIL on a leak; got \(result.status)")
    }

    @Test("Layer 3 reports a partial term drop on the otherwise-clean path")
    func layer3PartialShortTermDropSurfaced() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        // "zzqx" is searched (and clean); "ab" is too short. A term the
        // layer could not search is a could-not-verify WARN — the all-short
        // shape — never an informational note.
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["zzqx", "ab"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn && result.couldNotVerify,
                "partial short-term drop must surface as a could-not-verify WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("1 term too short to check"), "got: \(msg)")
        }
    }

    @Test("Layer 3 degraded-automaton WARN copy is unchanged under the variant expansion")
    func layer3DegradedWarnCopyUnchanged() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        // One 400k-character term expands past the byte-based 1 MB automaton
        // bound → degraded no-op → the existing WARN, verbatim.
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [String(repeating: "a", count: 400_000)].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn)
        if case .warn(let msg) = result.status {
            #expect(msg == "Sensitive term search exceeded size limit — results may be incomplete")
        }
    }

    // MARK: - Layer 3: Token-boundary + EXIF

    @Test("Layer 3 FAILs on a boundary-token structural match")
    func tokenBoundaryMatch_triggersFail() async throws {
        // Term in structural (non-stream) bytes followed by ")" — a PDF
        // delimiter → complete token → FAIL.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (CLASSIFIED)"),
            prefix: "tok_boundary_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["CLASSIFIED"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "boundary-token structural match must FAIL; got \(result.status)")
    }

    @Test("Layer 3 WARNs on a non-boundary (fragment) structural match")
    func nonBoundaryMatch_triggersWarn() async throws {
        // Term embedded mid-token ("CLASSIFIEDZ") — the byte after the match is a
        // letter, not a delimiter → possible fragment collision → WARN, not FAIL.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (CLASSIFIEDZ)"),
            prefix: "tok_fragment_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["CLASSIFIED"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn,
                "non-boundary fragment match must WARN, not FAIL; got \(result.status)")
    }

    @Test("Layer 3 WARNs on a sensitive term in JPEG EXIF")
    func jpegExifWithSensitiveTerm_triggersWarn() async throws {
        let jpeg = TestFixtures.exifJPEG(app1Payloads: ["CLASSIFIED"])
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.pdfWithDCTImageStream(jpeg), prefix: "exif_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["CLASSIFIED"].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn,
                "term in JPEG EXIF must WARN; got \(result.status)")
    }

    @Test("EXIF scan: single, multi-APP1, truncated, absent (adversarial)")
    func exifScanAdversarialBytes() {
        let automaton = AhoCorasick(patterns: AhoCorasick.encodeForSearch("CLASSIFIED"))
        // single APP1 carrying the term
        #expect(VerificationEngine.jpegEXIFContainsTerm(
            TestFixtures.exifJPEG(app1Payloads: ["CLASSIFIED"]), automaton: automaton))
        // multi-APP1: term only in the SECOND segment (walk must continue)
        #expect(VerificationEngine.jpegEXIFContainsTerm(
            TestFixtures.exifJPEG(app1Payloads: ["benign", "CLASSIFIED"]), automaton: automaton))
        // oversized declared length (claims past EOF) — term still in range, no OOB
        #expect(VerificationEngine.jpegEXIFContainsTerm(
            TestFixtures.exifJPEG(app1Payloads: ["CLASSIFIED"], truncateLastLengthTo: 9999),
            automaton: automaton))
        // term truncated before it completes → graceful miss (WARN-only worst case)
        #expect(!VerificationEngine.jpegEXIFContainsTerm(
            TestFixtures.exifJPEG(app1Payloads: ["CLASS"]), automaton: automaton))
        // no APP1 segment at all → no match
        #expect(!VerificationEngine.jpegEXIFContainsTerm(
            TestFixtures.exifJPEG(app1Payloads: []), automaton: automaton))
    }
}

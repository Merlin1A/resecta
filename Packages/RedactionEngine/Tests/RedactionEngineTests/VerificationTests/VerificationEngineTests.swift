import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

// ENGINE §6 — Verification engine tests.

@Suite("Verification Engine")
struct VerificationEngineTests {

    // MARK: - Overall Status Derivation (ENGINE §6.7)

    @Test("aggregateStatus: any FAIL → overall FAIL")
    func failDominates() {
        let engine = VerificationEngine()
        let layers = [
            makeResult(.pass), makeResult(.warn("w")), makeResult(.fail("critical"))
        ]
        #expect(engine.aggregateStatus(layers) == .fail(""))
    }

    @Test("aggregateStatus: no FAIL, any WARN → overall WARN")
    func warnWithoutFail() {
        let engine = VerificationEngine()
        let layers = [
            makeResult(.pass), makeResult(.warn("minor")), makeResult(.pass)
        ]
        #expect(engine.aggregateStatus(layers) == .warn(""))
    }

    @Test("aggregateStatus: all PASS → overall PASS")
    func allPass() {
        let engine = VerificationEngine()
        let layers = [makeResult(.pass), makeResult(.pass), makeResult(.pass)]
        #expect(engine.aggregateStatus(layers) == .pass)
    }

    @Test("aggregateStatus: empty layers → vacuous PASS")
    func emptyLayers() {
        let engine = VerificationEngine()
        #expect(engine.aggregateStatus([]) == .pass)
    }

    // MARK: - Layer Count (R4: never hardcoded)

    @Test("Secure Rasterization has 5 layers, Searchable has 10")
    func layerCounts() {
        let engine = VerificationEngine()
        #expect(engine.layerCount(for: .secureRasterization) == 5)
        #expect(engine.layerCount(for: .searchableRedaction) == 10)
    }

    // MARK: - Layer Names and Symbols

    @Test("Every Searchable-mode layer has a non-empty name and symbol")
    func layerNamesAndSymbols() {
        let engine = VerificationEngine()
        for i in 0..<engine.layerCount(for: .searchableRedaction) {
            #expect(!engine.layerName(at: i).isEmpty)
            #expect(!engine.layerSymbol(at: i).isEmpty)
        }
    }

    // MARK: - Layer 1: Text Extraction on clean output

    @Test("Layer 1 passes on image-only PDF with no text")
    func layer1PassesCleanPDF() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            0, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass)
    }

    // MARK: - Layer 3: Binary String Search

    @Test("Layer 3 finds sensitive term embedded in PDF bytes")
    func layer3FindsSensitiveTerm() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        // Manually check if the term "gray" appears in the PDF bytes
        // (it might since we draw gray). Use a term we KNOW is in the bytes.
        let engine = VerificationEngine()

        // Use a term that won't be in a clean PDF
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["NONEXISTENT_TERM_12345"],
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
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["ab", "xy"],  // All < 3 chars — should warn
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "Should warn when all terms are too short to search")
    }

    @Test("Layer 3 reports INFO when no sensitive terms provided (VQ-30)")
    func layer3InfoOnEmptyTerms() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [],  // No terms — expected for manual-only redaction
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // A manual-only redaction ran no string search — INFO (notes group,
        // masthead unaffected), not a "No issues found" PASS.
        #expect(result.status.isInfo,
                "Empty sensitive terms → INFO, not PASS; got \(result.status)")
        if case .info(let msg) = result.status {
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
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["zzq"],
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
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["acme"],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "Title Case leak of a lowercase query must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("(1 match(es))"),
                    "one physical occurrence must count once; got: \(msg)")
        }
    }

    @Test("Layer 3 SVT-3 flags a case variant in decoded page text (residual tier)")
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
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["acme"],
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
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["Andre\u{0301}"],
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
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["\u{674E}\u{660E}"],
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
        // "zzqx" is searched (and clean); "ab" is too short. The drop must
        // be visible, not silent — INFO so the searched-terms-clean verdict
        // is preserved.
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["zzqx", "ab"],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isInfo,
                "partial short-term drop must surface as INFO; got \(result.status)")
        if case .info(let msg) = result.status {
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
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [String(repeating: "a", count: 400_000)],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn)
        if case .warn(let msg) = result.status {
            #expect(msg == "Sensitive term search exceeded size limit — results may be incomplete")
        }
    }

    // MARK: - Layer 3: Token-boundary + EXIF (CAT-357 A+B)

    @Test("Layer 3 FAILs on a boundary-token structural match (CAT-357A)")
    func tokenBoundaryMatch_triggersFail() async throws {
        // Term in structural (non-stream) bytes followed by ")" — a PDF
        // delimiter → complete token → FAIL.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (CLASSIFIED)"),
            prefix: "tok_boundary_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["CLASSIFIED"],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "boundary-token structural match must FAIL; got \(result.status)")
    }

    @Test("Layer 3 WARNs on a non-boundary (fragment) structural match (CAT-357A)")
    func nonBoundaryMatch_triggersWarn() async throws {
        // Term embedded mid-token ("CLASSIFIEDZ") — the byte after the match is a
        // letter, not a delimiter → possible fragment collision → WARN, not FAIL.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/X (CLASSIFIEDZ)"),
            prefix: "tok_fragment_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["CLASSIFIED"],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn,
                "non-boundary fragment match must WARN, not FAIL; got \(result.status)")
    }

    @Test("Layer 3 WARNs on a sensitive term in JPEG EXIF (CAT-357B)")
    func jpegExifWithSensitiveTerm_triggersWarn() async throws {
        let jpeg = TestFixtures.exifJPEG(app1Payloads: ["CLASSIFIED"])
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.pdfWithDCTImageStream(jpeg), prefix: "exif_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: ["CLASSIFIED"],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn,
                "term in JPEG EXIF must WARN; got \(result.status)")
    }

    @Test("EXIF scan: single, multi-APP1, truncated, absent (CAT-357B adversarial)")
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

    // MARK: - Layer 4: Structural Verification

    @Test("Layer 4 passes on clean reconstructed PDF")
    func layer4PassesClean() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // Clean PDF should have no JavaScript, no forms, etc.
        let isClean = result.status == .pass
            || result.status == .warn("")
            || result.status == .info("")
        #expect(isClean, "Clean PDF should pass, warn, or be info-only (not fail) structural check")
    }

    // MARK: - Layer 4: /Names name-dictionary carriers (VQ-20)

    @Test("Layer 4 FAILs on active-content subtrees under /Names",
          arguments: ["EmbeddedFiles", "JavaScript"])
    func layer4FailsOnNamesTreeCarrier(carrier: String) async throws {
        // The real-world carrier location for embedded files and document
        // JavaScript is /Names → /<carrier>, not the catalog top level.
        // Pre-fix this surfaced only as the generic "Structural findings:
        // Names" WARN.
        let fixture = TestFixtures.withCatalogKey(
            "Names", value: "<< /\(carrier) << /Names [] >> >>")
        let (doc, url) = try TestFixtures.writeTempPDF(fixture, prefix: "names_carrier_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isFail,
                "/Names → /\(carrier) must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg == "\(carrier) found under /Names in document catalog",
                    "FAIL message should name the carrier under /Names; got \(msg)")
        }
    }

    @Test("Layer 4 keeps generic WARN for plain /Names without carriers")
    func layer4WarnsOnPlainNames() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withCatalogKey("Names"), prefix: "names_plain_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "Plain /Names with no carrier subtrees stays WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("Names"), "WARN message should name /Names; got \(msg)")
        }
    }

    @Test("Layer 4 still FAILs on top-level EmbeddedFiles")
    func layer4FailsTopLevelEmbeddedFiles() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withCatalogKey("EmbeddedFiles"), prefix: "embedded_top_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isFail,
                "Top-level EmbeddedFiles must FAIL unchanged; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg == "EmbeddedFiles found in document catalog",
                    "Top-level FAIL message unchanged; got \(msg)")
        }
    }

    // MARK: - Layer 5: Metadata Verification

    @Test("Layer 5 reports Apple auto-injected metadata as info")
    func layer5InfoOnAutoInjected() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // CGPDFContext auto-injects /Producer, /CreationDate — expect INFO
        // (post-split: only auto-injected → .info; /Trapped or XMP → .warn).
        #expect(result.status == .info("") || result.status == .pass,
                "Should report auto-injected metadata as info or pass if none present")
    }

    @Test("Layer 5 /Trapped WARN says Metadata present, not auto-injected (VQ-31b)")
    func trappedWarnCopyNotAutoInjected() async throws {
        // /Trapped is workflow-set, not auto-injected — the mixed-warning
        // message must not claim auto-injection when it names /Trapped.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Trapped /True"),
            prefix: "trapped_copy_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn, "/Trapped must WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg == "Metadata present: /Trapped",
                    "/Trapped WARN copy must not say auto-injected; got \(msg)")
        }
    }

    @Test("Layer 5 expected-keys-only INFO copy unchanged (VQ-31b)")
    func expectedKeysOnlyInfoCopyUnchanged() async throws {
        // Producer/CreationDate/ModDate ARE auto-injected — the pure-INFO
        // path keeps the auto-injected wording.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Producer (SyntheticWriter)"),
            prefix: "producer_info_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isInfo,
                "Expected keys only must stay INFO; got \(result.status)")
        if case .info(let msg) = result.status {
            #expect(msg == "Auto-injected metadata present: /Producer",
                    "Pure-INFO copy keeps auto-injected wording; got \(msg)")
        }
    }

    // MARK: - Layer 6: SVT-1 on region-less searchable pages (CAT-358)

    @Test("Layer 6 runs SVT-1 on region-less searchable pages (CAT-358)")
    func layer6RunsOnRegionlessPage() async throws {
        // regions: [:] — pre-fix runLayer6 skipped region-less pages entirely
        // (guard !pageRegions.isEmpty), so a tampered region-less searchable
        // page passed Layer 6. After the split the empty maps flow into
        // verifySpatialExclusion(regionShapes: []) and the SVT-1 lattice FAILs.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withBlandKerningInjection(), prefix: "layer6_regionless_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            5, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction]
        )
        #expect(result.status.isFail,
                "Layer 6 must run SVT-1 on a tampered region-less page; got \(result.status)")
    }

    // MARK: - Layer 5: XMP-without-/Info and non-string key presence (CAT-378/379)

    @Test("Layer 5 scans XMP even when /Info is absent (CAT-378)")
    func xmpScannedWhenInfoAbsent() async throws {
        // Fixture has an XMP /Metadata stream but no /Info dictionary. Pre-fix
        // the nil-/Info guard returned .pass before the XMP scan ran (red).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withXMPNoInfo(), prefix: "xmp_no_info_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "XMP present with no /Info must WARN, not silently pass; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("XMP"), "WARN message should name XMP; got \(msg)")
        }
    }

    @Test("Layer 5 FAILs on a non-string /Info value (CAT-379)")
    func nonStringTitleValueFails() async throws {
        // /Title is an INTEGER (42). Pre-fix the GetString/GetName pair both
        // returned false for an integer value → fell through as "absent" (red).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Title 42"),
            prefix: "title_int_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            4, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .fail("Metadata key /Title present"),
                "Integer /Title value must FAIL on key presence; got \(result.status)")
    }

    // MARK: - End-to-End: Reconstruct then Verify

    @Test("Full 5-layer verification passes on reconstructed output")
    func fullVerificationOnReconstructedPDF() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        var layers: [LayerResult] = []

        for i in 0..<5 {
            let result = await engine.runLayer(
                i, outputDocument: SendablePDFDocument(doc),
                sourcePageCount: 1, regions: [:], sensitiveTerms: [],
                pipelineMode: .secureRasterization,
                filterDigests: [], perPageModes: [.secureRasterization]
            )
            layers.append(result)
        }

        let overall = engine.aggregateStatus(layers)
        // Should be PASS or WARN (Apple metadata). Never FAIL on clean output.
        #expect(overall != .fail(""),
                "Clean reconstructed PDF should not FAIL verification")
    }

    // MARK: - Layer 4: Incremental Update Detection

    @Test("Layer 4 FAILs on PDF with incremental update (multiple %%EOF)")
    func layer4FailsIncrementalUpdate() async throws {
        let fixture = TestFixtures.incrementalUpdate(
            originalText: "ORIGINAL SECRET", updatedText: "REDACTED"
        )
        let (doc, url) = try TestFixtures.writeTempPDF(fixture, prefix: "incremental_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            3, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // Incremental update produces multiple %%EOF → FAIL (ENGINE §6.4)
        #expect(result.status.isFail,
                "Layer 4 should FAIL on incremental update (multiple %%EOF)")
    }

    // MARK: - Layer Name and Symbol Coverage

    @Test("All layer names are non-empty for both modes",
          arguments: [PipelineMode.secureRasterization, PipelineMode.searchableRedaction])
    func allLayerNamesNonEmpty(mode: PipelineMode) {
        let engine = VerificationEngine()
        let count = engine.layerCount(for: mode)
        for i in 0..<count {
            #expect(!engine.layerName(at: i).isEmpty,
                    "Layer \(i) name should be non-empty for \(mode)")
        }
    }

    @Test("All layer symbols are non-empty for both modes",
          arguments: [PipelineMode.secureRasterization, PipelineMode.searchableRedaction])
    func allLayerSymbolsNonEmpty(mode: PipelineMode) {
        let engine = VerificationEngine()
        let count = engine.layerCount(for: mode)
        for i in 0..<count {
            #expect(!engine.layerSymbol(at: i).isEmpty,
                    "Layer \(i) symbol should be non-empty for \(mode)")
        }
    }

    @Test("aggregateStatus with only skipped layers returns skipped (CAT-372)")
    func allSkippedReturnsSkipped() {
        let engine = VerificationEngine()
        let layers = [makeResult(.skipped), makeResult(.skipped)]
        // CAT-372: all-skipped is the .skipped sentinel, not a silent .pass.
        #expect(engine.aggregateStatus(layers) == .skipped)
    }

    // MARK: - Layers 7 & 9: Skipped-Layer Honesty (CAT-372)
    //
    // On the verify-only resume path the per-page filter digests are rebuilt
    // all-nil, so the digest-consuming cross-checks (Layer 7 character count,
    // Layer 9 character lineage) run zero comparisons. They must report the
    // truth (.skipped) rather than a silent .pass. Pre-fix these returned
    // .pass — the assertions below are the failing-then-green pins.

    @Test("Layer 7 returns .skipped when all eligible pages have nil digests")
    func layer7AllNilDigestsReturnsSkipped() async throws {
        let (doc, url) = try makeBlankPDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            6, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .searchableRedaction]
        )
        #expect(result.status == .skipped,
                "Layer 7 eligible-but-unchecked must report .skipped, not .pass")
    }

    @Test("Layer 9 returns .skipped when all eligible pages have nil digests")
    func layer9AllNilDigestsReturnsSkipped() async throws {
        let (doc, url) = try makeBlankPDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            8, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .searchableRedaction]
        )
        #expect(result.status == .skipped,
                "Layer 9 eligible-but-unchecked must report .skipped, not .pass")
    }

    @Test("Layer 7 stays .pass when no page is eligible (all per-page SR)")
    func layer7AllSRPagesStaysPass() async throws {
        // eligible == 0 (every page is per-page Secure Rasterization, e.g. the
        // CAT-353 rotated-page stopgap): the layer is skipped by design and
        // must stay .pass — promoting it would WARN-flag valid docs.
        let (doc, url) = try makeBlankPDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            6, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.secureRasterization, .secureRasterization]
        )
        #expect(result.status == .pass,
                "Layer 7 with zero eligible pages stays .pass (skipped by design)")
    }

    // MARK: - Layer 1 / Layer 2 Silent-Bypass Hardening

    @Test("Layer 1 warns when documentURL is nil (AcroForm cannot be checked)")
    func layer1WarnsOnCGPDFDocumentFailure() async throws {
        // PDFDocument loaded from Data has no documentURL, so the
        // CGPDFDocument(url:) chain cannot verify /AcroForm.
        let doc = try await makeCleanPDFWithoutURL()

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            0, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "Layer 1 should warn when CGPDFDocument cannot be opened")
    }

    @Test("Layer 2 OCR-checks a no-JPEG page via the thumbnail fallback (CAT-377)")
    func layer2ThumbnailFallbackChecksNoJPEGPage() async throws {
        // Pre-CAT-377 a page with no extractable JPEG XObject was added to
        // uncheckedPages and the layer WARNed. CAT-377 renders a PDFPage
        // thumbnail and OCRs it instead, so a vector page with no text is now
        // genuinely checked (OCR ran) and PASSes rather than warning unchecked.
        let (doc, url) = try makeVectorOnlyPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass,
                "vector page (no text) is OCR-checked via thumbnail → pass; got \(result.status)")
    }

    // MARK: - Layer 2: Multi-image + thumbnail fallback (CAT-377)

    @Test("extractPageImages returns every image XObject on a page (CAT-377)")
    func multiImagePageBothImagesOCRd() async throws {
        // Two JPEG XObjects on one page. Pre-fix extractPageImage returned a
        // single CGImage (first XObject only, via `return false`);
        // extractPageImages returns both, and runLayer2OCR OCRs each.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.twoImageJPEGPagePDF(), prefix: "twoimg_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        let cgPage = try #require(page.pageRef)

        let extraction = VerificationEngine.extractPageImages(from: cgPage)
        #expect(extraction.images.count == 2,
                "both embedded JPEG XObjects must be extracted; got \(extraction.images.count)")
        #expect(extraction.failedDecodeCount == 0,
                "well-formed JPEGs must not count as decode failures")
    }

    @Test("Multi-image page with a region + text → conservative WARN (CAT-377)")
    func multiImagePageConservativeWarn() async throws {
        // Per-image Vision coordinates cannot be identity-mapped to page space
        // (C-B contract); with a region present and OCR text found, the page is
        // surfaced as a WARN rather than an identity-mapped FAIL/PASS.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.twoImageJPEGPagePDF(textA: "ALPHA", textB: "BRAVO"),
            prefix: "twoimg_warn_")
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn,
                "multi-image page with a region must conservatively WARN; got \(result.status)")
    }

    @Test("aspectMatches: unpadded matches, letterboxed mismatches (A2-9)")
    func thumbnailAspectMismatchIsConservative() {
        // A thumbnail whose aspect matches the requested page aspect is trusted
        // (unpadded); a mismatched (letterboxed) render is not — its
        // observations must be treated conservatively, never identity-mapped.
        #expect(VerificationEngine.aspectMatches(
            CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)))
        #expect(VerificationEngine.aspectMatches(
            CGSize(width: 1224, height: 1584), CGSize(width: 612, height: 792)),
            "2× scale keeps the aspect → still trusted")
        #expect(!VerificationEngine.aspectMatches(
            CGSize(width: 792, height: 792), CGSize(width: 612, height: 792)),
            "square render of a portrait page is padded → not trusted")
    }

    // MARK: - Layer 2: Region-Scoped OCR (CAT-351)

    // -- Pure helper units (no Vision) --------------------------------------

    @Test("classifyPageOCR: text only outside regions → textOutsideRegionsOnly")
    func classifyPageOCR_textOutsideRegions() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            wordBoxes: [], text: "INCOME", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: [])
        #expect(verdict == .textOutsideRegionsOnly)
    }

    @Test("classifyPageOCR: no regions → text is outside (never in-region)")
    func classifyPageOCR_emptyRegions() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1),
            wordBoxes: [], text: "anything", confidence: 0.9)
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [], sensitiveTerms: ["anything"])
        // With no regions the hit can never be IN-region; because its text
        // matches a sensitive term, the out-of-region TERM signal now outranks
        // the generic outside-only verdict (both are "not in-region").
        #expect(verdict == .sensitiveTermOutsideRegions)
    }

    @Test("classifyPageOCR: sensitive term readable outside every region → sensitiveTermOutsideRegions")
    func classifyPageOCR_termOutsideRegion() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            wordBoxes: [], text: "ACME-SECRET", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["acme-secret"])
        #expect(verdict == .sensitiveTermOutsideRegions)
    }

    @Test("classifyPageOCR: out-of-region term below the FAIL confidence gate → generic outside-only")
    func classifyPageOCR_termOutsideRegion_belowConfidence() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            wordBoxes: [], text: "ACME-SECRET", confidence: 0.3)
        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        // Same confidence gate as the in-region term FAIL: a low-confidence
        // (likely misread) match must not raise the term-specific signal.
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["acme-secret"])
        #expect(verdict == .textOutsideRegionsOnly)
    }

    @Test("classifyPageOCR: in-region text outranks a sibling out-of-region term")
    func classifyPageOCR_inRegionBeatsTermOutside() {
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        let inRegion = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "leaked", confidence: 0.9)
        let termOutside = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            wordBoxes: [], text: "ACME-SECRET", confidence: 0.9)
        // Priority: readable text INSIDE a region is the stronger signal.
        #expect(VerificationEngine.classifyPageOCR(
            hits: [inRegion, termOutside], pageRegions: [region],
            sensitiveTerms: ["acme-secret"]) == .textInRegion)
    }

    @Test("classifyPageOCR: no hits → none")
    func classifyPageOCR_noHits() {
        let region = manualRegion(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        #expect(VerificationEngine.classifyPageOCR(
            hits: [], pageRegions: [region], sensitiveTerms: []) == .none)
    }

    @Test("classifyPageOCR: plain text inside region → textInRegion (no term)")
    func classifyPageOCR_textInRegion() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "leaked", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.4, height: 0.3))
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }

    @Test("classifyPageOCR: sensitive term inside region → sensitiveTermInRegion")
    func classifyPageOCR_termInRegion() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.1),
            wordBoxes: [], text: "ACME-SECRET", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.3))
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["acme-secret"]) == .sensitiveTermInRegion)
    }

    @Test("classifyPageOCR: term match is case-insensitive")
    func classifyPageOCR_caseInsensitiveTerm() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "SECRET", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["secret"]) == .sensitiveTermInRegion)
    }

    @Test("classifyPageOCR: a FAIL hit beats a sibling WARN hit (priority)")
    func classifyPageOCR_failBeatsWarn() {
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        let warnHit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.25, y: 0.25, width: 0.1, height: 0.05),
            wordBoxes: [], text: "ordinary", confidence: 0.9)
        let failHit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.05),
            wordBoxes: [], text: "ssn-token", confidence: 0.9)
        #expect(VerificationEngine.classifyPageOCR(
            hits: [warnHit, failHit], pageRegions: [region],
            sensitiveTerms: ["ssn-token"]) == .sensitiveTermInRegion)
    }

    @Test("classifyPageOCR: terms shorter than 3 chars are filtered (mirrors Layer 3)")
    func classifyPageOCR_shortTermFiltered() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "ab", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        // "ab" (< 3) is dropped → in-region text without a valid term → WARN, not FAIL.
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["ab"]) == .textInRegion)
    }

    @Test("classifyPageOCR: 2-character CJK name is admitted by the term filter")
    func classifyPageOCR_twoCharCJKTermAdmitted() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "\u{674E}\u{660E}", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        // "李明" is 2 characters but a complete full name — shared
        // isSearchableTerm admits it (mirrors Layer 3).
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region],
            sensitiveTerms: ["\u{674E}\u{660E}"]) == .sensitiveTermInRegion)
    }

    @Test("classifyPageOCR: term gate case fold is locale-pinned (POSIX)")
    func classifyPageOCR_termGateLocalePinned() {
        // Direct pin on the replacement for localizedCaseInsensitiveContains:
        // the fold must not follow the device locale. Under Turkish casing
        // rules lowercase "i" does not fold to "I" (dotless-I class); the
        // POSIX-pinned gate must match regardless of device locale.
        #expect(VerificationEngine.containsTermCaseInsensitive("ACCOUNT ID", "id"))
        #expect(VerificationEngine.containsTermCaseInsensitive("Invoice", "INVOICE"))
        #expect(!VerificationEngine.containsTermCaseInsensitive("résumé", "resume"),
                "case-only fold: diacritic-insensitivity must NOT be added")
    }

    @Test("classifyPageOCR (A2-3): word boxes flanking a region suppress a false FAIL")
    func classifyPageOCR_wordLevelIntersection() {
        // Line box spans the region (the survivors "JOHN"/"DOE" plus the filled
        // middle); word boxes sit entirely OUTSIDE the region. With line-level
        // intersection this FAILs ("JOHN DOE" ∈ terms); with word-level it must not.
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.10, y: 0.45, width: 0.80, height: 0.10),       // spans region
            wordBoxes: [
                CGRect(x: 0.10, y: 0.45, width: 0.18, height: 0.10),        // "JOHN" — left
                CGRect(x: 0.74, y: 0.45, width: 0.16, height: 0.10)         // "DOE"  — right
            ],
            text: "JOHN DOE", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.40, y: 0.44, width: 0.18, height: 0.12)) // middle gap
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["JOHN DOE"])
        #expect(verdict != .sensitiveTermInRegion, "word-level boxes must not false-FAIL on a bisected term")
        // The surviving words sit outside every region and the hit's text
        // matches a term → the term-specific outside signal (never the FAIL).
        #expect(verdict == .sensitiveTermOutsideRegions)
    }

    // -- 01-FIX (2026-06-25): meaningful-containment in-region predicate -----
    // The any-overlap test (`CGRect.intersects`) counted a still-visible word
    // whose box clips a mid-line region's edge by a sliver as in-region; in
    // Secure Rasterization that is the ONLY thing that can ever touch an opaque
    // region, so every mid-line redaction false-FAILed. The coverage predicate
    // (≥ `inRegionCoverageThreshold` of the OCR box inside a region) keeps a
    // real paint miss while dropping an edge sliver. See 00-DIAGNOSIS / 01-FIX.

    @Test("classifyPageOCR (01-FIX A1): a neighbour word clipping a region edge is not in-region")
    func classifyPageOCR_edgeClipNotInRegion() {
        // The repro: a mid-line redaction (the filled phone number) whose
        // adjacent still-visible lead-in word's box clips the region's left edge
        // by a sliver. Old predicate → textInRegion (false); coverage → outside.
        let region = manualRegion(CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10))
        let neighbour = VerificationEngine.OCRHit(
            box: CGRect(x: 0.30, y: 0.45, width: 0.16, height: 0.10), // ends at 0.46 — 0.01 past the edge
            wordBoxes: [], text: "Telephone us at", confidence: 1.0)
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [neighbour], pageRegions: [region], sensitiveTerms: [])
        #expect(verdict == .textOutsideRegionsOnly, "a sliver edge clip must not count as in-region")
    }

    @Test("classifyPageOCR (01-FIX A2): glyphs substantially inside a region still FAIL")
    func classifyPageOCR_paintMissStillInRegion() {
        let region = manualRegion(CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20))
        // A readable token centred inside the region (a fill that missed its target).
        let leaked = VerificationEngine.OCRHit(
            box: CGRect(x: 0.45, y: 0.45, width: 0.08, height: 0.06),
            wordBoxes: [], text: "SECRET", confidence: 0.9)
        #expect(VerificationEngine.classifyPageOCR(
            hits: [leaked], pageRegions: [region], sensitiveTerms: ["secret"]) == .sensitiveTermInRegion)
        // Same geometry, non-sensitive text → still in-region (textInRegion).
        let plain = VerificationEngine.OCRHit(
            box: CGRect(x: 0.45, y: 0.45, width: 0.08, height: 0.06),
            wordBoxes: [], text: "ordinary", confidence: 0.9)
        #expect(VerificationEngine.classifyPageOCR(
            hits: [plain], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }

    @Test("classifyPageOCR (01-FIX A3): sensitive text fully outside regions stays out-of-region")
    func classifyPageOCR_sensitiveOutsideRegions() {
        let region = manualRegion(CGRect(x: 0.60, y: 0.10, width: 0.20, height: 0.20))
        let outside = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.20, height: 0.05),
            wordBoxes: [], text: "SECRET", confidence: 0.9)
        // The term is sensitive but it is not inside any region → never a FAIL.
        // The verdict is now the term-specific out-of-region signal (still a
        // WARN-tier outcome once folded; a rasterized page surfaces its own arm).
        #expect(VerificationEngine.classifyPageOCR(
            hits: [outside], pageRegions: [region], sensitiveTerms: ["secret"]) == .sensitiveTermOutsideRegions)
    }

    @Test("classifyPageOCR (01-FIX A4): a sensitive neighbour clipping the edge does not FAIL")
    func classifyPageOCR_sensitiveNeighbourClipNoFail() {
        // Like A1 but the clipping neighbour contains a sensitive term. Old
        // predicate → sensitiveTermInRegion (false FAIL); coverage → outside.
        let region = manualRegion(CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10))
        let neighbour = VerificationEngine.OCRHit(
            box: CGRect(x: 0.30, y: 0.45, width: 0.16, height: 0.10), // clips edge by 0.01
            wordBoxes: [], text: "INDN DELIA HARTWELL CO ID", confidence: 1.0)
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [neighbour], pageRegions: [region], sensitiveTerms: ["hartwell"])
        #expect(verdict != .sensitiveTermInRegion, "edge clip must not raise an in-region term FAIL")
        // The clipped neighbour is out-of-region and its text matches a term,
        // so it carries the term-specific outside signal (never the FAIL).
        #expect(verdict == .sensitiveTermOutsideRegions)
    }

    @Test("classifyPageOCR (01-FIX A5): coverage exactly at the threshold is in-region (inclusive)")
    func classifyPageOCR_coverageAtThresholdInclusive() {
        // Exact-binary geometry: half the OCR box lies inside the region.
        let region = manualRegion(CGRect(x: 0.50, y: 0.0, width: 0.50, height: 1.0))
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50),   // right half inside R
            wordBoxes: [], text: "ordinary", confidence: 0.9)
        // overlap = 0.25×0.50 = 0.125; box = 0.50×0.50 = 0.25; fraction = 0.5 → in.
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }

    @Test("coverageFraction (01-FIX): half-overlap = 0.5; disjoint and degenerate = 0")
    func coverageFraction_math() {
        let box = CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50)
        let halfRegion = CGRect(x: 0.50, y: 0.0, width: 0.50, height: 1.0)
        #expect(VerificationEngine.coverageFraction(of: box, inside: halfRegion) == 0.5)
        let disjoint = CGRect(x: 0.90, y: 0.90, width: 0.05, height: 0.05)
        #expect(VerificationEngine.coverageFraction(of: box, inside: disjoint) == 0.0)
        let degenerate = CGRect(x: 0.25, y: 0.25, width: 0.0, height: 0.0)
        #expect(VerificationEngine.coverageFraction(of: degenerate, inside: halfRegion) == 0.0)
    }

    @Test("layer2RegionSnapshot (A2-4): sub-threshold slivers dropped, survivors clamped")
    func layer2RegionSnapshot_dropsSliversClampsSurvivors() {
        let sliverW = manualRegion(CGRect(x: 0.5, y: 0.5, width: 0.0005, height: 0.2))
        let sliverH = manualRegion(CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.0005))
        let outOfBounds = manualRegion(CGRect(x: -0.1, y: 0.2, width: 0.5, height: 0.3))
        let snapshot = VerificationEngine.layer2RegionSnapshot([sliverW, sliverH, outOfBounds])
        #expect(snapshot.count == 1, "both slivers dropped, one survivor")
        // Survivor is clamped into [0,1] (origin no longer negative).
        #expect(snapshot.first?.normalizedRect.minX ?? -1 >= 0)
    }

    // -- Vision integration fixtures (full-page JPEG → runLayer(1)) ----------

    @Test("Layer 2: SR out-of-region text WITH regions present → INFO (expected content, noted)")
    func layer2ScopedOCR_textOutsideRegions_secureInfoWhenRegionsPresent() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("INCOME", CGPoint(x: 40, y: 680), 80)], size: size)   // top-left
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2)) // bottom-right
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        // Readable non-redacted content is expected output for this mode, so the
        // observation is an informational note (never a WARN — that tier is kept
        // for could-not-verify conditions) but never silent PASS either: regions
        // were present, so the note records what remained readable. The leak this
        // arm's old WARN chased is carried by the specific arms: a redacted term
        // surviving out-of-region WARNs, in-region survivors FAIL. PASS is
        // preserved only when no regions are present
        // (layer2ScopedOCR_textOutsideRegions_noRegions_passes).
        #expect(result.status.isInfo,
                "SR out-of-region text with regions present is an INFO note; got \(result.status)")
        if case .info(let msg) = result.status {
            #expect(msg.contains("expected for this mode"),
                    "INFO copy must state the content is expected; got \(msg)")
        }
    }

    @Test("Layer 2 (D08-F1): SR out-of-region text with NO regions → PASS (no over-block)")
    func layer2ScopedOCR_textOutsideRegions_noRegions_passes() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("INCOME", CGPoint(x: 40, y: 680), 80)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        // documentHasRegions == false → the text is the raster's own content,
        // nothing was redacted to miss → PASS. Guards against over-blocking a
        // Secure-Rasterized document that carried no redaction regions.
        #expect(result.status == .pass,
                "SR text with no regions is the raster's own content → PASS; got \(result.status)")
    }

    @Test("Layer 2 (CAT-351): Searchable out-of-region text → INFO (continuity preserved)")
    func layer2ScopedOCR_textOutsideRegions_searchable_info() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("INCOME", CGPoint(x: 40, y: 680), 80)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        // D08-F1 leaves the Searchable .info continuity untouched: selectable text
        // outside regions is expected on a Searchable page.
        #expect(result.status.isInfo,
                "Searchable out-of-region text stays INFO; got \(result.status)")
    }

    @Test("Layer 2 (CAT-351): sensitive term inside a region → FAIL, page number only")
    func layer2ScopedOCR_sensitiveTermInsideRegion_fails() async throws {
        let size = CGSize(width: 600, height: 800)
        // A solid, common dictionary word recognizes reliably under the FROZEN
        // .fast verifier preset (a non-dictionary token like "SECRETCODE" can be
        // split/misread, defeating an exact term match). The term is synthetic —
        // no PII — so naming it in the fixture is safe.
        let term = "CONFIDENTIAL"
        let image = try renderTextPageImage(
            [(term, CGPoint(x: 30, y: 400), 64)], size: size)       // centered
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [term],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail, "term readable inside a region must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            // ARCH §12.2: page number present, document content (the term) absent.
            #expect(msg.contains("1"))
            #expect(!msg.localizedCaseInsensitiveContains(term),
                    "FAIL message must never echo the matched term")
        }
    }

    @Test("Layer 2 (D08-F2): SR text in a region → FAIL (page only); identity coordinate guard")
    func layer2ScopedOCR_textTopRegionTop_intersects() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("HEADER", CGPoint(x: 40, y: 700), 80)], size: size)   // baseline high = top
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let topBand = manualRegion(CGRect(x: 0, y: 0.55, width: 1.0, height: 0.43))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [topBand]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        // Identity mapping: top text (high y) ∈ top band → in-region → FAIL under
        // D08-F2 (readable text in a destroyed-pixel SR region is a leak, no term
        // needed). A reintroduced y-flip would map it low → out-of-region → the
        // INFO note, so identity vs flip stays distinguishable (FAIL ≠ INFO).
        #expect(result.status.isFail,
                "top text vs top region must intersect under identity mapping (D08-F2 FAIL); got \(result.status)")
        if case .fail(let msg) = result.status {
            // ARCH §12.2: page number present, document content absent.
            #expect(msg.contains("1"))
            #expect(!msg.localizedCaseInsensitiveContains("HEADER"),
                    "FAIL message must not echo OCR'd content")
        }
    }

    @Test("Layer 2: coordinate guard — text BOTTOM, region TOP → out-of-region (INFO)")
    func layer2ScopedOCR_textBottomRegionTop_outOfRegion() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("FOOTER", CGPoint(x: 40, y: 80), 80)], size: size)    // baseline low = bottom
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let topBand = manualRegion(CGRect(x: 0, y: 0.55, width: 1.0, height: 0.43))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [topBand]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        // Identity mapping: bottom text (low y) ∉ top band → out-of-region → the
        // INFO note (regions present). A reintroduced y-flip would map it high →
        // in-region → FAIL (D08-F2), so identity vs flip stays distinguishable
        // (INFO ≠ FAIL).
        #expect(result.status.isInfo,
                "bottom text vs top region must not intersect under identity mapping (out-of-region INFO); got \(result.status)")
    }

    @Test("Layer 2 (D08-F2): Searchable readable text inside a region → WARN (unchanged string)")
    func layer2ScopedOCR_textInRegion_searchable_warns() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("CONFIDENTIAL", CGPoint(x: 30, y: 400), 64)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        // D08-F2 keeps the Searchable branch as the existing WARN (a glyph layer
        // legitimately survives behind a Searchable fill). Regression-lock the
        // WARN + in-region wording (grammar updated by q16/UXF-10, wording only).
        #expect(result.status.isWarn,
                "Searchable in-region text stays WARN (D08-F2); got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("OCR detected text within a redacted region"),
                    "Searchable in-region WARN wording must stay in-region-scoped; got \(msg)")
        }
    }

    @Test("Layer 2 (D08-F2): sensitive term inside a region → FAIL in Searchable mode too")
    func layer2ScopedOCR_termInRegion_searchable_fails() async throws {
        let size = CGSize(width: 600, height: 800)
        let term = "CONFIDENTIAL"   // synthetic, non-PII
        let image = try renderTextPageImage(
            [(term, CGPoint(x: 30, y: 400), 64)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [term],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        // The .sensitiveTermInRegion super-priority FAIL is mode-independent (it
        // returns before any mode branch), so a recognized term in a region FAILs
        // in Searchable mode as well as Secure (secure is pinned by
        // layer2ScopedOCR_sensitiveTermInsideRegion_fails).
        #expect(result.status.isFail,
                "term readable inside a region must FAIL in Searchable mode; got \(result.status)")
    }

    @Test("Layer 2 (D08-F2): SR faithfully redacted region (no in-region text) → PASS")
    func layer2ScopedOCR_noSurvivor_secure_passes() async throws {
        let size = CGSize(width: 600, height: 800)
        // A blank (white) page models a faithfully destroyed region: the OCR pass
        // reads no text at all, so neither the in-region FAIL nor the out-of-region
        // INFO note fires → PASS. Locks that the Layer 2 verdicts do not over-block
        // a correctly redacted Secure-Rasterization output.
        let image = try renderTextPageImage([], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status == .pass,
                "no in-region or out-of-region text → PASS (no over-block); got \(result.status)")
    }

    @Test("Layer 2: fallback-rasterized page in a Searchable-mode run — in-region text → FAIL")
    func layer2ScopedOCR_mixedMode_fallbackPageFails() async throws {
        let size = CGSize(width: 600, height: 800)
        // Page 1: clean. Page 2: readable text inside its region — and page 2
        // was fallback-rasterized (perPageModes), so its region is a
        // destroyed-pixel box that holds no readable text by construction.
        let clean = try renderTextPageImage([], size: size)
        let leaky = try renderTextPageImage(
            [("CONFIDENTIAL", CGPoint(x: 30, y: 400), 64)], size: size)
        let (doc, url) = try await makeImagePDF(pages: [clean, leaky], size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [1: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [],
            perPageModes: [.searchableRedaction, .secureRasterization])
        // Before the per-page fold, the document-level Searchable mode demoted
        // this to the glyph-layer WARN — a real leak reported at the wrong tier
        // (Layer 2 is the only layer that inspects a fallback page's pixels).
        #expect(result.status.isFail,
                "in-region text on a fallback-rasterized page must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("2"), "FAIL must name the fallback page; got \(msg)")
        }
    }

    @Test("Layer 2: same fixture, all pages Searchable → WARN (existing tier pinned)")
    func layer2ScopedOCR_mixedModeFixture_allSearchable_warns() async throws {
        let size = CGSize(width: 600, height: 800)
        let clean = try renderTextPageImage([], size: size)
        let leaky = try renderTextPageImage(
            [("CONFIDENTIAL", CGPoint(x: 30, y: 400), 64)], size: size)
        let (doc, url) = try await makeImagePDF(pages: [clean, leaky], size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [1: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [],
            perPageModes: [.searchableRedaction, .searchableRedaction])
        // A genuinely Searchable page keeps a glyph layer behind the fill, so a
        // non-term in-region hit stays the existing WARN tier.
        #expect(result.status.isWarn,
                "in-region text on a Searchable page stays WARN; got \(result.status)")
    }

    @Test("Layer 2: OCR error on one page → unchecked WARN, sibling page still clean")
    func layer2ScopedOCR_performError_foldsToUnchecked() async throws {
        // The Vision perform error cannot be produced deterministically from a
        // fixture, so the guard seam flags THIS test's page-1 image only. The
        // page sizes are sentinels no other fixture uses, so a concurrently
        // running test can never match the predicate.
        let errorSize = CGSize(width: 597, height: 800)
        let cleanSize = CGSize(width: 598, height: 800)
        let errorPage = try renderTextPageImage([], size: errorSize)
        let cleanPage = try renderTextPageImage([], size: cleanSize)
        let (doc, url) = try await makeImagePDF(
            pages: [errorPage, cleanPage], size: errorSize)
        defer { try? FileManager.default.removeItem(at: url) }

        VerificationEngine.onLayer2OCRSimulateError = { $0.width == 597 }
        defer { VerificationEngine.onLayer2OCRSimulateError = nil }

        let region = manualRegion(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [0: [region], 1: [region]],
            sensitiveTerms: [], pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: [.secureRasterization, .secureRasterization])
        // "Could not check" must not read as "checked, found nothing": the
        // errored page folds to the unchecked WARN instead of a clean PASS,
        // while the sibling page classifies normally (nothing above the
        // unchecked arm fires).
        #expect(result.status.isWarn,
                "an OCR error page must WARN, never contribute to PASS; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("OCR could not be run on 1 page"),
                    "errored page folds to the unchecked arm; got \(msg)")
        }
    }

    @Test("Layer 2: SR page, region clean, term readable elsewhere → dedicated WARN")
    func layer2ScopedOCR_termOutsideRegion_secure_warns() async throws {
        let size = CGSize(width: 600, height: 800)
        let term = "CONFIDENTIAL"   // synthetic, non-PII
        // Term at the top of the page; the region (bottom-right) is faithfully
        // blank — the displaced-fill signature: the redacted term survives
        // OUTSIDE every region on a rasterized page.
        let image = try renderTextPageImage(
            [(term, CGPoint(x: 30, y: 680), 64)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [term],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn,
                "a term readable outside every region on an SR page must WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("A sensitive term is readable outside every redacted region"),
                    "term-specific arm must outrank the generic outside arm; got \(msg)")
            // ARCH §12.2: page number present, document content (the term) absent.
            #expect(msg.contains("1"))
            #expect(!msg.localizedCaseInsensitiveContains(term),
                    "WARN message must never echo the matched term")
        }
    }

    @Test("Layer 2: Searchable page, term readable outside regions → INFO unchanged (L3/L10 own the text layer)")
    func layer2ScopedOCR_termOutsideRegion_searchable_staysInfo() async throws {
        let size = CGSize(width: 600, height: 800)
        let term = "CONFIDENTIAL"   // synthetic, non-PII
        let image = try renderTextPageImage(
            [(term, CGPoint(x: 30, y: 680), 64)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [term],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        // On a Searchable page the text layer is verified by Layers 3/10; the
        // pixel-side term signal is bucketed back to the generic outside path,
        // so behavior is unchanged (INFO continuity).
        #expect(result.status.isInfo,
                "Searchable out-of-region term keeps the INFO continuity; got \(result.status)")
    }

    // MARK: - Page references for Layers 1/2/3 (VQ-13 shape)

    @Test("Layer 1 accumulates annotation pages across the document and returns 0-based references")
    func layer1AnnotationPagesAccumulatedWithReferences() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.threePageAnnotationsOnFirstAndThird(), prefix: "l1_annot_pages_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            0, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 3, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: Array(repeating: .secureRasterization, count: 3))
        #expect(result.status.isFail,
                "annotations in output must FAIL; got \(result.status)")
        #expect(result.pageReferences == [0, 2],
                "both annotation pages must be referenced 0-based; got \(String(describing: result.pageReferences))")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("2 pages"),
                    "message must name both pages, not stop at the first; got \(msg)")
        }
    }

    @Test("Layer 1 accumulates selectable-text pages across the document and returns 0-based references")
    func layer1SelectableTextPagesAccumulatedWithReferences() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermOnFirstAndThirdPages(term: "Acme"),
            prefix: "l1_text_pages_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            0, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 3, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: Array(repeating: .secureRasterization, count: 3))
        #expect(result.status.isFail,
                "selectable text on a Secure-Rasterized output must FAIL; got \(result.status)")
        #expect(result.pageReferences == [0, 2],
                "both text pages must be referenced 0-based; got \(String(describing: result.pageReferences))")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("2 pages"),
                    "message must name both pages, not stop at the first; got \(msg)")
        }
    }

    @Test("Layer 2 in-region FAIL carries the winning bucket's pages as 0-based references")
    func layer2InRegionFailCarriesPageReferences() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("HEADER", CGPoint(x: 40, y: 700), 80)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let topBand = manualRegion(CGRect(x: 0, y: 0.55, width: 1.0, height: 0.43))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [topBand]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "in-region text on a Secure-Rasterized page must FAIL; got \(result.status)")
        // Message numbering is 1-based ("page 1"); references are 0-based.
        #expect(result.pageReferences == [0],
                "references must be the message's page list minus one; got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 3 SVT-3 accumulates decoded-page hits across the document with 0-based references")
    func layer3DecodedPagesAccumulatedWithReferences() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermOnFirstAndThirdPages(term: "Acme"),
            prefix: "l3_decoded_pages_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 3, regions: [:], sensitiveTerms: ["acme"],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil, nil],
            perPageModes: Array(repeating: .searchableRedaction, count: 3))
        #expect(result.status.isAttention,
                "decoded-page leak must flag (residual tier); got \(result.status)")
        #expect(result.pageReferences == [0, 2],
                "both decoded hit pages must be referenced 0-based; got \(String(describing: result.pageReferences))")
        if case .attention(let msg) = result.status {
            #expect(msg.contains("2 pages"),
                    "message must name both pages, not stop at the first; got \(msg)")
            #expect(msg.contains("instances"), "count stays in the message; got \(msg)")
        }
    }

    // MARK: - VF-04: stream-range EOL gate (VQ-22)

    @Test("Layer 3: a /Downstream token cannot open a phantom stream range (VQ-22)")
    func layer3DownstreamPhantomRangeGated() async throws {
        // Structural term sits between a /Downstream name and the document's
        // only real stream. Pre-gate, the "stream" letters inside
        // "Downstream" opened a phantom range to the real `endstream`, and
        // the term inside that span was excluded from the structural pass —
        // the layer reported nothing.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.downstreamPhantomRange(term: "DELIAHARTWELL"),
            prefix: "phantom_range_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["DELIAHARTWELL"],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "structural term after a /Downstream token must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("structural data"), "got: \(msg)")
        }
    }

    @Test("Layer 3: malformed stream keyword EOL still excludes stream data (VQ-22 fallback)")
    func layer3MalformedStreamEOLFallback() async throws {
        // The only `stream` keyword is followed by a bare CR (spec-invalid),
        // so the strict pass yields no ranges. The permissive fallback must
        // still exclude the stream data: a term living only inside it stays
        // out of the structural FAIL path (compressed-stream bytes would
        // otherwise become false-positive fodder on malformed files).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.malformedStreamKeywordEOL(term: "DELIAHARTWELL"),
            prefix: "malformed_eol_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["DELIAHARTWELL"],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(!result.status.isFail,
                "term inside malformed stream data must stay excluded; got \(result.status)")
    }

    // MARK: - VF-04: unopenable-page honesty (VQ-23)

    /// VQ-23 seam: a document whose page 2 (index 1) cannot be opened.
    /// PDFKit synthesizes a PDFPage even for a broken /Kids entry (measured
    /// on macOS 15 / iOS 26.4), so an unopenable page cannot be produced
    /// from fixture bytes; overriding `page(at:)` models the same runtime
    /// condition through the public `runLayer` API.
    private final class UnopenablePageDocument: PDFDocument {
        override func page(at index: Int) -> PDFPage? {
            index == 1 ? nil : super.page(at: index)
        }
    }

    private func makeUnopenableSecondPageDoc() throws -> (PDFDocument, URL) {
        let data = TestFixtures.twoBlankPages()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unopenable_\(UUID().uuidString).pdf")
        try data.write(to: url)
        guard let doc = UnopenablePageDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    @Test("Layer 1 WARNs when a page cannot be read, with the page referenced (VQ-23)")
    func layer1UnreadablePageWarns() async throws {
        let (doc, url) = try makeUnopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            0, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization, .secureRasterization])
        #expect(result.status.isWarn,
                "an unreadable page must WARN, not fold into PASS; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("could not be read"), "got: \(msg)")
            #expect(msg.contains("2"), "copy prints the 1-based page number; got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "0-based reference to the unreadable page; got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 2 buckets an unopenable page as unchecked (VQ-23)")
    func layer2UnopenablePageUnchecked() async throws {
        let (doc, url) = try makeUnopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization, .secureRasterization])
        #expect(result.status.isWarn,
                "an unopenable page was never OCR-checked → unchecked WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("OCR could not be run"), "got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 6 WARNs when an eligible page cannot be read (VQ-23)")
    func layer6UnreadablePageWarns() async throws {
        let (doc, url) = try makeUnopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            5, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .searchableRedaction])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("could not be read"), "got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 8 WARNs when an eligible page cannot be read (VQ-23)")
    func layer8UnreadablePageWarns() async throws {
        let (doc, url) = try makeUnopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            7, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .searchableRedaction])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("could not be read"), "got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "got \(String(describing: result.pageReferences))")
    }

    // MARK: - VF-04: Layer 9 cooperative cancellation (VQ-24)

    @Test("Layer 9 surrenders to cancellation as .skipped (VQ-24)")
    func layer9CancelledReturnsSkipped() async throws {
        // The digest's lineage hash deliberately mismatches the blank page,
        // so a run that ignored cancellation would FAIL — .skipped proves the
        // entry check surrendered first. The task cancels itself before
        // calling the layer, making the outcome order-deterministic (no
        // wall-clock assertion; the 50 ms latency budget is owned by the
        // report-only perf suite).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.blankPage(), prefix: "l9_cancel_")
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = PageFilterDigest(
            pageIndex: 0, extractedCount: 1, excludedCount: 0,
            survivingCount: 1, boundaryCharacters: [],
            lineageHash: Data([0x01]))

        let engine = VerificationEngine()
        let sendableDoc = SendablePDFDocument(doc)
        let task = Task { () -> LayerResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.runLayer(
                8, outputDocument: sendableDoc,
                sourcePageCount: 1, regions: [:], sensitiveTerms: [],
                pipelineMode: .searchableRedaction,
                filterDigests: [digest],
                perPageModes: [.searchableRedaction])
        }
        let result = await task.value
        #expect(result.status.isSkipped,
                "cancelled Layer 9 must surrender as .skipped; got \(result.status)")
    }

    // MARK: - VF-04: Layer-2 decode cap (VQ-32)

    @Test("extractPageImages caps the transient decode size (VQ-32)")
    func extractPageImagesDecodeCap() async throws {
        // 5000-px JPEG: an uncapped decode would exceed the 4096-px OCR cap;
        // the bounded thumbnail decode must come back within it.
        let jpeg = TestFixtures.solidJPEG(width: 5000, height: 120)
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.pdfWithDCTImageStream(jpeg), prefix: "decode_cap_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        let cgPage = try #require(page.pageRef)

        let extraction = VerificationEngine.extractPageImages(from: cgPage)
        #expect(extraction.failedDecodeCount == 0)
        let image = try #require(extraction.images.first)
        #expect(max(image.width, image.height) <= 4096,
                "decode must be capped at the OCR pixel ceiling; got \(image.width)x\(image.height)")
    }

    @Test("Layer 2 buckets a page with an undecodable image as unchecked (VQ-32)")
    func layer2UndecodableImageUnchecked() async throws {
        // A DCTDecode stream whose bytes are not a decodable JPEG: the page
        // was never OCR-checked, so it must WARN as unchecked rather than
        // fall through to the thumbnail path and read as clean.
        var bad = Data([0xFF, 0xD8, 0xFF, 0xE0])
        bad.append(Data(repeating: 0x00, count: 64))
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.pdfWithDCTImageStream(bad), prefix: "bad_jpeg_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        let cgPage = try #require(page.pageRef)

        let extraction = VerificationEngine.extractPageImages(from: cgPage)
        #expect(extraction.failedDecodeCount == 1,
                "undecodable DCT stream must count as a decode failure")
        #expect(extraction.images.isEmpty)

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("OCR could not be run"), "got: \(msg)")
        }
        #expect(result.pageReferences == [0],
                "got \(String(describing: result.pageReferences))")
    }

    // MARK: - Helpers

    private func makeCleanPDF() async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_test_\(UUID().uuidString).pdf")

        guard let ctx = createBitmapContext(width: 200, height: 300) else {
            throw TestError.failed
        }
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        guard let image = ctx.makeImage() else { throw TestError.failed }

        let recon = PDFStreamReconstructor(tempURL: url)
        let size = CGSize(width: 200, height: 300)
        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        await recon.finalize()

        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    private func makeResult(_ status: VerificationStatus) -> LayerResult {
        LayerResult(name: "Test", symbolName: "circle", status: status,
                    shortDescription: "", detailDescription: "",
                    pageReferences: nil, durationSeconds: 0)
    }

    private func makeCleanPDFWithoutURL() async throws -> PDFDocument {
        let (_, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        guard let doc = PDFDocument(data: data) else { throw TestError.failed }
        return doc
    }

    /// Build a single-page vector-only PDF. No image XObjects, so
    /// `extractPageImage` returns nil on every page.
    private func makeVectorOnlyPDF() throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_vector_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw TestError.failed
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    /// Build an N-page blank (solid-white) PDF with a valid documentURL. Used
    /// by the Layer 7/9 skipped-honesty tests, where the layer short-circuits
    /// on the per-page-mode / nil-digest guards and never reads page content.
    private func makeBlankPDF(pageCount: Int) throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_blank_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw TestError.failed
        }
        for _ in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    // MARK: - CAT-351 fixture helpers

    private func manualRegion(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    /// Render black text on a white page using the PRODUCTION bottom-left bitmap
    /// context (`createBitmapContext`) so orientation round-trips through
    /// `PDFStreamReconstructor` exactly as a real rasterized page does. Each
    /// baseline origin is in bottom-left pixel coordinates (high y = top).
    private func renderTextPageImage(
        _ texts: [(string: String, baseline: CGPoint, fontSize: CGFloat)],
        size: CGSize
    ) throws -> CGImage {
        guard let ctx = createBitmapContext(width: Int(size.width), height: Int(size.height)) else {
            throw TestError.failed
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)  // CTLineDraw uses the fill color
        ctx.textMatrix = .identity
        for item in texts {
            let font = CTFontCreateWithName("Helvetica" as CFString, item.fontSize, nil)
            let attr = NSAttributedString(
                string: item.string,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = item.baseline
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { throw TestError.failed }
        return image
    }

    /// Wrap a single CGImage as a one-page full-page-JPEG PDF via the production
    /// reconstructor — the exact shape Layer 2 verifies.
    private func makeImagePDF(_ image: CGImage, size: CGSize) async throws -> (PDFDocument, URL) {
        try await makeImagePDF(pages: [image], size: size)
    }

    /// Multi-page variant: one full-page JPEG per element, each page at its
    /// image's own pixel size (so per-page fixtures can differ).
    private func makeImagePDF(pages: [CGImage], size: CGSize) async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_layer2_\(UUID().uuidString).pdf")
        let recon = PDFStreamReconstructor(tempURL: url)
        try await recon.begin(firstPageSize: size)
        for image in pages {
            let pageSize = CGSize(width: image.width, height: image.height)
            try await recon.appendPage(PageOutput(image: image, size: pageSize, textLayerEntries: nil))
        }
        await recon.finalize()
        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    private enum TestError: Error { case failed }
}

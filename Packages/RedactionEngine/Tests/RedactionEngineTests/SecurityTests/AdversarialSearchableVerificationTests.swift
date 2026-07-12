import Testing
import Foundation
import PDFKit
import CryptoKit
@testable import RedactionEngine

// Adversarial fixtures for the Searchable Redaction trust-parity refactor.
// See the trust-parity plan §5 (Red-Team Findings) and §6 (Adversarial
// Test Suite). Each test cites its RT-N row.
//
// M1: Layer 3/6/8 tightenings + Layer 9 lineage. RT-3, RT-4, RT-5,
// RT-7 (Layer 3 octal/literal variants), RT-9 are green.
// M2: per-character monospace grid. RT-1 (Bland kerning via Layer 6 SVT-1)
// and RT-2 (width-fingerprint collapse) are green.
// M3: Layer 10 operator-semantic re-extraction. RT-7 surrogate-pair and
// the operator-decoded view of RT-7 octal are reported by Layer 10; RT-8
// Name-object substitution flips from documented gap to active FAIL.

@Suite("Adversarial Searchable Verification", .tags(.security, .sandwich))
struct AdversarialSearchableVerificationTests {

    private let engine = VerificationEngine()
    private let sandwichVerifier = SandwichVerification()

    // MARK: - RT-4: /ToUnicode CMap policy (Layer 8 SVT-4, J-5 refined)

    @Test("RT-4: Layer 8 FAILs on /ToUnicode CMap on an unaccepted font",
          .tags(.critical))
    func rt4Layer8FailsOnToUnicode() async throws {
        // Re-pointed under the J-5 SVT-4 refinement (2026-06-09). The
        // original fixture put the CMap on an ACCEPTED Courier-suffixed
        // subset, which the refined SVT-4 tolerates as a writer-emitted,
        // load-bearing CMap (see rt4AcceptedSubsetCMapResidualNote). The
        // surviving RT-4-class structural detection: a /ToUnicode-bearing
        // font whose /BaseFont is NOT an accepted CGPDFContext monospace
        // subset — the unchanged accept-check FAILs it, CMap or no CMap.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withToUnicodeOnUnacceptedFont(),
            prefix: "rt4_tounicode_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            7,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(result.status == .fail(""),
                "Layer 8 must FAIL when a /ToUnicode-bearing font has an unaccepted BaseFont")
    }

    @Test("RT-4 residual: writer-emitted /ToUnicode on an accepted subset is tolerated (J-5)")
    func rt4AcceptedSubsetCMapResidualNote() async throws {
        // Documented residual (J-5, approved 2026-06-09): SVT-4 tolerates a
        // /ToUnicode CMap when the font's /BaseFont passed the accept-check.
        // Rationale (fix-plan §3.4): an Apple-writer-emitted CMap on a fresh
        // accepted subset maps only the drawn surviving glyphs — redacted
        // content was filtered before drawing and never embedded — and the
        // CMap is load-bearing for encoding-external glyph extraction
        // (EXP-E6.2); Layer 3 SVT-3 and Layer 10 SVT-5 independently cover
        // content/operator leakage. The given-up detection — a hand-injected
        // content-divergent CMap on a spoofed accepted BaseFont — requires
        // post-export tampering, outside the threat boundary (RT-6). This
        // test pins the tolerance as INTENTIONAL, not a regression.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withToUnicodeOnReconstructedFont(),
            prefix: "rt4_residual_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            7,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(result.status.isFail == false,
                "Layer 8 tolerates the accepted-subset CMap (J-5 documented residual)")
    }

    // MARK: - RT-5 / H3: Character lineage round-trip (Layer 9 SVT-2)
    //
    // H3 (closed): the pre-redesign PASS test compared `outputHash` to itself
    // (tautological), so H1/N1/N2 hash-domain bugs shipped undetected. The
    // tests below drive a real source PDF through `extractCharacters →
    // FilterResult.computeLineageHash → drawInvisibleTextLayer →
    // computeOutputLineageHash`, then assert filter and verifier agree.
    // Post-H1 redesign: the hash domain is `(character.utf8, globalPos)` per
    // composed character, dropping position fields entirely. Layer 6 owns
    // spatial tampering. See ENGINE §6.6 SVT-2.

    @Test("RT-5/H3: Layer 9 round-trip — Courier ASCII source",
          .tags(.critical))
    func rt5Layer9RoundTripCourierAscii() async throws {
        try await assertLayer9RoundTripAgreement(
            sourceData: TestFixtures.courierTextLayerPDF(text: "HELLO WORLD")
        )
    }

    @Test("RT-5/H3: Layer 9 round-trip — descender-heavy text (H1 surface)",
          .tags(.critical))
    func rt5Layer9RoundTripDescenderHeavy() async throws {
        // Pre-H1, descender glyphs (gpqy j) reported `bounds.minY` ~2.5pt
        // below same-line ascenders; the filter snapped one `runY` per run
        // while the verifier snapped per character, so the snapped cells
        // could disagree. Post-redesign, position is not hashed and the
        // round-trip agrees on any baseline.
        try await assertLayer9RoundTripAgreement(
            sourceData: TestFixtures.descenderHeavyTextLayerPDF()
        )
    }

    @Test("RT-5/H3: Layer 9 round-trip — non-Courier source font",
          .tags(.critical))
    func rt5Layer9RoundTripNonCourierSource() async throws {
        // Helvetica's descent differs from Courier's; pre-redesign this
        // shifted source-side `bounds.minY` relative to output-side
        // Courier-rendered `bounds.minY`, producing snapped-cell mismatch.
        // Post-redesign, the hash is font-metric-independent.
        try await assertLayer9RoundTripAgreement(
            sourceData: TestFixtures.nonCourierSourceTextLayerPDF()
        )
    }

    @Test("RT-5/H3: Layer 9 round-trip — multi-paragraph (N2 surface)",
          .tags(.critical))
    func rt5Layer9RoundTripMultiParagraph() async throws {
        // groupIntoRuns produces multiple runs; PDFKit may synthesize
        // inter-run whitespace on the output side. Pre-redesign this was
        // untested; the zero-bounds skip on the verifier is the only
        // safeguard. Post-redesign, the same zero-bounds skip applies and
        // the globalPos counter only advances on emitted characters.
        try await assertLayer9RoundTripAgreement(
            sourceData: TestFixtures.multiParagraphTextLayerPDF()
        )
    }

    @Test("RT-5/H3: Layer 9 round-trip — composed-character sequence (N1)",
          .tags(.critical))
    func rt5Layer9RoundTripComposedSequence() async throws {
        // Regional-indicator pair (`\u{1F1FA}\u{1F1F8}` = US flag) sits in
        // ASCII context. Pre-redesign, filter iterated Swift `Character` and
        // verifier iterated NSString composed sequences — these can diverge
        // on emoji ZWJ / regional indicators. Post-redesign, both sides use
        // NSString composed sequences so the iteration unit is the same.
        //
        // Note: Courier has no glyph for the regional indicators; CoreText
        // font fallback substitutes a different font, and PDFKit's
        // outputPage.string reports the substituted characters. Both
        // filter and verifier walk the SAME composed-character iteration
        // unit, so the hashes agree iff the substituted output preserves
        // the codepoint sequence — which CoreText's fallback discipline
        // does on iOS 26.
        try await assertLayer9RoundTripAgreement(
            sourceData: TestFixtures.composedSequenceTextLayerPDF()
        )
    }

    @Test("RT-5/H3: Layer 9 round-trip helper drives a non-tautological agreement test")
    func rt5Layer9RoundTripHelperIsNotTautological() async throws {
        // Sanity guard for the round-trip helper itself: a non-empty
        // surviving character set must produce a non-empty lineage hash on
        // both sides. If the helper degenerated to comparing two empty
        // hashes, every test above would silently pass. This assertion
        // pins the precondition: the hashes are real SHA-256 outputs over
        // emitted character sequences, not empty `Data()`.
        let sourceData = TestFixtures.courierTextLayerPDF(text: "X")
        let (sourceDoc, sourceURL) = try TestFixtures.writeTempPDF(
            sourceData, prefix: "rt5_sanity_"
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourcePage = try #require(sourceDoc.page(at: 0))

        let extractor = TextLayerExtractor()
        let chars = try await extractor.extractCharacters(from: sourcePage)
        #expect(!chars.isEmpty,
                "Sanity fixture must yield at least one CharacterInfo")
        let filterHash = FilterResult.computeLineageHash(over: chars)
        #expect(!filterHash.isEmpty,
                "Filter hash must be non-empty for a non-empty surviving set")
        #expect(filterHash.count == 32,
                "Filter hash must be a 32-byte SHA-256 output")
    }

    @Test("RT-5: Layer 9 FAILs on reordered output sequence",
          .tags(.critical))
    func rt5Layer9FailsOnReorder() async throws {
        // Filter side records "HELLO" — the digest's lineage hash is bound
        // to that exact sequence. The output PDF, however, renders the
        // reverse sequence "OLLEH"; the verifier's recomputed hash differs
        // and Layer 9 reports mismatch.
        let filterChars = makeCharInfos(for: "HELLO")
        let digest = PageFilterDigest(
            pageIndex: 0,
            extractedCount: 5, excludedCount: 0, survivingCount: 5,
            boundaryCharacters: [],
            lineageHash: FilterResult.computeLineageHash(over: filterChars)
        )

        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.courierTextLayerPDF(text: "OLLEH"),
            prefix: "rt5_reorder_"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))

        let result = try await sandwichVerifier.verifyCharacterLineage(
            outputPage: page, digest: digest
        )
        #expect(result == .fail(""),
                "Layer 9 must FAIL when output sequence differs from filter digest")
    }

    @Test("RT-5: Layer 9 FAILs on character insertion (visible glyph)")
    func rt5Layer9FailsOnCharacterInsertion() async throws {
        // Filter side: "ABC" (3 chars). Output side: "AXBC" — a visible
        // glyph X is rendered into the text layer between A and B. The
        // verifier's recomputed hash diverges from the filter's hash.
        //
        // Documented residual (M4): zero-width insertions (U+200B / U+FEFF)
        // are not surfaced by Layer 9 because both filter and verifier
        // iterate non-zero-bounds composed characters only (mirroring
        // `extractCharacters`). Layer 3 SVT-3 and Layer 10 SVT-5 surface
        // zero-width insertions that carry sensitive terms via independent
        // decoders; pure steganographic zero-width injection is bounded by
        // the threat model (post-export tampering on Resecta's own output).
        let filterChars = makeCharInfos(for: "ABC")
        let digest = PageFilterDigest(
            pageIndex: 0,
            extractedCount: 3, excludedCount: 0, survivingCount: 3,
            boundaryCharacters: [],
            lineageHash: FilterResult.computeLineageHash(over: filterChars)
        )

        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.courierTextLayerPDF(text: "AXBC"),
            prefix: "rt5_insert_"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))

        let result = try await sandwichVerifier.verifyCharacterLineage(
            outputPage: page, digest: digest
        )
        #expect(result == .fail(""),
                "Layer 9 must FAIL when a visible glyph is injected into the output sequence")
    }

    @Test("RT-5: Layer 9 PASSes when digest has empty lineage hash")
    func rt5Layer9PassesOnEmptyDigest() async throws {
        // A filter that recorded no surviving characters produces an empty
        // lineage hash. The verifier short-circuits to PASS; the
        // corresponding output page is expected to have no composed
        // characters of its own (the page consists of the rasterized
        // image only).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.imageOnlyPDF(),
            prefix: "rt5_empty_"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))

        let digest = PageFilterDigest(
            pageIndex: 0,
            extractedCount: 0, excludedCount: 0, survivingCount: 0,
            boundaryCharacters: [],
            lineageHash: Data()
        )
        let result = try await sandwichVerifier.verifyCharacterLineage(
            outputPage: page, digest: digest
        )
        #expect(result == .pass,
                "Layer 9 must PASS when the filter recorded no surviving characters")
    }

    // MARK: - RT-7: Encoding tricks defeated by Layer 3 SVT-3

    @Test("RT-7: Layer 3 flags sensitive term in text-show stream (residual tier)")
    func rt7Layer3FailsOnTermInTextStream() async throws {
        let term = "MYSECRET"
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermInTextStream(term: term),
            prefix: "rt7_stream_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            2,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [term],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(result.status == .attention(""),
                "Layer 3 SVT-3 tightening must flag a term that lives only inside a text-show stream (residual tier)")
    }

    @Test("RT-7: Layer 3 flags octal-escape-encoded sensitive term (residual tier)")
    func rt7Layer3FailsOnOctalEscape() async throws {
        let term = "PHIDATA"
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withOctalEscapedSensitiveTerm(term: term),
            prefix: "rt7_octal_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            2,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [term],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(result.status == .attention(""),
                "Layer 3 SVT-3 tightening must flag an octal-escape-encoded term in a stream (residual tier)")
    }

    // MARK: - RT-9: Oracle resistance (status-message discipline)

    @Test("RT-9: Layer 3 message reports count only, never term content")
    func rt9Layer3MessageIsContentIndependent() async throws {
        // Two different sensitive terms must produce identical FAIL
        // messages save for the page index and match count. The status
        // surface does not vary with redacted content (ARCH §12.2). The
        // attacker probing the engine learns at most that *some* term
        // matched on page N — not which one.
        let termA = "TERMABC"
        let termB = "TERMXYZ"
        let (docA, urlA) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermInTextStream(term: termA),
            prefix: "rt9_a_"
        )
        let (docB, urlB) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermInTextStream(term: termB),
            prefix: "rt9_b_"
        )
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let resultA = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(docA),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [termA],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        let resultB = await engine.runLayer(
            2, outputDocument: SendablePDFDocument(docB),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [termB],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(resultA.status.isAttention && resultB.status.isAttention)
        if case .attention(let msgA) = resultA.status,
           case .attention(let msgB) = resultB.status {
            #expect(!msgA.contains(termA),
                    "Layer 3 message must not echo the matched term (oracle resistance)")
            #expect(!msgB.contains(termB),
                    "Layer 3 message must not echo the matched term (oracle resistance)")
            #expect(msgA == msgB,
                    "Layer 3 message must be content-independent for equivalent attacks")
        }
    }

    // MARK: - RT-3: Snap-direction residual (documented)

    @Test("RT-3: snap-direction residual is bounded by raster precision (documentation)")
    func rt3SnapDirectionResidualNote() async throws {
        // Plan §3.2: a grid-snapped origin reveals at most one bit per run
        // edge of "snap up" vs. "snap down". That bit budget is a strict
        // subset of the bits the current 0.1pt encoding already exposes
        // (~13 bits per run width → ~2 bits per run edge under the grid).
        // The residual is accepted because it does not exceed the
        // visible-raster-fill leak inherent to Secure Rasterization at
        // 300 DPI (0.085mm ≈ 0.24pt per fill-edge).
        //
        // M1 ships the lineage hash; the grid lands in M2. This test is a
        // sentinel that the residual exists and is bounded — it asserts
        // the known constants line up. If the grid constant or the raster
        // DPI is changed without re-evaluating the residual, the
        // arithmetic below changes and the test fires.
        let cellWidthPt = SandwichVerification.courierAdvancePerPoint * 12.0
        #expect(abs(cellWidthPt - 7.20117_1875) < 0.001,
                "M2 grid cell width must remain 0.60009765625 × 12pt = 7.20…pt")
        let rasterPrecisionAt300DPIPt = 72.0 / 300.0
        #expect(rasterPrecisionAt300DPIPt < cellWidthPt,
                "Raster precision at 300 DPI must remain finer than the grid cell")
    }

    // MARK: - RT-6: Font subset glyph-tampering (documented residual)

    @Test("RT-6: font subset tampering residual is documented for V1.1 (Layer 11)")
    func rt6FontSubsetTamperingResidualNote() async throws {
        // Plan §4.6: Layer 11 (font subset enumeration via TrueType cmap
        // parsing) defeats the attack where an embedded Courier subset
        // carries extra glyphs for redacted characters. V1.0 accepts the
        // residual because the attack requires post-export tampering
        // outside Resecta's threat boundary; the writer is CGPDFContext
        // (Apple-maintained) and EXP-E5.1/EXP-E6.2 document the emitted
        // subset shape. Tracked for a future release.
        //
        // The test does not construct a tampered subset (that would
        // require a TrueType writer) — it asserts the accepted Courier
        // suffix set is closed under the names Layer 8 recognises, so a
        // future Layer 11 implementation can layer cmap inspection on top
        // without renaming the accept channel.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withToUnicodeOnReconstructedFont(),
            prefix: "rt6_residual_"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))

        // The fixture's Courier-suffixed name passes Layer 8's accept
        // channel, and per the J-5 refinement (2026-06-09) its writer-
        // emitted /ToUnicode is tolerated rather than reported — so this
        // fixture now documents BOTH Layer-11-deferred residuals: subset
        // glyph tampering AND a content-divergent CMap on a spoofed
        // accepted name (each requires post-export tampering, outside the
        // V1.0 threat boundary). A non-FAIL here is the accept channel
        // admitting the name — the property Layer 11 will extend.
        let result = try await sandwichVerifier.verifyFontsAreMonospace(
            outputPage: page, pageIndex: 0
        )
        #expect(!result.isFail,
                "Layer 8's accept channel admits the Courier-suffixed name and J-5 tolerates its CMap; Layer 11 V1.1 extends the same enumeration with cmap inspection")
    }

    // MARK: - RT-7: Layer 10 operator-semantic re-extraction (M3)

    @Test("RT-7: Layer 10 flags surrogate-pair-encoded sensitive term (residual tier)",
          .tags(.critical))
    func rt7Layer10FailsOnSurrogatePair() async throws {
        // Plan §5 RT-7 / §4.5: a sensitive term encoded as UTF-16
        // surrogate-pair halves inside a Tj literal-string operand is
        // reported by Layer 10 via the `CGPDFStringCopyTextString` decoder,
        // independent of PDFKit's `page.string` view (Layer 3 SVT-3). The
        // two decoders pair as a cross-check: a divergence between them
        // would surface as a mismatch between layers.
        let term = "PHIDATA"
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSurrogatePairSensitiveTerm(term: term),
            prefix: "rt7_surrogate_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            9,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [term],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(result.status == .attention(""),
                "Layer 10 SVT-5 must flag a UTF-16 surrogate-pair-encoded term in a Tj literal-string operand (residual tier)")
    }

    @Test("RT-7: Layer 10 flags octal-escape-encoded sensitive term (residual tier)",
          .tags(.critical))
    func rt7Layer10FailsOnOctalEscape() async throws {
        // Plan §5 RT-7 / §4.5: parallel coverage at Layer 10 for the same
        // encoding family Layer 3 SVT-3 surfaces via `page.string`. The two
        // layers act as independent decoders against the same content
        // stream — defense-in-depth.
        let term = "PHIDATA"
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withOctalEscapedSensitiveTerm(term: term),
            prefix: "rt7_l10_octal_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            9,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [term],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(result.status == .attention(""),
                "Layer 10 SVT-5 must flag an octal-escape-encoded term — independently of Layer 3 SVT-3's decoded-page.string view (residual tier)")
    }

    @Test("Layer 10 flags a case variant of the term in operator text, counted once",
          .tags(.critical))
    func layer10CaseVariantCountedOnce() async throws {
        // The user's query is contributed as typed ("acme"); a Title Case
        // occurrence ("Acme") surviving in a Tj operand must FAIL, and one
        // physical occurrence must report one match — not one per
        // case/encoding pattern variant.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermInTextStream(term: "Acme"),
            prefix: "l10_case_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            9,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: ["acme"],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(result.status.isAttention,
                "Layer 10 must flag a Title Case occurrence of a lowercase query (residual tier)")
        if case .attention(let msg) = result.status {
            #expect(msg.contains("(1 instance)"),
                    "one physical occurrence must count once; got: \(msg)")
        }
        #expect(result.reviewTermTexts == ["acme"],
                "display-only term texts carry the source term for the results UI")
    }

    @Test("Layer 10 reports a partial term drop on the otherwise-clean path")
    func layer10PartialShortTermDropSurfaced() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.imageOnlyPDF(),
            prefix: "l10_drop_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        // "zzqx" is searched (and clean); "ab" is too short — the drop must
        // surface as INFO, mirroring Layer 3.
        let result = await sandwichVerifier.verifyTextOperatorSemantics(
            outputDocument: SendablePDFDocument(doc),
            sensitiveTerms: ["zzqx", "ab"]
        )
        #expect(result.isInfo,
                "partial short-term drop must surface as INFO; got \(result)")
        if case .info(let msg) = result {
            #expect(msg.contains("1 term too short to check"), "got: \(msg)")
        }
    }

    @Test("Layer 10 reports INFO when no sensitive terms provided (VQ-30)")
    func layer10InfoOnEmptyTerms() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.imageOnlyPDF(),
            prefix: "l10_noterms_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        // Manual-only redaction: no operator-semantic search ran, so the
        // layer must say so (INFO) rather than claim "No issues found"
        // (mirrors Layer 3's VQ-30 guard).
        let result = await sandwichVerifier.verifyTextOperatorSemantics(
            outputDocument: SendablePDFDocument(doc),
            sensitiveTerms: []
        ).status
        #expect(result.isInfo,
                "empty terms → INFO, not PASS; got \(result)")
        if case .info(let msg) = result {
            #expect(msg.contains("string search did not run"), "got: \(msg)")
        }
    }

    @Test("Layer 10 WARNs when all sensitive terms are too short (VQ-30)")
    func layer10AllShortTermsWarn() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.imageOnlyPDF(),
            prefix: "l10_allshort_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        // All-short terms previously read as a clean PASS here while Layer 3
        // WARNed on the identical input — the tiers now match.
        let result = await sandwichVerifier.verifyTextOperatorSemantics(
            outputDocument: SendablePDFDocument(doc),
            sensitiveTerms: ["ab", "xy"]
        )
        #expect(result.isWarn,
                "all-short terms → WARN, matching Layer 3; got \(result)")
    }

    @Test("Layer 9 lineage walk surrenders to cooperative cancellation (VQ-24)")
    func layer9LineageCancellation() async throws {
        // The task cancels itself before calling the verifier, so the entry
        // check must throw CancellationError deterministically (no wall-clock
        // dependence). A run that ignored cancellation would return FAIL
        // (mismatched hash) or PASS — either records `false` below.
        let observed = await Task { () -> Bool in
            do {
                let (doc, url) = try TestFixtures.writeTempPDF(
                    TestFixtures.blankPage(), prefix: "l9_lineage_cancel_")
                defer { try? FileManager.default.removeItem(at: url) }
                guard let page = doc.page(at: 0) else { return false }
                let digest = PageFilterDigest(
                    pageIndex: 0, extractedCount: 1, excludedCount: 0,
                    survivingCount: 1, boundaryCharacters: [],
                    lineageHash: Data([0x01]))
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await SandwichVerification().verifyCharacterLineage(
                    outputPage: page, digest: digest)
                return false
            } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
                return true
            } catch { // LegalPhrases:safe (Swift keyword)
                return false
            }
        }.value
        #expect(observed,
                "verifyCharacterLineage must surface CancellationError under a cancelled task")
    }

    // MARK: - RT-8: Name-object substitution (Layer 10 SVT-5, M3)

    @Test("RT-8: Layer 10 flags Name-object Tj substitution (residual tier)",
          .tags(.critical))
    func rt8Layer10FailsOnNameObjectSubstitution() async throws {
        // Plan §5 RT-8 / §4.5: a term encoded as `/SSN` (a Name object)
        // rather than `(SSN)` (a literal string) does not surface through
        // PDFKit's `page.string` decoder. Pre-M3, no layer reported the
        // attack. Layer 10 SVT-5 walks the content stream via
        // `CGPDFScanner` + `CGPDFOperatorTable` and pops the Tj operand
        // via `CGPDFScannerPopString`, which surfaces the Name's bytes via
        // `CGPDFStringCopyTextString`. M3 closes this gap.
        let term = "SSN"
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withNameObjectTermInjection(term: term),
            prefix: "rt8_name_"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await engine.runLayer(
            9,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [term],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction]
        )
        #expect(result.status == .attention(""),
                "Layer 10 SVT-5 must flag a Name-object Tj operand whose name matches a sensitive term (residual tier)")
    }

    // MARK: - RT-1 / RT-2: width-fingerprint defeats (M2 grid)

    @Test("RT-1: Bland kerning injection reports non-uniform advances via Layer 6 SVT-1",
          .tags(.critical))
    func rt1Layer6FailsOnBlandKerning() async throws {
        // Plan §5 RT-1: the M2 reconstructor emits only `Tj` operators at
        // grid-aligned origins, so the Bland–Iyer–Levchenko TJ-kerning
        // attack cannot arise inside Resecta's own output. This fixture
        // simulates an attacker post-processing the sandwich PDF to inject
        // TJ kerning. Layer 6 SVT-1 (advance-width crosscheck on the
        // Courier-suffixed font) reports the per-character bounds as
        // deviating from `0.60009765625 × fontSize`.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withBlandKerningInjection(),
            prefix: "rt1_kerning_"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))

        // verifySpatialExclusion short-circuits when regionShapes is empty;
        // supply a dummy off-page rect so the SVT-1 per-character crosscheck
        // runs without producing a spatial intersection FAIL.
        let result = try await sandwichVerifier.verifySpatialExclusion(
            outputPage: page,
            redactionRects: [CGRect(x: 0, y: 0, width: 1, height: 1)],
            safetyMargin: 0,
            pageIndex: 0
        )
        #expect(result.isFail,
                "Layer 6 SVT-1 must FAIL on a Courier sandwich with TJ kerning injection")
    }

    @Test("RT-2: Width fingerprint collapses to cell-grid origins under the M2 grid",
          .tags(.critical))
    func rt2WidthFingerprintReducesToCellGrid() {
        // Plan §5 RT-2: the grid emits cell-quantized origins, so total
        // run width = `cellCount × cellWidth` — a function of character
        // count only. Synthesises 100 single-run inputs at the same start
        // X but with varying per-character widths in the source
        // `CharacterInfo`; the reconstructor's `groupIntoRuns` drops the
        // per-char widths and produces identical output positions for all
        // 100 runs, collapsing the width-fingerprint channel to the
        // inherent character-count channel already in Secure Rasterization.
        let charCount = 5
        let cellWidth = TextLayerReconstructor.cellWidth
        let baseStartX: CGFloat = 72.0
        let expectedOriginX = floor(baseStartX / cellWidth) * cellWidth

        let alphabet = Array("ABCDE")
        let widthCatalog: [CGFloat] = [4, 6, 8, 10, 12, 14, 16]

        for runIdx in 0..<100 {
            let perCharWidth = widthCatalog[runIdx % widthCatalog.count]
            var characters: [CharacterInfo] = []
            var x: CGFloat = baseStartX
            for c in 0..<charCount {
                characters.append(CharacterInfo(
                    character: String(alphabet[c]),
                    bounds: CGRect(x: x, y: 700, width: perCharWidth, height: 12),
                    stringIndex: c
                ))
                x += perCharWidth
            }
            let runs = TextLayerReconstructor.groupIntoRuns(characters)
            #expect(runs.count == 1,
                    "Run \(runIdx): \(charCount) adjacent characters group into one run")
            #expect(runs[0].origin.x == expectedOriginX,
                    "Run \(runIdx): origin X must snap to \(expectedOriginX) regardless of source per-character widths")
            #expect(runs[0].text.count == charCount,
                    "Run \(runIdx): text length equals input character count")
        }
    }

    // MARK: - Helpers

    /// Build a `CharacterInfo` array from a string. Origin and bounds are
    /// indicative — `groupIntoRuns` consumes them for sorting/grouping but
    /// the post-redesign lineage hash does not fold position fields. Each
    /// Swift Character maps to one `CharacterInfo` entry; for ASCII this
    /// matches the NSString composed-character-sequence iteration the
    /// production extractor uses.
    private func makeCharInfos(for text: String) -> [CharacterInfo] {
        var infos: [CharacterInfo] = []
        var x: CGFloat = 72
        for (i, scalar) in text.enumerated() {
            infos.append(CharacterInfo(
                character: String(scalar),
                bounds: CGRect(x: x, y: 700, width: 7, height: 12),
                stringIndex: i
            ))
            x += 7
        }
        return infos
    }

    /// Drive the full filter → reconstructor → verifier path on a source PDF
    /// and assert filter and verifier lineage hashes agree. The source is
    /// loaded via `PDFDocument(data:)` so `documentURL == nil` (matching
    /// production import paths after the M1 fix); the M1 OCG flag defaults
    /// to `false` because none of these fixtures carry hidden OCGs.
    ///
    /// Post-H1: the hash domain is content + ordering only, so any
    /// difference between filter (`extractCharacters` on the source) and
    /// verifier (`outputPage.string` on the reconstructed page) in the
    /// composed-character sequence is what flips the hash.
    private func assertLayer9RoundTripAgreement(
        sourceData: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let sourceDoc = try #require(PDFDocument(data: sourceData),
                                     sourceLocation: sourceLocation)
        let sourcePage = try #require(sourceDoc.page(at: 0),
                                      sourceLocation: sourceLocation)
        let pageSize = sourcePage.bounds(for: .mediaBox).size

        let extractor = TextLayerExtractor()
        let chars = try await extractor.extractCharacters(from: sourcePage)
        #expect(!chars.isEmpty,
                "Round-trip source fixture must yield CharacterInfo entries",
                sourceLocation: sourceLocation)
        let filterHash = FilterResult.computeLineageHash(over: chars)

        let outputData = try renderInvisibleTextLayer(
            characters: chars, pageSize: pageSize
        )
        let outputDoc = try #require(PDFDocument(data: outputData),
                                     sourceLocation: sourceLocation)
        let outputPage = try #require(outputDoc.page(at: 0),
                                      sourceLocation: sourceLocation)

        let outputHash = try SandwichVerification.computeOutputLineageHash(outputPage)
        #expect(filterHash == outputHash,
                "Layer 9 lineage hash must agree on a non-tampered round-trip",
                sourceLocation: sourceLocation)
    }

    /// Render the invisible Courier text layer for a `[CharacterInfo]` array
    /// onto a fresh CGPDFContext-backed page and return the PDF data. Used
    /// by `assertLayer9RoundTripAgreement` so the verifier reads the same
    /// reconstructor output the production pipeline would write.
    private func renderInvisibleTextLayer(
        characters: [CharacterInfo],
        pageSize: CGSize
    ) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt5_h3_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw RoundTripError.cannotCreatePDFContext
        }
        ctx.beginPDFPage(nil)
        TextLayerReconstructor.drawInvisibleTextLayer(
            context: ctx, entries: characters,
            pageWidth: pageSize.width
        )
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    private enum RoundTripError: Error {
        case cannotCreatePDFContext
    }
}

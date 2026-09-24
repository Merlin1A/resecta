import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// `LayerResult.couldNotVerify` — the engine-side classification of a WARN
// that says the check did not fully run (pages it could not read or open,
// OCR it could not run or map, terms it could not search, positions it
// could not measure, per-page data it lacked), as opposed to a WARN that
// reports what the check saw (a graze, a count excess, a structural or
// metadata note, an attestation mismatch). Never true on a non-WARN status.
//
// Table: for every reachable could-not-verify site a fixture that trips it
// asserts `true`; for every routine WARN `false`; every non-WARN `false`.
// The sites no fixture reaches (an unloadable document, an unopenable page
// dictionary, a content stream the scanner cannot traverse) are pinned by
// the source census at the end, so a new WARN site cannot land unclassified.

@Suite("could-not-verify flag on LayerResult")
struct CouldNotVerifyFlagTests {

    // MARK: - Helpers

    private enum TestError: Error { case failed }

    /// A document whose second page cannot be opened (`page(at: 1)` is nil)
    /// while `pageCount` still reports it — the per-page loops' unreadable arm.
    private final class UnopenableSecondPageDocument: PDFDocument {
        override func page(at index: Int) -> PDFPage? {
            index == 1 ? nil : super.page(at: index)
        }
    }

    private func unopenableSecondPageDoc() throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cnv_unopenable_\(UUID().uuidString).pdf")
        try TestFixtures.twoBlankPages().write(to: url)
        guard let doc = UnopenableSecondPageDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    private func zeroDigest(page: Int) -> PageFilterDigest {
        PageFilterDigest(pageIndex: page, extractedCount: 0, excludedCount: 0,
                         survivingCount: 0, boundaryCharacters: [])
    }

    private func run(
        _ index: Int, _ doc: PDFDocument, mode: PipelineMode,
        modes: [PipelineMode]? = nil, digests: [PageFilterDigest?]? = nil,
        terms: [String] = [], regions: [Int: [RedactionRegion]] = [:],
        searches: [SearchRecheckRequest] = []
    ) async -> LayerResult {
        let n = doc.pageCount
        let engine = VerificationEngine()
        return await engine.runLayer(
            engine.layers(for: mode)[index], outputDocument: SendablePDFDocument(doc),
            sourcePageCount: n, regions: regions,
            sensitiveTerms: terms.map { SensitiveTerm(text: $0) },
            pipelineMode: mode,
            filterDigests: digests ?? Array(repeating: nil, count: n),
            perPageModes: modes ?? Array(repeating: mode, count: n),
            appliedSearches: searches)
    }

    /// The flag reads `expected`, and a `true` never rides a non-WARN status.
    private func expectFlag(_ r: LayerResult, _ expected: Bool, _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.couldNotVerify == expected,
                "\(label): couldNotVerify must be \(expected); status \(r.status)",
                sourceLocation: sourceLocation)
        #expect(!r.couldNotVerify || r.status.isWarn,
                "\(label): the flag is WARN-only; status \(r.status)",
                sourceLocation: sourceLocation)
    }

    private func message(_ r: LayerResult) -> String {
        switch r.status {
        case .warn(let m), .info(let m), .attention(let m), .fail(let m): m
        case .pass, .skipped: ""
        }
    }

    // MARK: - Layer 1 (Text Extraction)

    @Test("Layer 1: /AcroForm absence unverifiable on a URL-less document → true")
    func layer1AcroFormUnverifiable() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.blankPage()))
        let r = await run(0, doc, mode: .secureRasterization)
        #expect(message(r).contains("Could not verify /AcroForm"), "got \(r.status)")
        expectFlag(r, true, "L1 AcroForm")
    }

    @Test("Layer 1: an unreadable page → true")
    func layer1UnreadablePage() async throws {
        let (doc, url) = try unopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(0, doc, mode: .secureRasterization)
        #expect(message(r).contains("could not be read"), "got \(r.status)")
        expectFlag(r, true, "L1 unreadable")
    }

    @Test("Layer 1: a clean image-only page → PASS, false")
    func layer1Pass() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "cnv_l1_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(0, doc, mode: .secureRasterization)
        #expect(r.status == .pass, "got \(r.status)")
        expectFlag(r, false, "L1 pass")
    }

    // MARK: - Layer 2 (OCR Check)

    // The OCR-not-run path through the DEBUG seam is asserted where the
    // seam's single user lives (`VerificationEngineTests`, the three
    // `onLayer2OCRSimulateError` tests): the seam is one shared closure, so
    // a second concurrent user would replace the first test's predicate.

    @Test("Layer 2 fold: unmappable and unchecked → true; the in-region note, the fill note and clean → false")
    func layer2FoldClassification() {
        typealias Bucket = VerificationEngine.PageOCRBucket
        func fold(_ bucket: Bucket, mode: PipelineMode = .searchableRedaction)
            -> (status: VerificationStatus, flag: Bool) {
            let r = VerificationEngine.foldLayer2PageOutcomes(
                [(page: 1, bucket: bucket)], pipelineMode: mode, documentHasRegions: true)
            return (r.0, r.3)
        }
        let unmappable = fold(.unmappable)
        #expect(unmappable.status.isWarn && unmappable.flag, "unmappable: \(unmappable)")
        let unchecked = fold(.unchecked)
        #expect(unchecked.status.isWarn && unchecked.flag, "unchecked: \(unchecked)")
        let inRegion = fold(.textInRegionSearchable)
        #expect(inRegion.status.isWarn && !inRegion.flag, "in-region text is a note: \(inRegion)")
        let fill = fold(.fillArtifactInRegion)
        #expect(fill.status.isInfo && !fill.flag, "fill note: \(fill)")
        let clean = fold(.clean)
        #expect(clean.status == .pass && !clean.flag, "clean: \(clean)")
        let leak = fold(.sensitiveTermInRegion)
        #expect(leak.status.isFail && !leak.flag, "leak: \(leak)")
    }

    // MARK: - Layer 3 (Binary String Search)

    @Test("Layer 3: all terms too short → true")
    func layer3AllShort() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "cnv_l3_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(2, doc, mode: .secureRasterization, terms: ["ab", "xy"])
        #expect(message(r).contains("shorter than 3 characters"), "got \(r.status)")
        expectFlag(r, true, "L3 all-short")
    }

    @Test("Layer 3: the automaton over its size limit → true")
    func layer3Degraded() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "cnv_l3d_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(2, doc, mode: .secureRasterization, terms: [String(repeating: "a", count: 400_000)])
        #expect(message(r).contains("exceeded size limit"), "got \(r.status)")
        expectFlag(r, true, "L3 degraded")
    }

    @Test("Layer 3: an EXIF hit (a note held as WARN) → false; no terms (INFO) → false")
    func layer3FindingsAndInfo() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.pdfWithDCTImageStream(TestFixtures.exifJPEG(app1Payloads: ["CLASSIFIED"])),
            prefix: "cnv_l3e_")
        defer { try? FileManager.default.removeItem(at: url) }
        let exif = await run(2, doc, mode: .secureRasterization, terms: ["CLASSIFIED"])
        #expect(exif.status.isWarn, "the EXIF hit is a WARN note; got \(exif.status)")
        expectFlag(exif, false, "L3 EXIF note")
        let info = await run(2, doc, mode: .secureRasterization, terms: [])
        #expect(info.status.isInfo, "got \(info.status)")
        expectFlag(info, false, "L3 no terms")
    }

    // MARK: - Layers 4 / 5 (Structure, Metadata)

    @Test("Layer 4: structural notes (a routine WARN) → false")
    func layer4StructuralFindings() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.withCatalogKey("URI"), prefix: "cnv_l4_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(3, doc, mode: .secureRasterization)
        #expect(message(r).contains("Structural findings"), "got \(r.status)")  // LegalPhrases:safe (the engine message)
        expectFlag(r, false, "L4 structural notes")
    }

    @Test("Layer 5: metadata present and the attestation WARN → false")
    func layer5RoutineWarns() async throws {
        let (trapped, u1) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Trapped /True"), prefix: "cnv_l5t_")
        defer { try? FileManager.default.removeItem(at: u1) }
        let present = await run(4, trapped, mode: .secureRasterization)
        #expect(message(present).contains("Metadata present"), "got \(present.status)")
        expectFlag(present, false, "L5 metadata present")

        let (producer, u2) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Producer (SyntheticWriter)"), prefix: "cnv_l5p_")
        defer { try? FileManager.default.removeItem(at: u2) }
        let attest = await run(4, producer, mode: .secureRasterization)
        #expect(message(attest).contains("not rewritten"), "got \(attest.status)")
        expectFlag(attest, false, "L5 attestation")
    }

    // MARK: - Layer 6 (Spatial Verification)

    @Test("Layer 6: characters with no measurable position → true")
    func layer6ZeroBounds() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.zeroBoundsGlyphPDF(text: "AB"), prefix: "cnv_l6z_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(5, doc, mode: .searchableRedaction)
        #expect(message(r).contains("had no measurable position"), "got \(r.status)")
        expectFlag(r, true, "L6 zero-bounds")
    }

    @Test("Layer 6: an edge graze (a positional note) → false")
    func layer6Graze() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "SECRET CONTENT")))
        let page = try #require(doc.page(at: 0))
        let sel = try #require(page.selection(for: NSRange(location: 0, length: 1)))
        let bounds = sel.bounds(for: page)
        let pageBounds = page.bounds(for: .cropBox)
        let sliver = CGRect(x: bounds.minX - 10, y: bounds.minY,
                            width: 10 + bounds.width * 0.2, height: bounds.height)
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: sliver.minX / pageBounds.width, y: sliver.minY / pageBounds.height,
                                   width: sliver.width / pageBounds.width, height: sliver.height / pageBounds.height),
            source: .manual)
        let r = await run(5, doc, mode: .searchableRedaction, regions: [0: [region]])
        #expect(message(r).contains("touches the edge"), "got \(r.status)")
        expectFlag(r, false, "L6 graze")
    }

    @Test("Layer 6: an unreadable searchable page → true; a short per-page mode array → true")
    func layer6UnreadableAndCoverage() async throws {
        let (doc, url) = try unopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }
        let unreadable = await run(5, doc, mode: .searchableRedaction)
        #expect(message(unreadable).contains("could not be read"), "got \(unreadable.status)")
        expectFlag(unreadable, true, "L6 unreadable")

        let (blank, u2) = try TestFixtures.writeTempPDF(TestFixtures.twoBlankPages(), prefix: "cnv_l6c_")
        defer { try? FileManager.default.removeItem(at: u2) }
        let coverage = await run(5, blank, mode: .searchableRedaction, modes: [.searchableRedaction])
        #expect(message(coverage).contains("not checked"), "got \(coverage.status)")
        expectFlag(coverage, true, "L6 coverage")
    }

    // MARK: - Layers 7 / 9 (Character Count, Character Lineage)

    @Test("Layers 7 and 9: a digest-less searchable page beside a checked one → true; full coverage → false",
          arguments: [6, 8])
    func digestLayersPartial(index: Int) async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.twoBlankPages(), prefix: "cnv_l\(index)_")
        defer { try? FileManager.default.removeItem(at: url) }
        let partial = await run(index, doc, mode: .searchableRedaction,
                                digests: [zeroDigest(page: 0), nil])
        #expect(message(partial).contains("Cross-checked 1 of 2"), "got \(partial.status)")
        expectFlag(partial, true, "L\(index + 1) partial digests")

        let full = await run(index, doc, mode: .searchableRedaction,
                             digests: [zeroDigest(page: 0), zeroDigest(page: 1)])
        #expect(!full.status.isWarn && !full.status.isFail, "got \(full.status)")
        expectFlag(full, false, "L\(index + 1) full")
    }

    @Test("Layers 7 and 9: a short per-page mode array → true", arguments: [6, 8])
    func digestLayersCoverage(index: Int) async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.twoBlankPages(), prefix: "cnv_l\(index)c_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(index, doc, mode: .searchableRedaction, modes: [.secureRasterization])
        #expect(message(r).contains("not checked"), "got \(r.status)")
        expectFlag(r, true, "L\(index + 1) coverage")
    }

    // MARK: - Layer 8 (Font Verification)

    @Test("Layer 8: an unreadable searchable page → true; a short per-page mode array → true")
    func layer8UnreadableAndCoverage() async throws {
        let (doc, url) = try unopenableSecondPageDoc()
        defer { try? FileManager.default.removeItem(at: url) }
        let unreadable = await run(7, doc, mode: .searchableRedaction)
        #expect(message(unreadable).contains("could not be read"), "got \(unreadable.status)")
        expectFlag(unreadable, true, "L8 unreadable")

        let (blank, u2) = try TestFixtures.writeTempPDF(TestFixtures.twoBlankPages(), prefix: "cnv_l8c_")
        defer { try? FileManager.default.removeItem(at: u2) }
        let coverage = await run(7, blank, mode: .searchableRedaction, modes: [.searchableRedaction])
        #expect(message(coverage).contains("not checked"), "got \(coverage.status)")
        expectFlag(coverage, true, "L8 coverage")
    }

    @Test("Layers 7 and 8: the verifier's per-page WARNs do not reach the dispatcher (known issue F12-23)")
    func verifierWarnsDroppedByDispatchers() async throws {
        // Layer 8: a page with no page-level /Resources — the verifier WARNs
        // ("font verification skipped"), the dispatcher collects per-page
        // FAILs only and the layer PASSes. Layer 7: a count excess — the same
        // shape. The flag cannot be set at those sites until the dispatchers
        // carry the WARN; the pin comes off with that fix.
        let (noRes, u1) = try TestFixtures.writeTempPDF(TestFixtures.pageWithoutResources(), prefix: "cnv_l8r_")
        defer { try? FileManager.default.removeItem(at: u1) }
        let fontsDirect = try await SandwichVerification().verifyFontsAreMonospace(
            outputPage: #require(noRes.page(at: 0)), pageIndex: 0)
        #expect(fontsDirect.isWarn, "the verifier WARNs on a page with no /Resources; got \(fontsDirect)")

        let (excess, u2) = try TestFixtures.writeTempPDF(
            TestFixtures.textLayerPDF(text: String(repeating: "ABCDEFGHIJ", count: 6), fontSize: 8), prefix: "cnv_l7x_")
        defer { try? FileManager.default.removeItem(at: u2) }
        let countDirect = try await SandwichVerification().verifyCharacterCount(
            outputPage: #require(excess.page(at: 0)), digest: zeroDigest(page: 0))
        #expect(countDirect.isWarn, "sixty characters against a zero digest is a count excess; got \(countDirect)")

        let l8 = await run(7, noRes, mode: .searchableRedaction)
        let l7 = await run(6, excess, mode: .searchableRedaction, digests: [zeroDigest(page: 0)])
        withKnownIssue("F12-23: the Layer 7/8 dispatchers collect per-page FAILs only, so the verifier's WARNs are dropped and both layers PASS") {
            #expect(l8.status.isWarn, "Layer 8 must carry the verifier's WARN; got \(l8.status)")
            #expect(l8.couldNotVerify, "no /Resources: font verification did not run")
            #expect(l7.status.isWarn, "Layer 7 must carry the verifier's WARN; got \(l7.status)")
        }
        expectFlag(l7, false, "L7 count excess is a note")
    }

    // MARK: - Layer 10 (Operator Re-Extraction)

    @Test("Layer 10: all terms too short → true; over the size limit → true; no terms → INFO false; clean → PASS false")
    func layer10() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "cnv_l10_")
        defer { try? FileManager.default.removeItem(at: url) }
        let short = await run(9, doc, mode: .searchableRedaction, terms: ["ab"])
        #expect(message(short).contains("shorter than 3 characters"), "got \(short.status)")
        expectFlag(short, true, "L10 all-short")
        let degraded = await run(9, doc, mode: .searchableRedaction, terms: [String(repeating: "a", count: 400_000)])
        #expect(message(degraded).contains("exceeded size limit"), "got \(degraded.status)")
        expectFlag(degraded, true, "L10 degraded")
        let info = await run(9, doc, mode: .searchableRedaction, terms: [])
        #expect(info.status.isInfo, "got \(info.status)")
        expectFlag(info, false, "L10 no terms")
        let clean = await run(9, doc, mode: .searchableRedaction, terms: ["NONEXISTENT_TERM_12345"])
        #expect(clean.status == .pass, "got \(clean.status)")
        expectFlag(clean, false, "L10 clean")
    }

    // MARK: - Search Re-check

    @Test("Search Re-check: a page that could not be checked → true; no searches → INFO false; a clean re-run → PASS false")
    func searchRecheck() async throws {
        // 300-DPI render of a 40×40-inch page exceeds the searcher's OCR pixel
        // cap → "too large to scan for text" (the layer's unchecked WARN).
        let size = CGSize(width: 40 * 72, height: 40 * 72)
        let img = try TestFixtures.renderedTextImage("CONFIDENTIAL", width: 1600, height: 1600, fontSize: 160)
        let (doc, url) = try await TestFixtures.imagePagesPDF([img], size: size, prefix: "cnv_sr_")
        defer { try? FileManager.default.removeItem(at: url) }
        let unchecked = await run(5, doc, mode: .secureRasterization,
                                  searches: [TestFixtures.textRequest("CONFIDENTIAL")])
        #expect(message(unchecked).contains("could not be checked"), "got \(unchecked.status)")
        expectFlag(unchecked, true, "re-check unchecked")

        let (blank, u2) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "cnv_srb_")
        defer { try? FileManager.default.removeItem(at: u2) }
        let info = await run(5, blank, mode: .secureRasterization)
        #expect(info.status.isInfo, "got \(info.status)")
        expectFlag(info, false, "re-check no searches")
        let clean = await run(5, blank, mode: .secureRasterization,
                              searches: [TestFixtures.textRequest("Delia")])
        #expect(clean.status == .pass, "got \(clean.status)")
        expectFlag(clean, false, "re-check clean")
    }

    // MARK: - Model default

    @Test("LayerResult defaults the flag to false")
    func modelDefault() {
        #expect(LayerResult.mock(status: .warn("x")).couldNotVerify == false)
        let flagged = LayerResult(
            name: "n", symbolName: "s", status: .warn("w"), shortDescription: "w",
            detailDescription: "d", pageReferences: nil, durationSeconds: 0, couldNotVerify: true)
        #expect(flagged.couldNotVerify)
    }

    // MARK: - Source census

    /// Every `.warn(` construction in the four verification files is
    /// classified here — the could-not-verify family (20 sites) and the
    /// routine-note WARNs — so a new site cannot land silently: an
    /// unclassified construction, a moved message or a changed count fails.
    @Test("source census: the could-not-verify family is exactly 20 sites and every WARN construction is classified")
    func warnSiteCensus() throws {
        struct Marker { let text: String; let family: Bool; let sites: Int; let lines: Int }
        let markers: [String: [Marker]] = [
            "VerificationEngine.swift": [
                Marker(text: "Could not verify /AcroForm absence", family: true, sites: 1, lines: 1),
                Marker(text: "All sensitive terms shorter than 3 characters", family: true, sites: 1, lines: 1),
                Marker(text: "Sensitive term search exceeded size limit", family: true, sites: 1, lines: 1),
                Marker(text: "Could not read output PDF for binary search", family: true, sites: 1, lines: 1),
                Marker(text: "Could not inspect document structure", family: true, sites: 1, lines: 1),
                Marker(text: "Could not inspect metadata", family: true, sites: 1, lines: 1),
                Marker(text: "Per-page mode data covered", family: true, sites: 1, lines: 1),
                Marker(text: "Cross-checked \\(checked) of \\(eligible)", family: true, sites: 2, lines: 2),
                Marker(text: "could not be read for this check", family: true, sites: 1, lines: 2),
                Marker(text: "return .warn(msg)", family: false, sites: 0, lines: 1),
                Marker(text: "Verification produced warnings", family: false, sites: 0, lines: 1),
                Marker(text: "Some verification checks were skipped", family: false, sites: 0, lines: 1),
                Marker(text: "return (.warn(warn.message), warn.pages, nil", family: false, sites: 0, lines: 1),
                Marker(text: "Structural findings:", family: false, sites: 0, lines: 1),  // LegalPhrases:safe (the engine message)
                Marker(text: "Auto-injected metadata present: XMP metadata", family: false, sites: 0, lines: 1),
                Marker(text: "Producer or timestamp fields were not rewritten", family: false, sites: 0, lines: 1),
                Marker(text: "File identifier was not derived from the file contents", family: false, sites: 0, lines: 1),
                Marker(text: "\\(prefix): \\(warnings.joined", family: false, sites: 0, lines: 1),
                Marker(text: "return (.warn(msg), exclusionWarnPages", family: false, sites: 0, lines: 1),
            ],
            "Layer2OCRCheck+Sweep.swift": [
                Marker(text: "OCR coordinates could not be mapped to page space", family: true, sites: 1, lines: 1),
                Marker(text: "OCR could not be run on", family: true, sites: 1, lines: 1),
                Marker(text: "OCR detected text within a redacted region", family: false, sites: 0, lines: 1),
            ],
            "SandwichVerification.swift": [
                Marker(text: "had no measurable position", family: true, sites: 1, lines: 1),
                Marker(text: "Could not inspect page fonts on page", family: true, sites: 1, lines: 1),
                Marker(text: "has no page-level /Resources", family: true, sites: 1, lines: 1),
                Marker(text: "All sensitive terms shorter than 3 characters", family: true, sites: 1, lines: 1),
                Marker(text: "Operator-semantic term search exceeded size limit", family: true, sites: 1, lines: 1),
                Marker(text: "Operator scanner unavailable for page", family: true, sites: 1, lines: 1),
                Marker(text: "Operator scanner could not traverse page", family: true, sites: 1, lines: 1),
                Marker(text: "return (.warn(firstGrazeMessage)", family: false, sites: 0, lines: 1),
                Marker(text: "Character count excess on page", family: false, sites: 0, lines: 1),
            ],
            "SearchRecheck.swift": [
                Marker(text: "status: .warn(message)", family: true, sites: 1, lines: 1),
            ],
        ]
        // Pinned `.warn(` construction counts (pattern matches excluded).
        let constructionCounts = ["VerificationEngine.swift": 21, "Layer2OCRCheck+Sweep.swift": 3, "SandwichVerification.swift": 9, "SearchRecheck.swift": 1]

        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RedactionEngine/Verification")
        var familySites = 0
        for (file, list) in markers {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            let constructions = lines.filter { $0.contains(".warn(") && !$0.contains("case .warn(") }
            #expect(constructions.count == constructionCounts[file],
                    "\(file): \(constructions.count) `.warn(` constructions; the census pins \(constructionCounts[file] ?? -1) — classify the new site here and set the flag at it")
            for m in list {
                let hits = lines.filter {
                    $0.contains(m.text) && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                }.count
                #expect(hits == m.lines, "\(file): '\(m.text)' on \(hits) lines, expected \(m.lines)")
                familySites += m.sites
            }
        }
        #expect(familySites == 20, "the could-not-verify family is \(familySites) sites; the contract says 20")
    }
}

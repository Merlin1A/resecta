import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// `LayerResult.hasDetail` — the consumer's seam for the expanded row — and
// the layer template's detail line: a check that has nothing to add to
// its short line emits an EMPTY detail (pass / warn / info / attention /
// fail, and the Layer 7 boundary promotion, whose short line carries the
// count); the skipped arm keeps its sentence (it adds the why). The app
// never string-sniffs engine copy.

@Suite("LayerResult.hasDetail and the template's detail line")
struct LayerResultHasDetailTests {

    private enum TestError: Error { case failed }

    private func run(
        _ index: Int, _ doc: PDFDocument, mode: PipelineMode,
        modes: [PipelineMode]? = nil, digests: [PageFilterDigest?]? = nil,
        terms: [String] = []
    ) async -> LayerResult {
        let n = doc.pageCount
        let engine = VerificationEngine()
        return await engine.runLayer(
            index, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: n, regions: [:],
            sensitiveTerms: terms.map { SensitiveTerm(text: $0) },
            pipelineMode: mode,
            filterDigests: digests ?? Array(repeating: nil, count: n),
            perPageModes: modes ?? Array(repeating: mode, count: n))
    }

    /// `pageCount` empty pages (CGContext-written, no text layer).
    private func blankPDF(pageCount: Int) throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("has_detail_blank_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw TestError.failed
        }
        for _ in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    @Test("hasDetail mirrors the detail's emptiness", arguments: ["", " ", "x"])
    func hasDetailMirrorsDetailDescriptionEmptiness(detail: String) {
        let r = LayerResult(name: "L", symbolName: "s", status: .pass,
                            shortDescription: "", detailDescription: detail,
                            pageReferences: nil, durationSeconds: 0)
        #expect(r.hasDetail == !detail.isEmpty)
    }

    @Test("PASS: no detail beyond the short line")
    func passDetailIsEmpty() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "hd_pass_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(0, doc, mode: .secureRasterization)
        #expect(r.status == .pass, "got \(r.status)")
        #expect(r.shortDescription == "No issues found.")
        #expect(r.detailDescription == "", "got: \(r.detailDescription)")
        #expect(r.hasDetail == false)
    }

    @Test("WARN: the short line is the note; no restating detail")
    func warnDetailIsEmpty() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.withCatalogKey("URI"), prefix: "hd_warn_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(3, doc, mode: .secureRasterization)
        #expect(r.status.isWarn, "got \(r.status)")
        #expect(r.detailDescription == "", "got: \(r.detailDescription)")
        #expect(r.hasDetail == false)
    }

    @Test("INFO: the short line is the note; no restating detail")
    func infoDetailIsEmpty() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(TestFixtures.blankPage(), prefix: "hd_info_")
        defer { try? FileManager.default.removeItem(at: url) }
        // Layer 3 with no sensitive terms → INFO.
        let r = await run(2, doc, mode: .secureRasterization, terms: [])
        #expect(r.status.isInfo, "got \(r.status)")
        #expect(r.detailDescription == "", "got: \(r.detailDescription)")
        #expect(r.hasDetail == false)
    }

    @Test("ATTENTION: the short line names the text that remains; no restating detail")
    func attentionDetailIsEmpty() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermInTextStream(term: "Acme"), prefix: "hd_attention_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(2, doc, mode: .searchableRedaction, terms: ["acme"])
        #expect(r.status.isAttention, "got \(r.status)")
        #expect(r.detailDescription == "", "got: \(r.detailDescription)")
        #expect(r.hasDetail == false)
    }

    @Test("FAIL: the short line names the issue; no restating detail")
    func failDetailIsEmpty() async throws {
        // A text layer on a page declared image-only.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.textLayerPDF(text: "Hello World"), prefix: "hd_fail_")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await run(5, doc, mode: .searchableRedaction, modes: [.secureRasterization])
        #expect(r.status.isFail, "got \(r.status)")
        #expect(r.detailDescription == "", "got: \(r.detailDescription)")
        #expect(r.hasDetail == false)
    }

    @Test("SKIPPED keeps its generic sentence — it adds the why")
    func skippedKeepsItsGenericDetailSentence() async throws {
        let (doc, url) = try blankPDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        // Layer 7 with nil digests on every eligible page → skipped.
        let r = await run(6, doc, mode: .searchableRedaction, digests: [nil, nil])
        #expect(r.status == .skipped, "got \(r.status)")
        #expect(r.shortDescription == "Skipped.")
        #expect(r.detailDescription == "Character Count was not applicable for this pipeline mode.",
                "got: \(r.detailDescription)")
        #expect(r.hasDetail == true)
    }

    @Test("Layer 7's boundary promotion: the short line carries the count; no detail")
    func layer7BoundaryCharacterPromotionDetailIsEmpty() async throws {
        let (doc, url) = try blankPDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        // A digest whose counts match the empty output page and that
        // records one character near a redaction boundary: the count check
        // passes and is promoted to INFO.
        let digest = PageFilterDigest(
            pageIndex: 0, extractedCount: 0, excludedCount: 0, survivingCount: 0,
            boundaryCharacters: [BoundaryCharacterInfo()])
        let r = await run(6, doc, mode: .searchableRedaction, digests: [digest])
        #expect(r.status.isInfo, "got \(r.status)")
        #expect(r.shortDescription == "1 character near redaction boundaries.",
                "got: \(r.shortDescription)")
        #expect(r.detailDescription == "", "got: \(r.detailDescription)")
        #expect(r.hasDetail == false)
    }
}

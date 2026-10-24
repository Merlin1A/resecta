#if canImport(UIKit)
import Testing
import Foundation
import PDFKit
import UIKit
@testable import RedactionEngine

// The manual-capture admission rule's short-surname exception, read through
// the corpus mirror (the app's rule in lockstep, held equal by the app-side
// parity pin): a capitalized word of two or three letters under a manual
// region is a standalone term, so where it recurs elsewhere on the page the
// Binary String Search reads it after the redaction and reports ATTENTION
// (the text is still readable outside every region) — the line-by-line
// capture had dropped every token under four scalars from the term set, and
// with it that recurrence flag. The one-word-region rule is untouched.

@Suite("Manual capture: a short capitalized surname")
struct ManualCaptureShortSurnameTests {

    private typealias Mirror = VerificationCorpusRunnerTests

    /// One page, Helvetica 24: the region's line, then the recurrence.
    private static let lines = ["Ann Lee", "Prepared by Lee for IBM"]

    private static func textPDF() -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont(name: "Helvetica", size: 24)!,
                                                        .foregroundColor: UIColor.black]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 72, y: 80 + 60 * i), withAttributes: attrs)
            }
        }
        return PDFDocument(data: data)!
    }

    /// The seed over the first line ("Ann Lee"): the union of its words'
    /// boxes with a one-point halo, as a hand-drawn region sits.
    private static func firstLineSeed(_ doc: PDFDocument) throws -> Mirror.RegionSeed {
        let page = try #require(doc.page(at: 0))
        let words = TextSpan.words(fullyInside: CGRect(x: 0, y: 0, width: 1, height: 1), on: page)
        let ann = try #require(words.first { $0.text == "Ann" }?.normalizedRect)
        let lee = try #require(words.first { $0.text == "Lee" }?.normalizedRect)
        let rect = ann.union(lee).insetBy(dx: -1 / 612, dy: -1 / 792)
        return Mirror.RegionSeed(gtId: "manual_0", value: "", category: "custom", page: 0, rect: rect)
    }

    private static func table(_ terms: [SensitiveTerm]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: terms.map { ($0.text, $0.requiresTokenBoundary) })
    }

    @Test("A region over \"Ann Lee\" captures Lee as a standalone bounded term; IBM elsewhere is no term")
    func shortSurnameIsAStandaloneTerm() throws {
        let doc = Self.textPDF()
        let seed = try Self.firstLineSeed(doc)
        let capture = Mirror.manualRegionTerms(
            seeds: [seed], doc: doc, polygon: false, textLayerStatus: [0: .rich])
        let terms = Self.table(capture.terms)
        #expect(terms == ["Ann Lee": false, "Ann": true, "Lee": true], "\(terms)")
        #expect(capture.regionsWithoutText == 0)
    }

    @Test("Lee recurring outside the region raises ATTENTION after the redaction; without the standalone term it did not")
    func recurrenceRaisesAttentionAgain() async throws {
        let doc = Self.textPDF()
        let seed = try Self.firstLineSeed(doc)
        let region = try #require(Mirror.region(from: seed, polygon: false))
        let capture = Mirror.manualRegionTerms(
            seeds: [seed], doc: doc, polygon: false, textLayerStatus: [0: .rich])
        let pages = Mirror.buildPages(
            doc: doc, effectiveMode: .searchableRedaction, regionsByPage: [0: [region]],
            textLayerStatus: [0: .rich], hasHiddenOCG: false)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("short_surname_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outcome = try await Mirror.runRedaction(pages: pages, outputURL: outputURL)
        let output = try #require(PDFDocument(url: outputURL))
        #expect(outcome.perPageModes == [.searchableRedaction], "the page went through the Searchable filter")
        #expect(output.page(at: 0)?.string?.contains("Ann Lee") == false, "the region's text is gone")

        let engine = VerificationEngine()
        func layer3(_ terms: [SensitiveTerm]) async -> LayerResult {
            await engine.runLayer(
                .binaryStringSearch,
                outputDocument: SendablePDFDocument(output),
                sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: terms,
                pipelineMode: .searchableRedaction,
                filterDigests: outcome.filterDigests, perPageModes: outcome.perPageModes)
        }
        let withException = await layer3(capture.terms)
        #expect(withException.status == .attention(""),
                "Lee is still readable outside the region: \(withException.status)")
        let lineOnly = await layer3(capture.terms.filter { $0.text == "Ann Lee" })
        #expect(lineOnly.status == .pass, "the line term alone reads nothing: \(lineOnly.status)")
    }
}
#endif

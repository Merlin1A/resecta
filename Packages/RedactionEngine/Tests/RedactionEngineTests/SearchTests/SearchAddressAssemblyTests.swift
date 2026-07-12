import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// RC-4 — Search-leg spatial address assembly.
//
// The detection path (DetectionOrchestrator.detectPage Step 3a) has run
// AddressSpatialAssembler over per-line records since WS1 item 1.6; both
// Search PII-scan legs ran only the flat single-line regex arms, so a
// multi-line address block never became a Search candidate on either leg.
// This suite pins the wiring on both legs — text leg over
// EmbeddedTextSource lines, OCR leg over the normalized OCR line records —
// plus the sample-statement recall contract at the Balanced preset and the
// stability of the non-assembly categories across the wiring.
//
// The sample statement is FULLY SYNTHETIC with a fixture-disclosed value
// set (see the SampleStatementSnapshotTests header); test diagnostics may
// log matched text from it. The synthetic block fixtures reuse the same
// disclosed values.

@Suite("Search-leg address assembly (RC-4)", .tags(.search))
struct SearchAddressAssemblyTests {

    // MARK: - Helpers

    private func runPIIScan(
        doc: PDFDocument,
        categories: Set<PIICategory>,
        vector: PresetThresholdVector?,
        searcher: DocumentSearcher? = nil,
        includeOCR: Bool = false
    ) async -> [SearchResult] {
        let active = searcher ?? DocumentSearcher()
        await active.setThresholdVector(vector)
        let mode = SearchMode.piiScan(
            categories: categories,
            options: SearchOptions(includeOCR: includeOCR)
        )
        let stream = active.search(
            SendablePDFDocument(doc), mode: mode, progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    private func balancedVector() throws -> PresetThresholdVector {
        try #require(
            PresetThresholdBundle.loadFromEngineBundle().presets[.balanced],
            "engine bundle must carry the Balanced preset"
        )
    }

    /// Raw 1-page PDF with a 3-line holder-style address block drawn as three
    /// Tj lines at byte-exact positions (the raw Helvetica Type1 path used by
    /// `TestFixtures.rotatedTextPDF`, so `page.string` / `page.selection(for:)`
    /// stay extractable on both platforms). x=72, y=700/682/664 at 12 pt on a
    /// 612×792 page; 18 pt line pitch keeps the assembler's y-walk engaged
    /// (18/792 ≈ 0.023 normalized, within the 0.08 gap ceiling).
    private func addressBlockPDF(rotation: Int = 0) -> Data {
        let stream = """
            BT /F1 12 Tf 72 700 Td (Delia R. Hartwell) Tj ET
            BT /F1 12 Tf 72 682 Td (4127 N Wrenfield Pl) Tj ET
            BT /F1 12 Tf 72 664 Td (Boise, ID 83702) Tj ET
            """
        let rotateEntry = rotation == 0 ? "" : "/Rotate \(rotation) "
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                \(rotateEntry)/Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// Thread-safe accumulator for the W10 overlap sink.
    private final class OverlapTally: @unchecked Sendable {
        private let lock = NSLock()
        private var accumulated: [PIICategory: Int] = [:]
        func record(_ counts: [PIICategory: Int]) {
            lock.lock(); defer { lock.unlock() }
            for (category, count) in counts {
                accumulated[category, default: 0] += count
            }
        }
        var counts: [PIICategory: Int] {
            lock.lock(); defer { lock.unlock() }
            return accumulated
        }
    }

    // MARK: - Sample-statement recall contract (text leg)

    @Test("Sample statement p1 surfaces the assembled holder address block at Balanced")
    func sampleStatementHolderBlockSurfaces() async throws {
        let data = try TestFixtures.sampleStatementPDF()
        let doc = try #require(PDFDocument(data: data))
        let results = await runPIIScan(
            doc: doc,
            categories: Set(PIICategory.allCases),
            vector: try balancedVector()
        )

        let addressP1 = results.filter { $0.pageIndex == 0 && $0.piiCategory == .address }

        // The assembled holder-block candidate: street line present, spans the
        // holder rows. Geometry transcribed from the Stage-1 snapshot's
        // text-leg detection (normalizedRect [0.0882, 0.7847, 0.8366, 0.0489];
        // the x-span is page-wide because the holder rows share line buckets
        // with the account-summary column).
        let holder = addressP1.first { $0.matchedText.contains("Wrenfield") }
        let holderResult = try #require(
            holder,
            "an assembled address candidate covering the holder street line must surface on p1"
        )
        #expect(holderResult.piiConfidence != nil && holderResult.piiConfidence! >= 0.6,
                "holder-block candidate must clear the Balanced address cutoff (0.6)")
        #expect(holderResult.source == .textLayer)
        #expect(holderResult.term == PIICategory.address.rawValue,
                "detector-row term convention (category rawValue) applies to assembled rows")
        let rect = holderResult.normalizedRect
        #expect(rect.minX <= 0.12 && rect.maxX >= 0.85,
                "holder-block rect must span the holder rows (Stage-1 x ≈ 0.088–0.925), got \(rect)")
        #expect(rect.minY >= 0.75 && rect.maxY <= 0.88 && rect.height <= 0.10,
                "holder-block rect must stay a tight band over the holder rows, got \(rect)")

        // Flat regex arms unchanged: the remittance-box PO-Box hit stays.
        #expect(addressP1.contains { $0.matchedText.contains("Box 4827") },
                "the single-line PO-Box regex hit must still surface alongside assembly")
    }

    @Test("Sample statement non-assembly category counts are unchanged by the wiring")
    func sampleStatementStableCategoryCounts() async throws {
        let data = try TestFixtures.sampleStatementPDF()
        let doc = try #require(PDFDocument(data: data))
        let results = await runPIIScan(
            doc: doc,
            categories: Set(PIICategory.allCases),
            vector: try balancedVector()
        )

        // Pinned from a pre-wiring run of this exact scan at master 6f6962f
        // (text leg, Balanced, all categories, whole document). The address
        // wiring must not move any non-address category. Name counts are
        // deliberately NOT pinned (NER availability varies across hosts).
        let phoneCount = results.filter { $0.piiCategory == .phone }.count
        let emailCount = results.filter { $0.piiCategory == .email }.count
        let accountCount = results.filter { $0.piiCategory == .account }.count
        #expect(phoneCount == 5, "phone count moved")
        #expect(emailCount == 1, "email count moved")
        #expect(accountCount == 0, "account count moved")
    }

    // MARK: - Synthetic block (text leg)

    @Test("Text leg assembles a 3-line address block into one candidate with the union rect")
    func textLegAssemblesBlock() async throws {
        let doc = try #require(PDFDocument(data: addressBlockPDF()))
        let results = await runPIIScan(
            doc: doc, categories: [.address], vector: try balancedVector()
        )

        // The assembled candidate joins the three word-enumerated line texts
        // (periods/commas drop out of the word joins; lines join with ", ").
        let assembled = results.first {
            $0.matchedText.contains("Hartwell") && $0.matchedText.contains("Wrenfield")
        }
        let candidate = try #require(
            assembled,
            "the 3-line block must assemble into one street-form candidate"
        )
        #expect(candidate.piiConfidence == 0.80,
                "street line + state ⇒ the assembler's 0.80 tier")
        #expect(candidate.piiCategory == .address)
        #expect(candidate.matchedText.contains("83702"))
        // Sentinel-ranged assembly: the joined block is its own snippet.
        #expect(candidate.contextSnippet == candidate.matchedText)

        // Union rect spans all three lines: x from 72/612 ≈ 0.118; y band
        // covering baselines 664–700 (+ascent/−descent) on the 792-pt page.
        let rect = candidate.normalizedRect
        #expect(rect.minX > 0.10 && rect.minX < 0.13, "block left edge, got \(rect)")
        #expect(rect.maxX > 0.13 && rect.maxX < 0.45, "block right edge, got \(rect)")
        #expect(rect.minY > 0.82 && rect.minY < 0.85, "block bottom edge, got \(rect)")
        #expect(rect.maxY > 0.88 && rect.maxY < 0.91, "block top edge, got \(rect)")
    }

    @Test("Categories without .address never run assembly")
    func nonAddressCategoriesSkipAssembly() async throws {
        let doc = try #require(PDFDocument(data: addressBlockPDF()))
        let results = await runPIIScan(
            doc: doc, categories: [.phone], vector: try balancedVector()
        )
        #expect(results.allSatisfy { $0.piiCategory != .address },
                "a scan without the address category must not emit address rows")
    }

    @Test("Assembled candidates ride the same raw threshold gate as the regex arms")
    func assembledCandidatesShareThresholdGate() async throws {
        let doc = try #require(PDFDocument(data: addressBlockPDF()))

        // Cutoff above the assembler's ceiling: the assembled 0.80 must drop.
        let gated = await runPIIScan(
            doc: doc, categories: [.address],
            vector: PresetThresholdVector(thresholdsByWireName: ["address": 0.99])
        )
        #expect(gated.filter { $0.piiCategory == .address }.isEmpty,
                "an address cutoff above 0.80 must gate the assembled candidate out")

        // Nil vector: pre-W4 behavior, assembled candidate passes ungated.
        let ungated = await runPIIScan(doc: doc, categories: [.address], vector: nil)
        #expect(ungated.contains { $0.matchedText.contains("Wrenfield") && $0.piiConfidence == 0.80 },
                "with no vector installed the assembled candidate passes through")
    }

    // MARK: - Rotated page (text leg; provider geometry through the wiring)

    @Test("Rotated 180 page emits the assembled candidate in displayed-space coordinates")
    func rotatedPageKeepsDisplayedSpaceGeometry() async throws {
        // Independent expectation: the unrotated ZIP line's rect, transformed
        // test-locally into the /Rotate 180 displayed frame. (On 180 the line
        // stays horizontal; the upward y-walk gathers no participants above
        // the ZIP anchor, so the assembly is the ZIP line alone at the 0.65
        // state tier — same anchor semantics as the detection path.)
        let refDoc = try #require(PDFDocument(data: addressBlockPDF(rotation: 0)))
        let refPage = try #require(refDoc.page(at: 0))
        let refLines = try #require(EmbeddedTextSource.make(from: refPage)).lines
        let zipLine = try #require(refLines.first { $0.text.contains("83702") })
        let zipRect = zipLine.normalizedRect
        let expected = CGRect(
            x: 1 - zipRect.maxX, y: 1 - zipRect.maxY,
            width: zipRect.width, height: zipRect.height
        )

        let doc = try #require(PDFDocument(data: addressBlockPDF(rotation: 180)))
        let results = await runPIIScan(
            doc: doc, categories: [.address], vector: try balancedVector()
        )
        let assembled = results.first { $0.matchedText == zipLine.text }
        let candidate = try #require(
            assembled,
            "the ZIP-anchor assembly must surface on the rotated page"
        )
        #expect(candidate.piiConfidence != nil && candidate.piiConfidence! >= 0.6)
        let rect = candidate.normalizedRect
        #expect(abs(rect.minX - expected.minX) < 0.02 &&
                abs(rect.minY - expected.minY) < 0.02 &&
                abs(rect.width - expected.width) < 0.02 &&
                abs(rect.height - expected.height) < 0.02,
                "rotated assembly rect \(rect) must match the displayed-frame transform \(expected)")
    }

    // MARK: - OCR leg (seeded line records; no Vision dependency)

    @Test("OCR leg assembles a 3-line block from cached line records")
    func ocrLegAssemblesBlock() async throws {
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines([
            OCREngine.TextLine(
                text: "Delia R. Hartwell",
                normalizedRect: CGRect(x: 0.10, y: 0.80, width: 0.15, height: 0.015),
                confidence: 0.95),
            OCREngine.TextLine(
                text: "4127 N Wrenfield Pl",
                normalizedRect: CGRect(x: 0.10, y: 0.78, width: 0.18, height: 0.015),
                confidence: 0.90),
            OCREngine.TextLine(
                text: "Boise, ID 83702",
                normalizedRect: CGRect(x: 0.10, y: 0.76, width: 0.14, height: 0.015),
                confidence: 0.92),
        ], forPageIndex: 0)

        // Blank raw page: no text layer, so the PII scan takes the OCR leg
        // and reads the seeded cache instead of invoking Vision.
        let doc = try #require(PDFDocument(data: TestFixtures.blankPage()))
        let results = await runPIIScan(
            doc: doc, categories: [.address], vector: try balancedVector(),
            searcher: searcher, includeOCR: true
        )

        let assembled = results.first {
            $0.matchedText.contains("Hartwell") && $0.matchedText.contains("Wrenfield")
        }
        let candidate = try #require(
            assembled,
            "the seeded 3-line block must assemble on the OCR leg"
        )
        #expect(candidate.piiConfidence == 0.80)
        #expect(candidate.matchedText.contains("83702"))
        #expect(candidate.contextSnippet == candidate.matchedText)

        // Union of the three seeded rects, no padding (orchestrator parity).
        let rect = candidate.normalizedRect
        #expect(abs(rect.minX - 0.10) < 0.001 && abs(rect.minY - 0.76) < 0.001 &&
                abs(rect.width - 0.18) < 0.001 && abs(rect.maxY - 0.815) < 0.001,
                "assembled rect must equal the seeded-line union, got \(rect)")

        // Sentinel-ranged assembly derives its OCR confidence from the lines
        // the union rect covers (minimum: the street line's 0.90).
        if case .ocr(let confidence) = candidate.source {
            #expect(abs(confidence - 0.90) < 0.001,
                    "assembled OCR confidence must be the covered-line minimum")
        } else {
            Issue.record("assembled OCR-leg result must carry the .ocr source")
        }
    }

    @Test("Assembled candidate and PO-Box regex hit resolve to one result for one span")
    func assembledAndRegexArmResolveToOneResult() async throws {
        let searcher = DocumentSearcher()
        let tally = OverlapTally()
        await searcher.setOverlapSink({ tally.record($0) })
        // Single line: the assembled candidate's text IS the line verbatim, so
        // its located range covers the PO-Box regex hit and the two matches
        // land in one overlap group — the resolver keeps one winner (the
        // PO-Box arm's 0.70 over the state-tier 0.65, outside the dead-band).
        await searcher._testSeedOCRLines([
            OCREngine.TextLine(
                text: "P.O. Box 512, Boise, ID 83701",
                normalizedRect: CGRect(x: 0.10, y: 0.50, width: 0.40, height: 0.02),
                confidence: 0.93),
        ], forPageIndex: 0)

        let doc = try #require(PDFDocument(data: TestFixtures.blankPage()))
        let results = await runPIIScan(
            doc: doc, categories: [.address], vector: try balancedVector(),
            searcher: searcher, includeOCR: true
        )

        let addressResults = results.filter { $0.piiCategory == .address }
        #expect(addressResults.count == 1,
                "one span must yield one resolved address result, got \(addressResults.map(\.matchedText))")
        let winner = try #require(addressResults.first)
        #expect(winner.matchedText.contains("Box 512"))
        // The winner's range is widened to the coalesced group span, so its
        // rect covers the whole seeded line (D05-F1 semantics).
        #expect(winner.normalizedRect.width >= 0.39,
                "coalesced winner must cover the full line, got \(winner.normalizedRect)")
        #expect(tally.counts[.address] == 1,
                "the resolver must report exactly one suppressed address loser")
    }
}

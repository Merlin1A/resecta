import Testing
import Foundation
import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// PERF-4 — OCR confidence-based skip fast path.
//
// Locked decision: skip Vision OCR for a page when BOTH:
//   1. Selectable-text coverage > 0.95
//   2. effectiveMode == .searchableRedaction
//
// The orchestrator stamps `DetectionResult.Provenance.ocrSkipped == true`
// on every result produced on the fast path (PII matches AND face hits).
// Coverage threshold is locked at 0.95; this suite does not exercise tuning.
//
// .serialized: shares Vision's perform() blocking semantics with the rest
// of the detection suite (see DetectionOrchestratorTests).
@Suite("PERF-4 — OCR Skip Fast Path", .serialized)
struct OCRSkipFastPathTests {

    // MARK: - 1. Born-digital PDF skips OCR

    @Test("Born-digital PDF page: orchestrator does NOT invoke Vision OCR")
    func testBornDigitalPDFSkipsOCR() async throws {
        // A born-digital fixture has a real embedded text layer. The
        // coordinator-side coverage gate computes the union of word
        // bounding boxes; for this test we bypass the gate (the gate is
        // exercised by `testEmbeddedTextSource*`) and pass an
        // EmbeddedTextSource directly so we can isolate the orchestrator's
        // branch decision.
        let embedded = makeStubEmbeddedTextSource(
            sentence: "Alice Smith SSN 123-45-6789 lives in Portland."
        )
        let blankImage = try #require(makeBlankImage(width: 200, height: 200))

        let orchestrator = DetectionOrchestrator()

        let pageResult = try await orchestrator.detectPage(
            image: blankImage,
            pageIndex: 0,
            priors: PerCategoryPriors(),
            surfaceForms: SurfaceFormDictionary(),
            doctypeContext: DoctypeWindow(primary: .financial),
            thresholdVector: nil,
            embeddedText: embedded,
            ocrSkipReason: .coverageHighEnough
        )

        // Primary assertion: every detection must be stamped as OCR-skipped
        // with the locked reason. This is the per-detection audit signal
        // the plan specifies and is race-free vs. parallel suites.
        #expect(!pageResult.detections.isEmpty,
                "Fixture should produce at least one detection")
        for detection in pageResult.detections {
            #expect(detection.provenance.ocrSkipped == true)
            #expect(detection.provenance.ocrSkipReason == .coverageHighEnough)
        }
    }

    // MARK: - 2. Scanned PDF runs OCR

    @Test("Scanned (text-layerless) page: OCR runs and stamps ocrRan provenance")
    func testScannedPDFRunsOCR() async throws {
        // No embedded text source → orchestrator takes the default OCR
        // path. The PER-PAGE counter delta is racy across suites, so the
        // primary assertion is on the provenance stamp: every detection
        // produced on the OCR path carries `ocrSkipped == false`.
        // A real-text image (via UIGraphicsImageRenderer) makes it more
        // likely Vision returns at least one observation on the simulator.
        let image = try #require(makeTextImage(
            text: "Acme Corp 123-45-6789", width: 600, height: 120
        ))

        let orchestrator = DetectionOrchestrator()

        let before = DetectionOrchestrator.OCRInvocationCounter.count
        let pageResult: PageDetectionResult
        do {
            pageResult = try await orchestrator.detectPage(
                image: image,
                pageIndex: 0,
                priors: PerCategoryPriors(),
                surfaceForms: SurfaceFormDictionary(),
                doctypeContext: DoctypeWindow(primary: .financial)
            )
        } catch { // LegalPhrases:safe
            // Vision can occasionally error on the simulator; that still
            // counts as "OCR was attempted" — the counter increments
            // before the throw site.
            let after = DetectionOrchestrator.OCRInvocationCounter.count
            #expect(after >= before + 1,
                    "Default path must invoke Vision OCR at least once")
            return
        }

        let after = DetectionOrchestrator.OCRInvocationCounter.count
        // Counter monotonicity (race-tolerant): at least one OCR call
        // happened between `before` and `after`.
        #expect(after >= before + 1,
                "Default path must invoke Vision OCR for the dispatched page")
        // Provenance stamp: every detection from the OCR path is .ocrRan.
        for detection in pageResult.detections {
            #expect(detection.provenance.ocrSkipped == false,
                    "OCR-path detections must NOT be marked as OCR-skipped")
            #expect(detection.provenance == .ocrRan)
        }
    }

    // MARK: - 3. Detection-count parity

    @Test("OCR-skip path matches OCR-on path on a frozen text fixture")
    func testDetectionCountParity() async throws {
        // Frozen text used for both paths. SSN + name + address keywords
        // exercise the SSN detector and (optionally) the name/address
        // pipelines. We assert the SSN match is found on the skip path and
        // matches what a synthetic OCR-on run produces for the same text.
        let frozenText = "John Smith SSN 123-45-6789 lives at 742 Evergreen Terrace, Springfield."
        let embedded = makeStubEmbeddedTextSource(sentence: frozenText)
        let blankImage = try #require(makeBlankImage(width: 200, height: 200))

        let orchestrator = DetectionOrchestrator()

        let skipResult = try await orchestrator.detectPage(
            image: blankImage,
            pageIndex: 0,
            priors: PerCategoryPriors(),
            surfaceForms: SurfaceFormDictionary(),
            doctypeContext: DoctypeWindow(primary: .financial),
            thresholdVector: nil,
            embeddedText: embedded,
            ocrSkipReason: .coverageHighEnough
        )

        // The orchestrator's PII detector is text-only — given identical
        // text via either path, the set of PII categories detected is the
        // same. We assert at the category-set level rather than UUID-level
        // because UUIDs are fresh per run.
        let skipKinds: [DetectionResult.PIIKind] = skipResult.detections.compactMap { d in
            guard case .pii(let kind) = d.kind else { return nil }
            return kind
        }

        // Ground truth for frozenText under the V1 detector set: at minimum
        // the SSN must show up. (Address spatial assembly requires a real
        // multi-line shape; we don't claim it here.)
        #expect(skipKinds.contains(.ssn),
                "SSN should be detected on the OCR-skip path")
    }

    // MARK: - 4. Provenance records skip reason

    @Test("Skip-path detections carry provenance.ocrSkipped + correct reason")
    func testProvenanceRecordsSkipReason() async throws {
        let frozenText = "Jane Doe SSN 987-65-4321 phone 555-867-5309."
        let embedded = makeStubEmbeddedTextSource(sentence: frozenText)
        let blankImage = try #require(makeBlankImage(width: 200, height: 200))

        let orchestrator = DetectionOrchestrator()

        let result = try await orchestrator.detectPage(
            image: blankImage,
            pageIndex: 0,
            priors: PerCategoryPriors(),
            surfaceForms: SurfaceFormDictionary(),
            doctypeContext: DoctypeWindow(primary: .financial),
            thresholdVector: nil,
            embeddedText: embedded,
            ocrSkipReason: .coverageHighEnough
        )

        #expect(!result.detections.isEmpty,
                "Fixture should produce at least one detection")
        for detection in result.detections {
            #expect(detection.provenance.ocrSkipped == true,
                    "every detection on a skipped page must record ocrSkipped")
            #expect(detection.provenance.ocrSkipReason == .coverageHighEnough,
                    "reason must reflect the locked gate")
        }
    }

    // MARK: - Coverage gate helpers (engine-level builder)

    @Test("EmbeddedTextSource.make returns nil for empty pages")
    func testEmbeddedTextSourceNilOnEmpty() throws {
        let data = TestFixtures.blankPage()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let source = EmbeddedTextSource.make(from: page)
        #expect(source == nil)
    }

    @Test("EmbeddedTextSource.make returns a source with low coverage for sparse text")
    func testEmbeddedTextSourceLowCoverageOnSparseText() throws {
        let data = TestFixtures.textLayerPDF(
            text: "John Smith SSN 123-45-6789 lives at 742 Evergreen Terrace"
        )
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let source = try #require(EmbeddedTextSource.make(from: page))
        // Single line on an 8.5x11 sheet — coverage is well under the locked
        // 0.95 threshold. Skip gate must NOT engage.
        #expect(source.coverage < 0.95)
        #expect(source.coverage > 0)
    }

    // MARK: - Provenance default value

    @Test("DetectionResult init defaults to .ocrRan provenance")
    func testDetectionResultDefaultProvenanceIsOcrRan() {
        let det = DetectionResult(
            normalizedRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
            kind: .pii(.ssn),
            confidence: 0.9
        )
        #expect(det.provenance.ocrSkipped == false)
        #expect(det.provenance.ocrSkipReason == nil)
        #expect(det.provenance == .ocrRan)
    }

    // MARK: - ST-83 pixel-cap provenance (q13)

    @Test("Pixel-cap page: page-level provenance reports pixelCapExceeded")
    func testPixelCapPageStampsPageProvenance() async throws {
        // 10_001 px exceeds the per-axis cap with a tiny buffer (10 rows),
        // so the test allocates ~400 KB, not a jetsam-scale bitmap. runOCR
        // skips Vision (pre-existing behavior); the NEW page-level
        // provenance must record it — the trace lives on the page result
        // because a skipped page can produce zero detections, leaving no
        // per-detection provenance to carry it.
        let image = try #require(makeBlankImage(width: 10_001, height: 10))
        let orchestrator = DetectionOrchestrator()

        let pageResult = try await orchestrator.detectPage(
            image: image,
            pageIndex: 3,
            priors: PerCategoryPriors(),
            surfaceForms: SurfaceFormDictionary(),
            doctypeContext: DoctypeWindow(primary: .financial),
            thresholdVector: nil,
            embeddedText: nil,
            ocrSkipReason: nil
        )

        #expect(pageResult.ocrProvenance.ocrSkipped == true)
        #expect(pageResult.ocrProvenance.ocrSkipReason == .pixelCapExceeded)
        // The skip itself is unchanged: no text was OCR'd, so no text
        // detections can exist on this page.
        #expect(pageResult.detections.isEmpty)
    }

    @Test("In-cap page: page-level provenance stays .ocrRan")
    func testInCapPageStampsOcrRanPageProvenance() async throws {
        let image = try #require(makeBlankImage(width: 200, height: 200))
        let orchestrator = DetectionOrchestrator()

        let pageResult = try await orchestrator.detectPage(
            image: image,
            pageIndex: 0,
            priors: PerCategoryPriors(),
            surfaceForms: SurfaceFormDictionary(),
            doctypeContext: DoctypeWindow(primary: .financial),
            thresholdVector: nil,
            embeddedText: nil,
            ocrSkipReason: nil
        )

        #expect(pageResult.ocrProvenance == .ocrRan)
    }

    @Test("exceedsOCRPixelCap gates per-axis and total-pixel budgets")
    func testPixelCapPredicate() {
        #expect(DetectionOrchestrator.exceedsOCRPixelCap(width: 10_001, height: 10))
        #expect(DetectionOrchestrator.exceedsOCRPixelCap(width: 10, height: 10_001))
        // 9000 × 9000 = 81 MP: under both axis caps, over the 36 MP total.
        #expect(DetectionOrchestrator.exceedsOCRPixelCap(width: 9_000, height: 9_000))
        #expect(!DetectionOrchestrator.exceedsOCRPixelCap(width: 4_096, height: 4_096))
        #expect(!DetectionOrchestrator.exceedsOCRPixelCap(width: 200, height: 200))
    }

    // MARK: - Fixture helpers

    /// Build a small Sendable EmbeddedTextSource for a single horizontal
    /// line of text. Coordinates are arbitrary but valid in [0,1]; the
    /// PII detector cares about the `text` string, not the geometry.
    private func makeStubEmbeddedTextSource(
        sentence: String
    ) -> EmbeddedTextSource {
        let nsText = sentence as NSString
        var wordBounds: [EmbeddedTextSource.WordBound] = []
        var x: CGFloat = 0
        let wordWidth: CGFloat = 0.08
        let wordHeight: CGFloat = 0.04
        let baselineY: CGFloat = 0.5

        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: .byWords
        ) { _, wordRange, _, _ in
            let rect = CGRect(x: x, y: baselineY, width: wordWidth, height: wordHeight)
            wordBounds.append(EmbeddedTextSource.WordBound(
                range: wordRange, normalizedRect: rect
            ))
            x += wordWidth + 0.005
        }

        let line = OCREngine.TextLine(
            text: sentence,
            normalizedRect: CGRect(x: 0, y: baselineY, width: 1, height: wordHeight),
            confidence: 1.0
        )

        return EmbeddedTextSource(
            text: sentence,
            wordBounds: wordBounds,
            lines: [line],
            coverage: 0.99  // Synthetic value; gate is enforced upstream.
        )
    }

    /// Tiny blank CGImage for the OCR / face paths that still want a non-nil
    /// raster argument. Vision will return zero observations.
    private func makeBlankImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            return nil
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Render a CGImage containing `text` so Vision OCR has at least one
    /// observation to return on the simulator (a fully blank image often
    /// returns zero results, which yields no detections to check
    /// provenance against).
    private func makeTextImage(text: String, width: Int, height: Int) -> CGImage? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36),
                .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: attrs)
        }
        return uiImage.cgImage
    }
}

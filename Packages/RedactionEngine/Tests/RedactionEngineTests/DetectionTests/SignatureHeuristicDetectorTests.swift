import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// DRAW-3 — Heuristic signature detector tests. Triage-only — these tests
// verify both the detector behavior and the engine-side invariant that the
// detector emits `.pii(.signatureCandidate)` so the state-layer's
// `applyDetectionResults` can route to triage rather than auto-applying.
// The state-layer auto-apply contract itself is also tested at the app
// layer (Tests/ResectaAppTests/SignatureCandidateTriageRoutingTests.swift).
@Suite("Signature Heuristic Detector", .serialized)
struct SignatureHeuristicDetectorTests {

    // MARK: - Fixtures

    /// Render a small page-sized raster containing a "Signature:" label
    /// and (optionally) ink-like content to the right of it. Returns the
    /// CGImage plus the OCR blocks the detector consumes.
    ///
    /// Uses `UIGraphicsImageRenderer` so the drawing context is UIKit's
    /// flipped-y convention; the renderer's CGImage output is top-left
    /// origin (the same orientation `image.cropping(to:)` expects in the
    /// detector). The label text and the candidate-area draw closure both
    /// operate in UIKit coordinates (top-left origin).
    ///
    /// The supplied OCR block uses normalized (bottom-left origin)
    /// coordinates, matching the engine's contract.
    private static func makeFixture(
        labelText: String = "Signature:",
        candidateContent: (CGContext, CGRect) -> Void
    ) -> (CGImage, [OCREngine.TextLine])? {
        let width = 400
        let height = 200
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext

            // White background (UIKit coords, top-left origin).
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Render the label text at pixel (10, 60) (top-left origin).
            (labelText as NSString).draw(
                at: CGPoint(x: 10, y: 60),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24),
                    .foregroundColor: UIColor.black
                ]
            )

            // Candidate area in UIKit (top-left) coords. The detector
            // looks at the rectangle to the right of the label, growing
            // downward by 1.6× the label height. With the label at OCR
            // normalized (0.025, 0.55, 0.375, 0.15) → UIKit pixels
            // y∈[42, 90] in this 400×200 raster, the detector's candidate
            // covers pixels (160…360, 42…90) (height 48). We confine the
            // drawn ink to that vertical band so every stroke is inside
            // what the detector actually samples.
            let candidatePixelRect = CGRect(x: 220, y: 44, width: 160, height: 46)
            candidateContent(ctx, candidatePixelRect)
        }
        guard let image = uiImage.cgImage else { return nil }

        // Label OCR block — pixel rect (x: 10, y: 60, w: ~150, h: ~30)
        // in UIKit top-left coords. Convert to normalized, bottom-left:
        //   x = 10/400 = 0.025
        //   y = 1 - (60+30)/200 = 1 - 0.45 = 0.55
        //   w = 150/400 = 0.375
        //   h = 30/200 = 0.15
        let labelLine = OCREngine.TextLine(
            text: labelText,
            normalizedRect: CGRect(x: 0.025, y: 0.55, width: 0.375, height: 0.15),
            confidence: 0.95
        )
        return (image, [labelLine])
    }

    /// Draw "handwriting-like" curved strokes in the candidate area —
    /// designed to produce both high edge density and clustered curved
    /// edge windows that pass the heuristic. We use multiple passes at
    /// different baselines so the resulting raster has the densely
    /// overlapping curved-stroke pattern characteristic of a signature.
    private static func drawHandwriting(_ ctx: CGContext, _ rect: CGRect) {
        ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Three baselines stacked vertically; each is a sequence of cubic
        // loops to maximize the clustered-edge-windows curvature signal.
        let baselines: [(CGFloat, CGFloat)] = [
            (rect.minY + rect.height * 0.30, 3.0),
            (rect.minY + rect.height * 0.50, 4.0),
            (rect.minY + rect.height * 0.70, 3.0)
        ]
        for (baselineY, lineWidth) in baselines {
            ctx.setLineWidth(lineWidth)
            ctx.beginPath()
            var x = rect.minX + 6
            ctx.move(to: CGPoint(x: x, y: baselineY))
            while x < rect.maxX - 16 {
                // Tight cubic loop: up-left, down-right, swoop-up.
                ctx.addCurve(
                    to: CGPoint(x: x + 14, y: baselineY - 2),
                    control1: CGPoint(x: x + 3, y: baselineY - 12),
                    control2: CGPoint(x: x + 11, y: baselineY + 10)
                )
                ctx.addCurve(
                    to: CGPoint(x: x + 28, y: baselineY + 2),
                    control1: CGPoint(x: x + 17, y: baselineY - 14),
                    control2: CGPoint(x: x + 25, y: baselineY + 12)
                )
                x += 22
            }
            ctx.strokePath()
        }
    }

    /// Draw a typed (printed) name in the candidate area — glyphs sit on a
    /// single baseline near the middle of the rect, leaving the top and
    /// bottom thirds nearly empty. The detector's band-spread check
    /// rejects single-baseline edge distributions.
    private static func drawTypedName(_ ctx: CGContext, _ rect: CGRect) {
        // Use a font size that comfortably fits inside `rect.height` with
        // empty space above and below the glyphs.
        let fontSize = max(12, min(rect.height * 0.6, 26))
        let y = rect.minY + (rect.height - fontSize) * 0.5
        ("Jane Doe" as NSString).draw(
            at: CGPoint(x: rect.minX + 4, y: y),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: UIColor.black
            ]
        )
    }

    // MARK: - Tests

    @Test("Labeled signature box with handwriting is detected")
    func testLabeledSignatureBoxDetected() async throws {
        guard let (image, blocks) = Self.makeFixture(
            candidateContent: { ctx, rect in Self.drawHandwriting(ctx, rect) }
        ) else {
            Issue.record("Could not build fixture")
            return
        }

        let detector = SignatureHeuristicDetector()
        let results = try await detector.detect(in: image, ocrBlocks: blocks)

        #expect(results.count == 1, "Expected exactly one signature suggestion, got \(results.count)")
        guard let first = results.first else { return }
        if case .pii(.signatureCandidate) = first.kind {
            // Expected
        } else {
            Issue.record("Expected .pii(.signatureCandidate), got \(first.kind)")
        }
        // Suggestion should sit to the right of the label, within the page.
        #expect(first.normalizedRect.minX > 0.3, "Suggestion should be right of the label")
        #expect(first.normalizedRect.maxX <= 1.0, "Suggestion stays within the page")
        #expect(first.confidence > 0.0 && first.confidence <= 0.85,
                "Heuristic confidence in (0, 0.85] range")
    }

    @Test("Typed name next to label is not detected as signature")
    func testTypedNameNextToLabelNotDetected() async throws {
        guard let (image, blocks) = Self.makeFixture(
            candidateContent: { ctx, rect in Self.drawTypedName(ctx, rect) }
        ) else {
            Issue.record("Could not build fixture")
            return
        }

        let detector = SignatureHeuristicDetector()
        let results = try await detector.detect(in: image, ocrBlocks: blocks)
        #expect(results.isEmpty, "Typed name should not produce a signature suggestion (got \(results.count))")
    }

    @Test("Empty labeled box is not detected")
    func testEmptyLabeledBoxNotDetected() async throws {
        guard let (image, blocks) = Self.makeFixture(
            candidateContent: { _, _ in /* leave blank */ }
        ) else {
            Issue.record("Could not build fixture")
            return
        }

        let detector = SignatureHeuristicDetector()
        let results = try await detector.detect(in: image, ocrBlocks: blocks)
        #expect(results.isEmpty, "Empty candidate box should produce zero suggestions (got \(results.count))")
    }

    @Test("Signature candidates are emitted with the .signatureCandidate kind so the state layer can route to triage (never auto-apply)")
    func testNeverAutoApplied() async throws {
        // Detector-level contract: every suggestion this detector emits
        // carries `.pii(.signatureCandidate)`. The app-side
        // `RedactionState.applyDetectionResults` matches on that kind and
        // diverts the result into `pendingTriage` instead of creating a
        // region. This test pins the engine half of that contract — the
        // app-side half is pinned by SignatureCandidateTriageRoutingTests.
        guard let (image, blocks) = Self.makeFixture(
            candidateContent: { ctx, rect in Self.drawHandwriting(ctx, rect) }
        ) else {
            Issue.record("Could not build fixture")
            return
        }

        let detector = SignatureHeuristicDetector()
        let results = try await detector.detect(in: image, ocrBlocks: blocks)
        #expect(!results.isEmpty, "Need at least one result to validate kind tagging")
        for result in results {
            if case .pii(.signatureCandidate) = result.kind {
                // Expected — this is the discriminator the state layer
                // matches on to enforce "triage-only, never auto-apply".
            } else {
                Issue.record("Signature detector emitted non-signature kind: \(result.kind)")
            }
        }
    }

    // MARK: - Label matcher unit tests

    @Test("Label matcher accepts the four canonical phrases (case-insensitive, optional trailing punctuation)")
    func labelMatcherAccepts() {
        let accept = [
            "Signature", "signature:", "SIGNATURE.",
            "Sign Here", "sign here:", "SIGN HERE",
            "Signed", "Signed.",
            "Authorized Signature", "authorized signature:"
        ]
        for s in accept {
            #expect(SignatureHeuristicDetector.isSignatureLabel(s),
                    "Expected '\(s)' to be a signature label")
        }
    }

    @Test("Label matcher rejects non-signature text")
    func labelMatcherRejects() {
        let reject = [
            "name", "date", "address:", "applicant signature initials",
            "please sign here", "signature required", ""
        ]
        for s in reject {
            #expect(!SignatureHeuristicDetector.isSignatureLabel(s),
                    "Expected '\(s)' NOT to be a signature label")
        }
    }

    // MARK: - Geometry unit tests

    @Test("Candidate rect lands to the right of the label when space is available")
    func candidateRectRightOf() {
        let label = OCREngine.TextLine(
            text: "Signature:",
            normalizedRect: CGRect(x: 0.05, y: 0.5, width: 0.2, height: 0.05),
            confidence: 0.95
        )
        let rect = SignatureHeuristicDetector.candidateRect(
            for: label, in: [label]
        )
        #expect(rect != nil)
        #expect(rect?.minX == label.normalizedRect.maxX)
        #expect((rect?.width ?? 0) <= 0.5)
        #expect((rect?.width ?? 0) > 0)
    }

    @Test("Candidate rect is bounded by next OCR block on the same row")
    func candidateRectBoundedByNeighbor() {
        let label = OCREngine.TextLine(
            text: "Signature:",
            normalizedRect: CGRect(x: 0.05, y: 0.5, width: 0.15, height: 0.05),
            confidence: 0.95
        )
        let neighbor = OCREngine.TextLine(
            text: "Date:",
            normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05),
            confidence: 0.95
        )
        let rect = SignatureHeuristicDetector.candidateRect(
            for: label, in: [label, neighbor]
        )
        guard let rect else {
            Issue.record("Expected a candidate rect"); return
        }
        // Rect should end just shy of the neighbor's minX.
        #expect(rect.maxX <= neighbor.normalizedRect.minX,
                "Candidate must not overlap the next field")
    }

    // MARK: - Sobel-pass unit tests

    @Test("Sobel pass on a uniform buffer reports zero edges (and zero curvature)")
    func sobelUniformBuffer() throws {
        let w = SignatureHeuristicDetector.workingWidth
        let h = SignatureHeuristicDetector.workingHeight
        var pixels = [UInt8](repeating: 200, count: w * h)
        let analysis = try pixels.withUnsafeBufferPointer { ptr -> SignatureHeuristicDetector.CandidateAnalysis in
            try SignatureHeuristicDetector.sobelPass(pixels: ptr.baseAddress!, width: w, height: h)
        }
        #expect(analysis.density == 0)
        #expect(analysis.curvature == 0)
        _ = pixels  // silence "never mutated" — buffer is read by the pass.
    }

    @Test("Sobel pass on a high-contrast stripe pattern reports density above zero")
    func sobelStripePattern() throws {
        let w = SignatureHeuristicDetector.workingWidth
        let h = SignatureHeuristicDetector.workingHeight
        var pixels = [UInt8](repeating: 255, count: w * h)
        // Vertical black stripes every 4 columns.
        for y in 0..<h {
            for x in 0..<w where x % 4 == 0 {
                pixels[y * w + x] = 0
            }
        }
        let analysis = try pixels.withUnsafeBufferPointer { ptr -> SignatureHeuristicDetector.CandidateAnalysis in
            try SignatureHeuristicDetector.sobelPass(pixels: ptr.baseAddress!, width: w, height: h)
        }
        #expect(analysis.density > 0, "Stripe pattern should have non-zero edge density")
    }

    // MARK: - Cost-guardrail invariants

    @Test("Detector skips the Sobel pass when there are no OCR blocks")
    func skipsWithoutOCR() async throws {
        let w = 100, h = 100
        guard let ctx = createBitmapContext(width: w, height: h) else { return }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return }

        let detector = SignatureHeuristicDetector()
        let results = try await detector.detect(in: image, ocrBlocks: [])
        #expect(results.isEmpty, "No OCR blocks → zero suggestions, no Sobel pass")
    }

    @Test("Detector skips the Sobel pass when no OCR block matches a signature label")
    func skipsWithoutLabel() async throws {
        let w = 100, h = 100
        guard let ctx = createBitmapContext(width: w, height: h) else { return }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return }

        let detector = SignatureHeuristicDetector()
        let blocks = [
            OCREngine.TextLine(
                text: "Date:",
                normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.05),
                confidence: 0.95
            )
        ]
        let results = try await detector.detect(in: image, ocrBlocks: blocks)
        #expect(results.isEmpty, "No signature label → zero suggestions")
    }
}

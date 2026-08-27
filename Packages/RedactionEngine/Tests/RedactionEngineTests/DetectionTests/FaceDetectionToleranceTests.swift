import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// The face pass tolerates a Vision error the same way the barcode pass
// does: a failed pass yields no face boxes on that page and the page's
// other detections stand; cancellation still propagates. The pass is
// replaced through the orchestrator's internal `faceDetection` seam so the
// failure is deterministic on any host.
//
// .serialized: shares Vision's perform() blocking semantics with the rest
// of the detection suite (see DetectionOrchestratorTests).
@Suite("Face-detection error tolerance", .serialized)
struct FaceDetectionToleranceTests {

    private struct ProbeError: Error {}

    private static let sentence = "Alice Smith SSN 123-45-6789 lives in Portland."

    @Test("A failing face pass leaves the page's text-PII detections standing")
    func failingFacePassKeepsTextDetections() async throws {
        var orchestrator = DetectionOrchestrator()
        orchestrator.faceDetection = { _ in throw ProbeError() }
        let image = try #require(makeBlankImage(width: 200, height: 200))

        let result = try await orchestrator.detectPage(
            image: image,
            pageIndex: 0,
            priors: PerCategoryPriors(),
            surfaceForms: SurfaceFormDictionary(),
            doctypeContext: DoctypeWindow(primary: .generic),
            thresholdVector: nil,
            embeddedText: makeStubEmbeddedTextSource(sentence: Self.sentence),
            ocrSkipReason: .coverageHighEnough
        )

        let ssnDetected = result.detections.contains { detection in
            if case .pii(.ssn) = detection.kind { return true }
            return false
        }
        #expect(ssnDetected, "the SSN must survive a failed face pass")
        let faceDetected = result.detections.contains { detection in
            if case .face = detection.kind { return true }
            return false
        }
        #expect(!faceDetected, "a failed face pass yields no face boxes")
    }

    @Test("Cancellation inside the face pass still propagates")
    func cancellationPropagates() async throws {
        var orchestrator = DetectionOrchestrator()
        orchestrator.faceDetection = { _ in throw CancellationError() }
        let image = try #require(makeBlankImage(width: 200, height: 200))

        await #expect(throws: CancellationError.self) {
            _ = try await orchestrator.detectPage(
                image: image,
                pageIndex: 0,
                priors: PerCategoryPriors(),
                surfaceForms: SurfaceFormDictionary(),
                doctypeContext: DoctypeWindow(primary: .generic),
                thresholdVector: nil,
                embeddedText: makeStubEmbeddedTextSource(sentence: Self.sentence),
                ocrSkipReason: .coverageHighEnough
            )
        }
    }

    // MARK: - Helpers

    /// A small Sendable EmbeddedTextSource for one horizontal line of text.
    /// Coordinates are arbitrary but valid in [0,1]; the PII detector reads
    /// the `text` string, not the geometry.
    private func makeStubEmbeddedTextSource(sentence: String) -> EmbeddedTextSource {
        let nsText = sentence as NSString
        var wordBounds: [EmbeddedTextSource.WordBound] = []
        var x: CGFloat = 0
        let wordWidth: CGFloat = 0.08
        let wordHeight: CGFloat = 0.04
        let baselineY: CGFloat = 0.5
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length), options: .byWords
        ) { _, wordRange, _, _ in
            wordBounds.append(EmbeddedTextSource.WordBound(
                range: wordRange,
                normalizedRect: CGRect(x: x, y: baselineY, width: wordWidth, height: wordHeight)))
            x += wordWidth + 0.005
        }
        let line = OCREngine.TextLine(
            text: sentence,
            normalizedRect: CGRect(x: 0, y: baselineY, width: 1, height: wordHeight),
            confidence: 1.0)
        return EmbeddedTextSource(text: sentence, wordBounds: wordBounds, lines: [line], coverage: 0.99)
    }

    /// A blank white raster for the face / barcode / signature passes.
    private func makeBlankImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = createBitmapContext(width: width, height: height) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

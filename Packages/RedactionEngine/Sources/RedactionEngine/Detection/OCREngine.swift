import CoreGraphics
import Vision

// ENGINE §4.2 — Vision OCR for PII detection pipeline.

/// Vision-based text recognition for PII detection.
/// Stateless; uses @concurrent for cooperative thread pool execution.
public struct OCREngine: Sendable {

    public init() {}

    /// Recognized text line with its bounding box in normalized coordinates.
    public struct TextLine: Sendable {
        public let text: String
        /// Bounding box in normalized coordinates (0–1, bottom-left origin),
        /// matching Vision framework output.
        public let normalizedRect: CGRect
        public let confidence: Float
    }

    /// Run OCR on a page image. Returns recognized text lines with positions.
    /// Request parameters route through `OCRConfiguration.search` (OCR
    /// quality program) — one config type per call site.
    @concurrent
    public func recognizeText(
        in image: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel = .fast
    ) async throws -> [TextLine] {
        let request = OCRConfiguration
            .search(recognitionLevel: recognitionLevel)
            .makeRequest()

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        let observations = request.results ?? []
        return observations.compactMap { obs -> TextLine? in
            guard let topCandidate = obs.topCandidates(1).first else { return nil }
            return TextLine(
                text: topCandidate.string,
                normalizedRect: obs.boundingBox,
                confidence: obs.confidence
            )
        }
    }

    /// Extract the full text from all observations, joined by newlines.
    public static func fullText(from lines: [TextLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }
}

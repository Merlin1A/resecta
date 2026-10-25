import CoreGraphics
import Vision

// Vision OCR for PII detection pipeline.

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
        /// For a line of a hidden text layer over a page image whose rect was
        /// fitted to the ink (`DocumentSearcher.inkFittedRect`), the layer's
        /// own line box, which a Searchable export strips; nil otherwise.
        var textLayerRect: CGRect? = nil
        /// The fit fell back to the drift envelope (`DocumentSearcher.inkFit`):
        /// the caller reports the page as not fully analysed.
        var inkFitDegraded: Bool = false
    }

    /// One whitespace-separated token of a recognised line, with its own box
    /// (Vision's `boundingBox(for:)` over the token's range).
    public struct Token: Sendable {
        public let text: String
        /// The recognised line the token belongs to (its order on the page).
        public let line: Int
        /// Bounding box in normalized coordinates (0–1, bottom-left origin).
        public let normalizedRect: CGRect
    }

    /// The tokens of a page image with their boxes, for the ink fit; run
    /// synchronously on the caller's thread (`OCRConfiguration.inkFitTokens`).
    static func recognizeTokens(in image: CGImage, languages: [String]? = nil) throws -> [Token] {
        let request = OCRConfiguration.inkFitTokens.makeRequest()
        if let languages { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: image).perform([request])
        var tokens: [Token] = []
        for (lineIndex, observation) in (request.results ?? []).enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            var index = line.startIndex
            while index < line.endIndex {
                guard let start = line[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                let end = line[start...].firstIndex(where: \.isWhitespace) ?? line.endIndex
                if let box = try candidate.boundingBox(for: start..<end)?.boundingBox {
                    tokens.append(Token(text: String(line[start..<end]), line: lineIndex, normalizedRect: box))
                }
                index = end
            }
        }
        return tokens
    }

    /// The queue Vision's text recognition is performed on: never a thread
    /// of Swift's task pool, which Vision needs free to finish a recognition
    /// (searches whose recognitions blocked every pool thread were seen to
    /// stall together).
    private static let visionQueue = DispatchQueue(label: "com.resecta.ocr.vision", qos: .userInitiated, attributes: .concurrent)

    /// A page image crossing to the Vision queue by value.
    private struct VisionImage: @unchecked Sendable { let image: CGImage }

    /// Run OCR on a page image. Returns recognized text lines with positions.
    /// Request parameters route through `OCRConfiguration.search` (OCR
    /// quality program) — one config type per call site. Performed on
    /// `visionQueue` and awaited, so the caller's task thread does not block.
    @concurrent
    func recognizeText(
        in image: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel = .fast
    ) async throws -> [TextLine] {
        let boxed = VisionImage(image: image)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TextLine], Error>) in
            Self.visionQueue.async {
                let request = OCRConfiguration
                    .search(recognitionLevel: recognitionLevel)
                    .makeRequest()
                let handler = VNImageRequestHandler(cgImage: boxed.image)
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results ?? []
                continuation.resume(returning: observations.compactMap { obs -> TextLine? in
                    guard let topCandidate = obs.topCandidates(1).first else { return nil }
                    return TextLine(
                        text: topCandidate.string,
                        normalizedRect: obs.boundingBox,
                        confidence: obs.confidence
                    )
                })
            }
        }
    }
}

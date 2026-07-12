import CoreGraphics
import Vision

// ENGINE §4.8 — Face detection via Vision framework.

/// Detects faces in page images. Stateless, uses @concurrent.
public struct FaceDetector: Sendable {

    public init() {}

    /// Detect faces in a page image. Returns DetectionResults with 20% padding
    /// for re-identification protection (ENGINE §4.8).
    /// Coordinates are normalized (0–1, bottom-left origin), matching Vision output.
    @concurrent
    public func detect(in image: CGImage) async throws -> [DetectionResult] {
        // PERF-8 / CANCEL-005: entry-level cooperative cancellation ahead of
        // the synchronous Vision wrap, which can take seconds on large pages.
        try Task.checkCancellation()
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        return (request.results ?? []).compactMap { face -> DetectionResult? in
            // Drop sub-floor observations before any
            // geometry work; see `normalizedPaddedRect(confidence:boundingBox:)`.
            guard let rect = Self.normalizedPaddedRect(
                confidence: face.confidence,
                boundingBox: face.boundingBox  // Normalized 0–1, bottom-left origin
            ) else { return nil }

            return DetectionResult(
                normalizedRect: rect,
                kind: .face,
                confidence: Double(face.confidence)
            )
        }
    }

    /// Minimum Vision face confidence. Observations
    /// below this floor are discarded: `VNDetectFaceRectanglesRequest` on
    /// document scans (notably on the simulator) returns occasional very
    /// low-confidence rectangles that are not faces. 0.3 is a conservative
    /// floor — true positives on document images rarely sit below it, and the
    /// padding + clamp below keep the re-identification-protection margin for
    /// every observation that is retained. (ENGINE §4.8)
    static let minimumFaceConfidence: Float = 0.3

    /// Applies the confidence floor, then the 20% padding
    /// and unit-rect clamp. Returns nil for observations below the floor or
    /// whose padded rect clamps to empty. Pure and `nonisolated` so the
    /// floor + padding contract is unit-testable without a live Vision request.
    static func normalizedPaddedRect(
        confidence: Float, boundingBox: CGRect
    ) -> CGRect? {
        // Confidence floor ahead of the geometry.
        guard confidence >= minimumFaceConfidence else { return nil }

        // 20% padding on each side for re-identification protection (ENGINE §4.8)
        // L4 confirmed: padding + clamping works for center, corner, and edge positions.
        var rect = boundingBox.insetBy(
            dx: -boundingBox.width * 0.2,
            dy: -boundingBox.height * 0.2
        )
        // Clamp to valid range
        rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isEmpty else { return nil }
        return rect
    }
}

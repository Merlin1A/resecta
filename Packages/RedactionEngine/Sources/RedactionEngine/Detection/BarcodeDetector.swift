import CoreGraphics
import Vision

// ENGINE §4.19 (DRAW-2) — Barcode / QR detection via Vision framework.
// Mirrors `FaceDetector.swift` shape: stateless `Sendable` struct with a
// single `@concurrent` detect entry point. Holds no state across calls.

/// Detects 1D / 2D barcodes (QR, Aztec, DataMatrix, PDF417, Code 39, Code 128,
/// EAN-8/13, UPC, etc.) in a page image. Stateless; one Vision request per call.
///
/// Coordinates returned are normalized (0–1, bottom-left origin), matching
/// Vision's native `VNBarcodeObservation.boundingBox` convention and the
/// downstream `DetectionResult.normalizedRect` / `RedactionRegion.normalizedRect`
/// convention used across the engine.
///
/// `matchedText` carries the decoded payload string when Vision could extract
/// one (`VNBarcodeObservation.payloadStringValue`). Some symbologies / damaged
/// codes decode without a payload — when `payloadStringValue` is `nil`, the
/// detection is still emitted with a `nil` `matchedText` so the user can still
/// redact the visible code region (the bounding box is the load-bearing output).
public struct BarcodeDetector: Sendable {

    public init() {}

    /// Detect barcodes / QR codes in a page image. Returns DetectionResults
    /// tagged `.pii(.barcode)` with confidence taken from
    /// `VNBarcodeObservation.confidence`.
    ///
    /// Vision's `VNDetectBarcodesRequest` defaults to a broad symbology set;
    /// we do not restrict `request.symbologies` so the detector picks up the
    /// formats most likely to encode sensitive payloads (QR for URLs / contact
    /// payloads; PDF417 for driver-license back; Aztec / DataMatrix for tickets
    /// and labels; 1D for inventory / patient identifiers).
    @concurrent
    public func detect(in image: CGImage) async throws -> [DetectionResult] {
        // PERF-8 / CANCEL-005: entry-level cooperative cancellation ahead of
        // the synchronous Vision wrap.
        try Task.checkCancellation()
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation -> DetectionResult? in
            // Normalized 0–1, bottom-left origin (Vision native convention).
            let rect = observation.boundingBox.intersection(
                CGRect(x: 0, y: 0, width: 1, height: 1)
            )
            guard !rect.isEmpty else { return nil }

            // payloadStringValue may be nil for damaged codes or symbologies
            // that Vision cannot decode end-to-end. Keep the detection so the
            // user can still redact the visible region.
            return DetectionResult(
                normalizedRect: rect,
                kind: .pii(.barcode),
                confidence: Double(observation.confidence),
                matchedText: observation.payloadStringValue
            )
        }
    }
}

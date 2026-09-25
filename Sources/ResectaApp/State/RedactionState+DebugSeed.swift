import Foundation
import RedactionEngine

// The DEBUG-only review seed, moved out of `RedactionState.swift` (the
// hub) as the extension block it already was: the `--seedTriage` launch
// hook's synthetic detections for the Simulator repro of the staged
// review. Compiled in DEBUG only, as before.

#if DEBUG
extension RedactionState {
    /// DEBUG-only review repro hook. Seeds `pendingTriage` (+ matching
    /// `triageSelections`, all-deselected per the review-first arrival rule) with a handful of
    /// synthetic `DetectionResult`s on page 0 so the unified review —
    /// the search sheet's Scan interface, opened by the
    /// `DocumentEditorView` bridge whenever `pendingTriage != nil` —
    /// can be reached on the Simulator WITHOUT running on-device
    /// detection (the Vision/Core-Graphics page-0 rasterize cannot be
    /// serviced on the sim). Invoked from the `--seedTriage` launch
    /// hook in `ResectaApp` (arg name carried from the triage era —
    /// it is test plumbing). Mirrors the real staging in
    /// `PipelineCoordinator.runDetectionPipeline`. Strictly
    /// `#if DEBUG` — no mock data ships in release.
    ///
    /// The synthetic strings below are fabricated test fixtures (not document
    /// content) chosen to span detection kinds and a confidence range so the
    /// review list, kind-filter chips, Select-Where, and "Apply N" are
    /// all exercised — including the review → Dismiss path this unblocks.
    func seedDebugTriage() {
        let mocks: [DetectionResult] = [
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.82, width: 0.34, height: 0.035),
                kind: .pii(.ssn), confidence: 0.97, matchedText: "123-45-6789"),
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.74, width: 0.30, height: 0.035),
                kind: .pii(.email), confidence: 0.93, matchedText: "j.doe@example.com"),
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.66, width: 0.26, height: 0.035),
                kind: .pii(.phone), confidence: 0.88, matchedText: "(555) 010-2934"),
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.58, width: 0.40, height: 0.035),
                kind: .pii(.name), confidence: 0.71, matchedText: "Jordan Avery"),
            DetectionResult(
                normalizedRect: CGRect(x: 0.12, y: 0.50, width: 0.38, height: 0.035),
                kind: .pii(.creditCard), confidence: 0.99, matchedText: "4111 1111 1111 1111"),
            // Second "Jordan Avery" so the Grouped view mode has a real
            // cluster — "Apply Group" is drivable on the sim.
            DetectionResult(
                normalizedRect: CGRect(x: 0.52, y: 0.42, width: 0.40, height: 0.035),
                kind: .pii(.name), confidence: 0.83, matchedText: "Jordan Avery"),
        ]
        pendingTriage = [0: mocks]
        // Review-first arrival: seeded detections arrive all-DESELECTED
        // like every arrival — an empty map, since an absent id reads
        // as not accepted everywhere.
        triageSelections = [:]
        // Mirror the real staging path's sibling writes so the summary
        // banner, its Review re-entry, and the Grouped view mode
        // are all drivable on the Simulator: `detectionResults` backs the
        // banner's Review action, `crossPageEntityGroups` backs "Apply
        // Group", and the run record drives the banner itself.
        detectionResults = [0: mocks]
        crossPageEntityGroups = CrossPageEntityGroup.clusters(from: [0: mocks])
        recordDetectionRun(.staged)
    }
}
#endif

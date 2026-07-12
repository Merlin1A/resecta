import CoreGraphics

// Detection render DPI policy
// (doctype-conditional hook).
//
// The design's hook point, shipped with measured values: .financial pages
// render at 200 DPI (the program's target — tax-form recall; the S8 A/B
// measured SSN/Account/DOB/EIN categories appearing on the packet OCR leg
// at 200 that are invisible at 150), everything else keeps the shipped
// 150 (the A/B also surfaced a Vision face-detection inference-context
// failure on cover-page content at 200 when a classification flip stops
// the financial doctype gate from skipping the face pass — financial
// doctypes never run face detection, so the 200-DPI cohort never feeds
// the fragile leg; see S8 exit notes for the sim-vs-device caveat).
//
// Engine-side (deviation from the design's PipelineCoordinator snippet) so
// the app pipeline and the S8 measurement harness consume the SAME policy
// — the cap arithmetic cannot drift between production and instrument.

public enum DetectionRenderPolicy {

    /// Pixel cap on the largest rendered dimension. 4096 px is ample for
    /// Vision OCR accuracy and bounds memory on photo-sourced PDFs whose
    /// point dimensions equal pixel dimensions.
    public static let maxDetectionPixels: CGFloat = 4096

    /// Target detection-render DPI for a page, seeded by the doctype
    /// window available at render time (nil → no window → default).
    /// V1.x upgrade path per the design: raise .financial to 250 after
    /// the on-device measurement pass.
    public static func detectionDPI(for doctype: DoctypeClass?) -> CGFloat {
        switch doctype {
        case .financial: return 200.0
        case .court, .medical, .foia, .generic, nil: return 150.0
        }
    }

    /// Target DPI with the 4096-px cap applied for a page's effective
    /// (post-rotation) point size: when the target would overflow, the
    /// page renders at exactly the cap — (4096 / largestDim) * 72.
    public static func cappedDetectionDPI(
        for doctype: DoctypeClass?,
        effectiveSize: CGSize
    ) -> CGFloat {
        capped(targetDPI: detectionDPI(for: doctype), effectiveSize: effectiveSize)
    }

    /// Cap arithmetic for an explicit target (the S8 measurement harness
    /// uses this for forced-DPI A/B runs so its cap cannot drift from
    /// production's).
    public static func capped(
        targetDPI: CGFloat,
        effectiveSize: CGSize
    ) -> CGFloat {
        let largestDim = max(effectiveSize.width, effectiveSize.height)
        guard largestDim > 0 else { return targetDPI }
        if largestDim * (targetDPI / 72.0) > maxDetectionPixels {
            return (maxDetectionPixels / largestDim) * 72.0
        }
        return targetDPI
    }
}

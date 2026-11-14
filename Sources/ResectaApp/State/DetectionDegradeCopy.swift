import Foundation
import RedactionEngine

// MARK: - Detection-degrade copy

/// Copy table for the detection-degrade surfaces (one-time toast +
/// persistent Scan-interface banner). An NER-only degrade — the OS-
/// provisioned `.nameType` MobileAsset absent, bundled corpus healthy —
/// is described as such: the corpus-blaming line would be false on a
/// pre-26.4 device. Mechanism-description discipline throughout.
enum DetectionDegradeCopy {
    /// True when the failure list is exactly the NER name model.
    static func isNEROnly(_ failedGazetteers: [String]) -> Bool {
        failedGazetteers ==
            [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue]
    }

    static func toast(failedGazetteers: [String]) -> String {
        isNEROnly(failedGazetteers)
            ? "Name detection degraded \u{2014} this OS version doesn't provide the on-device name model. Other detectors still run."
            : "Detection degraded \u{2014} detection corpus failed to load. Manual redaction tools remain available."
    }

    static func banner(failedGazetteers: [String]) -> String {
        isNEROnly(failedGazetteers)
            ? "Name detection is degraded for this session because the on-device name model isn't available on this OS version. Other detectors and manual redaction tools remain available."
            : "Detection is degraded for this session because the detection corpus failed to load. Manual redaction tools remain available."
    }
}

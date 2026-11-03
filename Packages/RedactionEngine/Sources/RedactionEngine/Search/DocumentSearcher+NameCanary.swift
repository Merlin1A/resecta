import Foundation

// The detector diagnostics a PII Scan kickoff surfaces.
extension DocumentSearcher {

    /// The diagnostics the app reads at each PII Scan kickoff to raise the
    /// degraded-detection toast and banner: the shared detector's load-time
    /// diagnostics (`sharedLoadDiagnostics`).
    @concurrent
    public static func scanKickoffDiagnostics() async -> GazetteerLoadDiagnostics {
        sharedLoadDiagnostics
    }
}

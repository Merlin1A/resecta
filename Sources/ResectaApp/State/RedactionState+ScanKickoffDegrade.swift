import Foundation
import RedactionEngine

// The PII Scan kickoff's degrade surface: the detector diagnostics each
// kickoff reads, recorded on the session (the flag and failure list the
// toast, the Scan banner and the verification degrade line read).

extension RedactionState {
    /// Records a PII Scan kickoff's detector diagnostics on the session.
    /// The first kickoff that reports a failure raises the degrade (the
    /// flag and the failure list) and returns the one-time warning toast to
    /// post; otherwise returns nil. A session already degraded for another
    /// reason gains a name model failure in its list, with no second toast.
    func noteScanKickoffDiagnostics(_ diagnostics: GazetteerLoadDiagnostics) -> String? {
        guard diagnostics.didDegrade else { return nil }
        guard !autoDetectionDegraded else {
            let nameModel = GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue
            if diagnostics.failedGazetteers.contains(nameModel),
               !autoDetectionDegradeFailures.contains(nameModel) {
                autoDetectionDegradeFailures.append(nameModel)
            }
            return nil
        }
        autoDetectionDegraded = true
        autoDetectionDegradeFailures = diagnostics.failedGazetteers
        return DetectionDegradeCopy.toast(failedGazetteers: diagnostics.failedGazetteers)
    }
}

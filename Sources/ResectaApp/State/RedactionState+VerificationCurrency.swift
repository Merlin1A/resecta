import Foundation

// The burned-version guard on the run's verified handlers. A run burns
// the regions of ONE region state (`PipelineRunner.captureRunEntry`) and
// carries that state's `regionVersion` to `.verified` /
// `.verificationSkipped`; the stale flag clears only while that version
// is still the live one, so a region the run did not burn — whatever
// path added it — keeps the results screen's stale banner standing.
// An extension file: `RedactionState.swift` is at its growth ratchet.

extension RedactionState {

    /// Clear `regionsModifiedSinceVerification` for a finished run whose
    /// burned regions are the live ones. `burnedRegionVersion` is the
    /// `regionVersion` the run snapshotted when it built its pages; when
    /// the live version has moved past it, the output does not carry every
    /// region on screen and the flag stands. The one caller is
    /// `PipelineCoordinator.apply(_:)`; `markVerificationCurrent()` stays
    /// the only writer of the flag's `false`.
    func markVerificationCurrent(burnedRegionVersion: Int) {
        guard regionVersion == burnedRegionVersion else { return }
        markVerificationCurrent()
    }
}

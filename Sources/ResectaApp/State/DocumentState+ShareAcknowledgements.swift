import Foundation

// The share-risk confirms' acknowledgements, moved out of
// `DocumentState.swift` (a pure move): marking a confirm acknowledged for
// the send it confirmed, and re-arming every confirm. The flags themselves
// stay stored on `DocumentState` beside the other share state.
extension DocumentState {

    /// Mark the current verification report as user-overridden (FAIL
    /// override). Sets `failShareAcknowledged` — the shadow
    /// `shareNeedsFailConfirm` actually reads — then mirrors the
    /// acknowledgement onto the live `.verified` report's
    /// `userOverrodeFailure` (write-only now; see the shadow doc comment
    /// above).
    func overrideVerificationFailure() {
        guard case .verified(var report) = phase else { return }
        failShareAcknowledged = true
        report.userOverrodeFailure = true
        phase = .verified(report: report)
    }

    /// Mark the current skipped-verification report as acknowledged for
    /// sharing (the one-time skipped-share confirm). Mirrors
    /// `overrideVerificationFailure()`: sets `skippedShareAcknowledged` —
    /// the shadow `shareNeedsSkippedConfirm` actually reads — then mirrors
    /// the acknowledgement onto the live `.verified` report's
    /// `userAcknowledgedSkippedShare`.
    func acknowledgeSkippedShare() {
        guard case .verified(var report) = phase else { return }
        skippedShareAcknowledged = true
        report.userAcknowledgedSkippedShare = true
        phase = .verified(report: report)
    }

    /// Mark the incomplete-WARN share-risk confirm acknowledged for the
    /// current report. No phase guard: unlike the two methods above, this
    /// flag is not mirrored into report-scoped storage, so there is
    /// nothing to mutate back into `phase` — the guard on the READ side
    /// (`transition(to:)`'s reset conditioning) is what gives it correct
    /// per-report lifetime.
    func acknowledgeIncompleteWarnShare() {
        incompleteWarnShareAcknowledged = true
    }

    /// Mark the possible-items line acknowledged for this send attempt — any
    /// confirm family that showed it.
    func acknowledgePossibleItemsShare() {
        possibleItemsShareAcknowledged = true
    }

    /// Re-arm the five share confirms after every share sheet completion,
    /// sent or not: an acknowledgement covers one send, so the NEXT Share tap
    /// for the same report confirms again (a fresh report re-arms them in
    /// `transition(to:)`). Clears every shadow, then — under the `.verified`
    /// guard, the only phase with a report to mirror into — sets
    /// `userOverrodeFailure` / `userAcknowledgedSkippedShare` back to false
    /// so mirror and shadow never disagree. The incomplete-WARN,
    /// concealing-annotations and possible-items flags have no report-side
    /// mirror.
    func rearmShareRiskConfirms() {
        failShareAcknowledged = false
        skippedShareAcknowledged = false
        incompleteWarnShareAcknowledged = false
        concealedAnnotationsShareAcknowledged = false
        possibleItemsShareAcknowledged = false
        guard case .verified(var report) = phase else { return }
        report.userOverrodeFailure = false
        report.userAcknowledgedSkippedShare = false
        phase = .verified(report: report)
    }
}

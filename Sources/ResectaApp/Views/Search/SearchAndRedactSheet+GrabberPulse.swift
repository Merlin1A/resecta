import SwiftUI

extension SearchAndRedactSheet {
    // MARK: - Grabber Pulse

    /// Custom drag-indicator capsule replacing the system
    /// `.presentationDragIndicator(.visible)` for the search sheet
    /// (hidden in `DocumentEditorView`). 36×5pt matches Apple's system
    /// indicator dimensions; gray fill at 0.4 opacity matches the
    /// system tint within an order of magnitude. Pulse is driven by
    /// `grabberPulseScale` via `Anim.attentionPulse`.
    var grabberCapsule: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .scaleEffect(grabberPulseScale)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    /// Detent-change handler for the grabber pulse. Predicate lives on
    /// `CompactFloatDetent.shouldPulseGrabber(...)` so the gating
    /// contract (first-drop, not Reduce Motion, transitions to
    /// compact) is unit-tested separately from this view-side wiring.
    /// The deferred reset settles `grabberPulseScale` back to 1.0
    /// after the 0.45s pulse + 0.45s autoreverse so the scaleEffect
    /// converges to the neutral value even if the visual + state
    /// values diverge during the animation.
    func handleDetentChangeForPulse(newDetent: PresentationDetent) {
        guard CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: newDetent,
            hasAlreadyPulsed: hasPulsedGrabberThisSession,
            reduceMotion: reduceMotion
        ) else { return }
        hasPulsedGrabberThisSession = true
        withAnimation(ResectaTokens.Anim.attentionPulse) {
            grabberPulseScale = 1.4
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(950))
            grabberPulseScale = 1.0
        }
    }
}

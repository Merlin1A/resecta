import UIKit

// Keeps the screen from locking on its own while a run works, so the
// device's auto-lock cannot send the app to the background and cut a long
// redaction or check short. The screen shows the run's progress card
// over a blurred canvas, never the page, while it is held.

/// The one owner of the system idle-timer flag. `DocumentState.phase`
/// hands it every phase change (`update(for:)`), so every way a run ends —
/// success, Stop, a failure, a thrown error, leaving the app, closing the
/// document — releases the flag through the same line, and no path can
/// leave the screen awake. The flag write is a seam: tests pass a recorder
/// and never touch `UIApplication`.
final class RunKeepAwake {
    private let setIdleTimerDisabled: @MainActor (Bool) -> Void

    /// Whether this owner is holding the screen awake now.
    private(set) var isKeepingAwake = false

    init(setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void = {
        UIApplication.shared.isIdleTimerDisabled = $0
    }) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    /// Hold the screen awake in a run phase and let it lock in any other.
    /// Writes only when the answer changes, so progress ticks and the
    /// hand-off from redacting to verifying write nothing.
    func update(for kind: DocumentState.PhaseKind) {
        let wanted = kind.keepsScreenAwake
        guard wanted != isKeepingAwake else { return }
        isKeepingAwake = wanted
        setIdleTimerDisabled(wanted)
    }

    /// An owner that goes away while holding the screen lets it lock.
    isolated deinit {
        if isKeepingAwake { setIdleTimerDisabled(false) }
    }
}

extension DocumentState.PhaseKind {
    /// The run phases, in which the screen is kept awake: detecting (no
    /// production path enters it today), redacting and checking. Importing
    /// and exporting are short and leave the system's auto-lock alone.
    var keepsScreenAwake: Bool {
        switch self {
        case .detecting, .redacting, .verifying: true
        default: false
        }
    }
}

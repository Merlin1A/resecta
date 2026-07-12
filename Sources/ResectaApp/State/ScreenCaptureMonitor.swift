import Foundation
import UIKit

// SEC-3: Screen-capture / mirroring privacy shield.
//
// Observes `UIScreen.capturedDidChangeNotification` (driving `isCaptured`)
// and `UIScreen.didConnectNotification` / `didDisconnectNotification`
// (driving `isMirroring = UIScreen.screens.count > 1`). The derived
// `isShielded` flag is consumed by `DocumentEditorView`, the thumbnail
// strip, and the verification-results sheet — when set, those views swap
// their sensitive content for a `PrivacyShieldView` so the document never
// reaches a screen recorder or external display.
//
// Mechanism-description language (ARCH §1.3 / I6): this monitor reacts to
// the platform's published capture/mirroring signals. It does not claim to
// defeat hardware-level capture paths outside that signal surface.
//
// API notes:
// * `UIScreen.main` / `UIScreen.screens` / `didConnect`/`didDisconnect`
//   notifications are formally deprecated in iOS 16+ in favor of
//   `UIScene`-routed equivalents, but they remain the documented surface
//   for "is the main display currently being mirrored?" and continue to
//   fire reliably on iOS 26. We suppress the deprecation warnings here
//   to keep the SEC-3 posture intact without introducing a scene-
//   delegate detour. Revisit if Apple removes these APIs.

/// MainActor-isolated monitor that drives the SEC-3 privacy shield.
///
/// The `@Observable` machinery delivers per-property change notifications
/// to SwiftUI consumers, so views that read `isShielded` re-evaluate when
/// either underlying flag flips. The class follows the app-target's
/// SE-0466 default (MainActor) — no explicit `@MainActor` is required,
/// matching the pattern used by `PipelineCoordinator` / `DocumentState`.
///
/// `@unchecked Sendable`: MainActor isolation (SE-0466) serializes all
/// mutation; the @Observable macro generates storage that Swift 6 does
/// not infer as Sendable, so the annotation is opt-in to what the
/// runtime already enforces via the MainActor hop. Mirrors
/// `PipelineCoordinator` (`:97`). Required so the RES-01 fix can use
/// `Task { @MainActor [weak self] in }` (PipelineCoordinator.swift:172
/// pattern) without the prior `nonisolated(unsafe) let monitor = self`
/// cycle-forming alias.
@Observable
final class ScreenCaptureMonitor: @unchecked Sendable {
    /// Set when `UIScreen.main.isCaptured == true` (screen recording,
    /// AirPlay receiver, or any other capture path the system reports).
    private(set) var isCaptured: Bool

    /// Set when more than one `UIScreen` is connected — covers AirPlay /
    /// HDMI / wired mirroring. The threshold matches the SEC-3 locked
    /// decision (`UIScreen.screens.count > 1`).
    private(set) var isMirroring: Bool

    /// Convenience for view-side gating. True if either trigger fires.
    var isShielded: Bool { isCaptured || isMirroring }

    // nonisolated(unsafe): assigned once in `init` (on MainActor) and read only in
    // the nonisolated `deinit` to cancel them. `Task<Void, Never>` is Sendable with
    // no concurrent access, so opting these out of the s04 SE-0466 MainActor default
    // keeps the deinit synchronous (RES-01 reachability). These are @Observable-
    // tracked mutable stored properties: plain `nonisolated` is REJECTED ("cannot be
    // applied to mutable stored properties"), so `nonisolated(unsafe)` is the required
    // form. The compiler's "has no effect, consider 'nonisolated'" suggestion is a
    // benign @Observable-macro false-positive — do not act on it (it will not build).
    nonisolated(unsafe) private var captureObservationTask: Task<Void, Never>?
    nonisolated(unsafe) private var screenConnectObservationTask: Task<Void, Never>?
    nonisolated(unsafe) private var screenDisconnectObservationTask: Task<Void, Never>?

    init() {
        // Seed from the current platform state so the shield engages even
        // if the user starts a recording before the app is foregrounded.
        self.isCaptured = Self.readIsCaptured()
        self.isMirroring = Self.readIsMirroring()

        // RES-01: capture `self` weakly in the observer tasks so this
        // monitor can deallocate. The prior `nonisolated(unsafe) let
        // monitor = self` alias formed a strong-reference cycle that
        // pinned the instance for the app lifetime, breaking `deinit`
        // reachability in tests and multi-scene re-instantiation. Pattern
        // mirrors `PipelineCoordinator.memoryWarningTask` (PipelineCoordinator.swift:172).
        //
        // Observe capture state. Each notification re-reads the live
        // `isCaptured` flag — the notification payload doesn't carry the
        // value, so we sample after the change is published.
        captureObservationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIScreen.capturedDidChangeNotification
            ) {
                self?.isCaptured = Self.readIsCaptured()
            }
        }

        // Observe screen-connect / disconnect. Two sibling MainActor
        // Tasks, one per notification, each with `[weak self]` capture
        // so neither retains the monitor. Splitting the streams (vs.
        // the prior `async let` pattern that used a `nonisolated(unsafe)`
        // alias) avoids the cross-isolation `sending 'self'` surface
        // under Swift 6.2 strict concurrency while still letting both
        // notification kinds re-read `UIScreen.screens.count > 1`.
        screenConnectObservationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: ScreenCaptureMonitor.didConnectNotificationName
            ) {
                self?.isMirroring = Self.readIsMirroring()
            }
        }
        screenDisconnectObservationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: ScreenCaptureMonitor.didDisconnectNotificationName
            ) {
                self?.isMirroring = Self.readIsMirroring()
            }
        }
    }

    deinit {
        // Cancel all three observer tasks. The task properties are declared
        // `nonisolated(unsafe)` (see above) so this nonisolated deinit can read and
        // `cancel()` them without hopping to MainActor — they are Sendable,
        // written once in `init`, and never touched concurrently. With the
        // RES-01 `[weak self]` fix, deinit is now reachable (was previously
        // pinned by the strong `monitor = self` alias captured by the tasks).
        captureObservationTask?.cancel()
        screenConnectObservationTask?.cancel()
        screenDisconnectObservationTask?.cancel()
    }

    // MARK: - Platform read helpers (deprecation-suppression seam)

    /// Centralized read of `UIScreen.main.isCaptured`. Encapsulating the
    /// call keeps the deprecation-suppression annotation in one place.
    @available(iOS, deprecated: 26.0)
    private static func readIsCaptured() -> Bool {
        UIScreen.main.isCaptured
    }

    /// Centralized read of `UIScreen.screens.count > 1`. Same rationale
    /// as `readIsCaptured` — the SEC-3 posture pins this API.
    @available(iOS, deprecated: 16.0)
    private static func readIsMirroring() -> Bool {
        UIScreen.screens.count > 1
    }

    /// Centralized notification name lookup. The SEC-3 posture
    /// names `UIScreen.didConnectNotification`; this static keeps the
    /// deprecation-suppression annotation off the call sites above.
    @available(iOS, deprecated: 16.0)
    private static var didConnectNotificationName: Notification.Name {
        UIScreen.didConnectNotification
    }

    @available(iOS, deprecated: 16.0)
    private static var didDisconnectNotificationName: Notification.Name {
        UIScreen.didDisconnectNotification
    }

    // MARK: - Test seam

    /// Test-only entry point that re-reads both platform signals. The
    /// `ScreenCaptureShieldTests` post the system notifications
    /// synthetically; `NotificationCenter` delivery is async with the
    /// AsyncSequence form, so the tests call this from the test body to
    /// force a deterministic refresh on the same runloop tick.
    func refreshFromPlatform() {
        isCaptured = Self.readIsCaptured()
        isMirroring = Self.readIsMirroring()
    }

    #if DEBUG
    /// Test-only mutator. Bypasses the platform read so unit tests can
    /// drive the shield state without juggling `UIScreen` internals.
    func _setForTesting(isCaptured: Bool, isMirroring: Bool) {
        self.isCaptured = isCaptured
        self.isMirroring = isMirroring
    }
    #endif
}

import SwiftUI
import UIKit

// Toast severity system — severity-aware positioning, tinting, and animation.
// Injected via .environment(toastManager) at the ContentView level.

// MARK: - Severity Enum

enum ToastSeverity: Equatable {
    case info
    case success
    case warning
    case error

    var sfSymbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    // Routed through the WCAG-AA text tier: ToastView
    // applies this to the action-button TEXT, the severity glyph, and a
    // 10%-opacity background fill. The text use is what mandates the
    // text tier; the glyph/fill ride along on the same value.
    var tintColor: Color {
        switch self {
        case .info: ResectaTokens.SemanticColor.infoText
        case .success: ResectaTokens.SemanticColor.passText
        case .warning: ResectaTokens.SemanticColor.warnText
        case .error: ResectaTokens.SemanticColor.failText
        }
    }

    var autoDismissSeconds: Double {
        switch self {
        case .info, .success: 2.5
        case .warning, .error: 4.0
        }
    }

    /// Bottom for non-blocking confirmatory toasts; top for attention-demanding alerts.
    var position: ToastPosition {
        switch self {
        case .info, .success: .bottom
        case .warning, .error: .top
        }
    }
}

enum ToastPosition {
    case top, bottom
}

// MARK: - Updated ToastItem

struct ToastItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let severity: ToastSeverity
    let wordCount: Int
    /// Optional action button on the toast — used
    /// for undo affordances. `actionLabel` is the user-visible button
    /// text; `actionHandler` is a @MainActor closure
    /// invoked when the user taps the button. The closure captures
    /// snapshot state at enqueue time; it expires when the toast dismisses.
    let actionLabel: String?
    let actionHandler: (@MainActor () -> Void)?
    // Icon is derived from severity — no optional icon field

    init(
        message: String,
        severity: ToastSeverity,
        actionLabel: String? = nil,
        actionHandler: (@MainActor () -> Void)? = nil
    ) {
        self.message = message
        self.severity = severity
        self.wordCount = message.split(separator: " ").count
        self.actionLabel = actionLabel
        self.actionHandler = actionHandler
    }

    /// Equality by message text and severity for coalescing.
    /// Different-severity toasts with the same message are not coalesced.
    /// `actionLabel` and `actionHandler` are excluded from equality —
    /// closures are non-Equatable and equality drives only coalescing
    /// of duplicate informational toasts; an undo toast is by nature a
    /// one-off action, so duplicate-coalescing on the message text is
    /// the right grain.
    static func == (lhs: ToastItem, rhs: ToastItem) -> Bool {
        lhs.message == rhs.message && lhs.severity == rhs.severity
    }
}

// MARK: - ToastQueueManager

/// Manages toast lifecycle: enqueue, coalesce duplicates, severity-based duration,
/// VoiceOver minimum 5s, auto-dismiss, per-position queue draining.
@Observable @MainActor
final class ToastQueueManager {
    /// Active toasts — at most one per position (top and bottom can coexist).
    private(set) var activeToasts: [ToastItem] = []

    /// Stable version counter for animation tracking. Cheaper than hashing
    /// activeToasts.map(\.id) on every render cycle.
    private(set) var toastVersion: Int = 0

    /// Extra bottom inset ContentView's bottom
    /// host applies so a toast clears a Search/Scan sheet parked at the
    /// compact float. The sheet's own host yields there (an 80-pt float
    /// has no room for a toast), and the app-level copy — no longer
    /// covered by the sheet — would otherwise sit beneath it. Set by
    /// the sheet on detent changes, reset when it disappears; zero at
    /// every other detent and whenever no sheet is up.
    var bottomClearance: CGFloat = 0

    /// Pre-filtered active toasts by position — avoids per-render .filter allocations.
    var activeTopToasts: [ToastItem] {
        activeToasts.filter { $0.severity.position == .top }
    }
    var activeBottomToasts: [ToastItem] {
        activeToasts.filter { $0.severity.position == .bottom }
    }

    private var topQueue: [ToastItem] = []
    private var bottomQueue: [ToastItem] = []
    private var topDismissTask: Task<Void, Never>?
    private var bottomDismissTask: Task<Void, Never>?

    /// Per-position queue cap. Without an upper bound, a
    /// burst-y producer (e.g., a per-region nudge fire that triggers a
    /// toast for every match) can grow a queue past the user's
    /// attention span and stretch toast residency time past the
    /// useful-feedback window. Capped at 32 entries per position; on
    /// overflow the oldest queued (not displayed) entry is dropped,
    /// matching the principle that newer feedback supersedes older
    /// feedback in time-bounded UI. The active toast at each position
    /// is unaffected (still drains via the auto-dismiss tasks).
    static let perPositionQueueCap = 32

    // Display duration from severity floor + word count + VoiceOver minimum.
    // Action-bearing toasts (Undo, Re-run) additionally floor at
    // `actionFloorSeconds` — a short message otherwise expires in ~4s, which
    // in practice is too small a window to notice the affordance, reach for
    // it, and tap. The action closure's lifetime IS the display window,
    // so the floor is what makes the affordance reachable.
    static let actionFloorSeconds: Double = 8.0

    func displayDuration(for item: ToastItem) -> Double {
        let wordBasedDuration = Double(item.wordCount) * 0.5 + 1.0
        let severityFloor = item.severity.autoDismissSeconds
        let voiceOverMinimum: Double = UIAccessibility.isVoiceOverRunning ? 5.0 : 0.0
        let actionFloor: Double = item.actionHandler != nil ? Self.actionFloorSeconds : 0.0
        let result = max(severityFloor, wordBasedDuration, voiceOverMinimum, actionFloor)
        return min(10.0, max(2.5, result))
    }

    /// Check if a toast with the same message and severity is already active or queued.
    private func isDuplicate(_ item: ToastItem) -> Bool {
        activeToasts.contains(where: { $0 == item })
        || (item.severity.position == .top ? topQueue : bottomQueue)
            .contains(where: { $0 == item })
    }

    /// Add a toast to the queue. Duplicate messages are coalesced.
    func enqueue(_ item: ToastItem) {
        guard !isDuplicate(item) else { return }

        let position = item.severity.position
        // Different positions can display simultaneously
        let positionOccupied = activeToasts.contains { $0.severity.position == position }

        if !positionOccupied {
            show(item)
        } else {
            // Cap each per-position queue at 32 entries.
            // On overflow drop the oldest queued entry so the latest
            // notification is the one that lands. The active toast is
            // not touched — only the buffered tail.
            if position == .top {
                topQueue.append(item)
                if topQueue.count > Self.perPositionQueueCap {
                    topQueue.removeFirst(topQueue.count - Self.perPositionQueueCap)
                }
            } else {
                bottomQueue.append(item)
                if bottomQueue.count > Self.perPositionQueueCap {
                    bottomQueue.removeFirst(bottomQueue.count - Self.perPositionQueueCap)
                }
            }
        }
    }

    /// Convenience: enqueue a toast with message and severity.
    func enqueue(_ message: String, severity: ToastSeverity = .info) {
        enqueue(ToastItem(message: message, severity: severity))
    }

    /// Enqueue an action toast — convenience overload
    /// for the undo-toast pattern. `actionHandler` runs from MainActor
    /// when the user taps the button; the toast is dismissed after the
    /// handler runs. `ToastItem.equality` ignores the closure, so
    /// coalescing still keys on (message, severity).
    func enqueue(
        _ message: String,
        severity: ToastSeverity = .info,
        actionLabel: String,
        actionHandler: @escaping @MainActor () -> Void
    ) {
        enqueue(ToastItem(
            message: message,
            severity: severity,
            actionLabel: actionLabel,
            actionHandler: actionHandler
        ))
    }

    /// Dismiss a specific toast and show the next queued item for that position after a gap.
    func dismiss(_ item: ToastItem) {
        let position = item.severity.position

        // Cancel the auto-dismiss task for this position
        if position == .top {
            topDismissTask?.cancel()
        } else {
            bottomDismissTask?.cancel()
        }

        // Route through `Anim.resolved` so Reduce Motion swaps the
        // toast-out easing to the opacity-only fallback. The queue
        // manager is a non-View service, so we read
        // `UIAccessibility.isReduceMotionEnabled` directly — same posture
        // RedactionOverlayView's CADisplayLink-driven handle animation uses
        // for its Reduce-Motion gate.
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(
            ResectaTokens.Anim.resolved(ResectaTokens.Anim.toastOut, reduceMotion: reduceMotion)
        ) {
            activeToasts.removeAll { $0.id == item.id }
        }
        toastVersion &+= 1

        // 0.3s gap between consecutive toasts at the same position
        let drainTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            drainQueue(for: position)
        }

        if position == .top {
            topDismissTask = drainTask
        } else {
            bottomDismissTask = drainTask
        }
    }

    /// Clear all active and queued toasts. Called on document close to prevent
    /// stale context toasts from displaying after a new document opens.
    func clearAll() {
        topDismissTask?.cancel()
        bottomDismissTask?.cancel()
        topDismissTask = nil
        bottomDismissTask = nil
        withAnimation(ResectaTokens.Anim.toastOut) {
            activeToasts.removeAll()
        }
        topQueue.removeAll()
        bottomQueue.removeAll()
    }

    // MARK: - Private

    private func show(_ item: ToastItem) {
        withAnimation(ResectaTokens.Anim.toastIn) {
            activeToasts.append(item)
        }
        toastVersion &+= 1

        // Light haptic on toast appearance
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // VoiceOver announcement on toast appearance
        AccessibilityNotification.Announcement(item.message).post()

        let duration = displayDuration(for: item)
        let position = item.severity.position

        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            dismiss(item)
        }

        if position == .top {
            topDismissTask = task
        } else {
            bottomDismissTask = task
        }
    }

    private func drainQueue(for position: ToastPosition) {
        if position == .top, let next = topQueue.first {
            topQueue.removeFirst()
            show(next)
        } else if position == .bottom, let next = bottomQueue.first {
            bottomQueue.removeFirst()
            show(next)
        }
    }
}

// MARK: - Commit-feedback contract

/// One commit-feedback contract. Every path that promotes marks
/// into redaction regions — triage "Apply N", "Apply Group", Search &
/// Redact's "Apply N" (including PII Scan mode), and the
/// auto-apply-ON detection completion — builds its count message here, so
/// the number the user sees is the count of regions actually created,
/// never the raw detection or selection total.
enum CommitFeedback {
    /// Appended to every non-nil `markedMessage` result —
    /// "Marked" on its own reads as already-redacted, so the suffix
    /// names the step that still has to happen. Its own `static let` so
    /// the pin below is exact-text. At AX3 the
    /// 2-line toast cap may truncate this longer message; the length is accepted.
    static let notYetRedactedSuffix = ". Not redacted until you tap Redact."

    /// "Marked 3 for redaction (2 already covered). Not redacted until
    /// you tap Redact." Returns nil when nothing was created and
    /// nothing was skipped — callers suppress the toast rather than
    /// announce a no-op.
    static func markedMessage(applied: Int, alreadyCovered: Int = 0) -> String? {
        guard applied > 0 || alreadyCovered > 0 else { return nil }
        var message = "Marked \(applied) for redaction"
        if alreadyCovered > 0 {
            message += " (\(alreadyCovered) already covered)"
        }
        message += notYetRedactedSuffix
        return message
    }
}

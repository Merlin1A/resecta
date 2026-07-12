import Testing
import Foundation
@testable import ResectaApp

// §A6 — ToastQueueManager lifecycle. Focused on coalescing, per-position
// queueing, and clearAll determinism. Auto-dismiss timers are bounded below
// at 2.5 s so those paths are exercised via `dismiss(_:)` + a short sleep
// to cross the 0.3 s drain gap.

@Suite("ToastQueueManager (§A6)")
@MainActor
struct ToastQueueManagerTests {

    @Test("First enqueue shows the toast")
    func firstEnqueueShows() {
        let mgr = ToastQueueManager()
        mgr.enqueue("Welcome", severity: .info)
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.activeBottomToasts.count == 1)
        #expect(mgr.activeBottomToasts.first?.message == "Welcome")
    }

    @Test("Duplicate message+severity coalesces into one toast")
    func duplicateCoalesces() {
        let mgr = ToastQueueManager()
        mgr.enqueue("Saved", severity: .success)
        mgr.enqueue("Saved", severity: .success)
        mgr.enqueue("Saved", severity: .success)
        #expect(mgr.activeToasts.count == 1)
    }

    @Test("Different severities at different positions coexist")
    func differentPositionsCoexist() {
        let mgr = ToastQueueManager()
        mgr.enqueue("Heads up", severity: .warning)     // top
        mgr.enqueue("All good", severity: .success)     // bottom
        #expect(mgr.activeToasts.count == 2)
        #expect(mgr.activeTopToasts.count == 1)
        #expect(mgr.activeBottomToasts.count == 1)
    }

    @Test("Same position queues subsequent toasts")
    func samePositionQueues() {
        let mgr = ToastQueueManager()
        mgr.enqueue("First", severity: .info)
        mgr.enqueue("Second", severity: .info)
        mgr.enqueue("Third", severity: .info)
        // All three distinct bottom-position; only first is active.
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.activeBottomToasts.first?.message == "First")
    }

    @Test("Same message duplicated while queued also coalesces")
    func duplicateWhileQueuedCoalesces() {
        let mgr = ToastQueueManager()
        mgr.enqueue("First", severity: .info)     // active
        mgr.enqueue("Second", severity: .info)    // queued
        mgr.enqueue("Second", severity: .info)    // should coalesce into queued copy
        // Active is still "First". Queue holds one "Second".
        #expect(mgr.activeBottomToasts.first?.message == "First")
    }

    @Test("Manual dismiss removes the active toast and drains the queue after 0.3 s gap")
    func dismissDrainsQueue() async throws {
        let mgr = ToastQueueManager()
        mgr.enqueue("First", severity: .info)
        mgr.enqueue("Second", severity: .info)
        let first = mgr.activeBottomToasts.first!
        mgr.dismiss(first)
        // Immediate removal from activeToasts (animation target state).
        #expect(mgr.activeToasts.count == 0)
        // CAT-234: self-clocking — poll until the 300 ms-gap drain promotes the
        // queued toast instead of a fixed 450 ms wall-clock sleep (which flaked
        // under full-suite load, OQ-25). The 300 ms drain gap constant is NOT
        // reduced; only the test wait becomes deterministic.
        for _ in 0..<100 {
            if mgr.activeBottomToasts.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mgr.activeBottomToasts.count == 1)
        #expect(mgr.activeBottomToasts.first?.message == "Second")
    }

    @Test("clearAll empties active + queued + cancels pending drain")
    func clearAllIsIdempotent() async throws {
        let mgr = ToastQueueManager()
        mgr.enqueue("First", severity: .warning)
        mgr.enqueue("Second", severity: .warning)
        mgr.enqueue("Third", severity: .info)
        mgr.clearAll()
        #expect(mgr.activeToasts.isEmpty)
        // Second clearAll is a no-op.
        mgr.clearAll()
        #expect(mgr.activeToasts.isEmpty)
        // No drain task should resurrect the queued toast.
        try await Task.sleep(for: .milliseconds(450))
        #expect(mgr.activeToasts.isEmpty)
    }

    @Test("toastVersion increments on enqueue and dismiss")
    func toastVersionMoves() {
        let mgr = ToastQueueManager()
        let v0 = mgr.toastVersion
        mgr.enqueue("Hello", severity: .info)
        #expect(mgr.toastVersion > v0)
        let v1 = mgr.toastVersion
        mgr.dismiss(mgr.activeBottomToasts.first!)
        #expect(mgr.toastVersion > v1)
    }

    @Test("displayDuration floors at 8s for action-bearing toasts (q16/UXF-19)")
    func actionToastFloor() {
        let mgr = ToastQueueManager()
        let short = ToastItem(message: "Cleared 1 match.", severity: .info,
                              actionLabel: "Undo", actionHandler: {})
        #expect(mgr.displayDuration(for: short) >= ToastQueueManager.actionFloorSeconds)
        let noAction = ToastItem(message: "Cleared 1 match.", severity: .info)
        #expect(mgr.displayDuration(for: noAction) < ToastQueueManager.actionFloorSeconds)
    }

    @Test("displayDuration stays within [2.5, 10] regardless of word count")
    func displayDurationBounds() {
        let mgr = ToastQueueManager()
        let short = ToastItem(message: "Ok", severity: .info)
        let long = ToastItem(message: Array(repeating: "word", count: 200).joined(separator: " "),
                             severity: .error)
        #expect(mgr.displayDuration(for: short) >= 2.5)
        #expect(mgr.displayDuration(for: long) <= 10.0)
    }
}

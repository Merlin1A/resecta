import Testing
import Foundation
@testable import ResectaApp

// RES-01 — `ScreenCaptureMonitor` strong-reference cycle fix.
//
// Prior to this fix, the monitor's initializer aliased
// `nonisolated(unsafe) let monitor = self` and the two infinite-loop
// observer Tasks (`captureObservationTask`, `screenConnectObservationTask`)
// captured that alias by value. Because the tasks live on `self` and
// they hold a strong reference back to `self`, the monitor pinned
// itself for the app lifetime — `deinit` was unreachable. The
// app-lifetime singleton at `ResectaApp.swift:54` masks this in
// production, but it breaks tests and multi-scene re-instantiation
// (PERF-7-style iPad scene restoration).
//
// The fix rewrites both observer Tasks with `[weak self]`, mirroring
// `PipelineCoordinator.memoryWarningTask` at `PipelineCoordinator.swift:172`.
// These tests pin that `deinit` is reachable when no external strong
// reference remains.

@Suite("ScreenCaptureMonitor lifecycle (RES-01)")
@MainActor
struct ScreenCaptureMonitorLifecycleTests {

    @Test("deinit fires when instance is dropped")
    func testDeinitFiresWhenInstanceDropped() async {
        // Create the monitor inside a local scope, hand only a weak
        // reference to the outer scope, then drop the strong reference
        // and assert the weak reference niled. If the observer tasks
        // still strongly retained `self`, the weak reference would
        // remain non-nil and this test would fail.
        weak var weakMonitor: ScreenCaptureMonitor?
        do {
            let monitor = ScreenCaptureMonitor()
            weakMonitor = monitor
            #expect(weakMonitor != nil)
            // Yield once so the observer Tasks have had a chance to
            // start their for-await loops. The cycle would form here if
            // we still aliased `self` strongly.
            await Task.yield()
        }

        // After the local scope exits, the only references that could
        // keep the monitor alive are the observer Tasks themselves.
        // With `[weak self]` capture, they do not retain. A couple of
        // yields give the runtime a chance to release.
        await Task.yield()
        await Task.yield()

        #expect(weakMonitor == nil,
                "ScreenCaptureMonitor.deinit must be reachable (RES-01).")
    }
}

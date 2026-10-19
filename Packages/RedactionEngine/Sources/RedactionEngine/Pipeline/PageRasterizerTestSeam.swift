import Foundation

// Test seam — exercises the per-page verification retry path.
//
// The seam is `#if DEBUG`-gated so release builds carry zero state and no
// hooks. Callers inside `PageRasterizer.rasterize` reach the seam through
// `PageRasterizerTestSeam.shared.recordCallAndShouldFail(...)`; in release
// the entire type compiles to a no-op shim with the same surface so
// the call sites don't need extra gating around individual properties.
//
// **Isolation model.** Earlier drafts used process-wide globals, which
// raced when Swift Testing scheduled tests in parallel:
// `testRetryAtHalfDPISucceeds` and `testRetryRendersAtTheLowestTier` would
// double-increment one another's `rasterizeCallCount`. The seam now keys
// its state on a task-local activation handle so each test can install
// its own `Recorder` via `withActivated(_:body:)`; calls outside that
// scope (i.e. unrelated tests, production builds, the app at runtime)
// see no recorder and the hook short-circuits to `false`.
//
// Concurrency: rasterize runs as `@concurrent`, so the recorder must be
// safely reachable from any cooperative actor. `final class @unchecked
// Sendable` with `NSLock` mirrors the codebase's existing pattern (see
// `ColdStartTimer`). Task-local lookups inherit naturally across Task
// detached/group boundaries spawned inside the test's `withActivated`
// scope.

#if DEBUG
enum PageRasterizerTestSeam {
    /// Per-test recorder. Tests construct one inside `withActivated` so the
    /// state is scoped to the surrounding Task — concurrent tests using the
    /// rasterizer do not contend for the same counters.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        /// The attempts still to fail, per page index.
        private var _remainingFailures: [Int: Int]
        private var _rasterizeCallCount: Int = 0
        private var _dpiCapHistory: [(pageIndex: Int, dpiCap: Int)] = []

        /// Each listed page fails its first `failingAttempts` rasterize
        /// calls (one by default — the retry then succeeds; two drives the
        /// production wrapper's second-failure branch).
        init(simulatedVerifyFailures: Set<Int> = [], failingAttempts: Int = 1) {
            self._remainingFailures = Dictionary(
                uniqueKeysWithValues: simulatedVerifyFailures.map { ($0, failingAttempts) })
        }

        /// Total rasterize calls observed during the activation.
        var rasterizeCallCount: Int {
            lock.lock(); defer { lock.unlock() }; return _rasterizeCallCount
        }

        /// Per-call (pageIndex, dpiCap) tuples in observation order.
        var dpiCapHistory: [(pageIndex: Int, dpiCap: Int)] {
            lock.lock(); defer { lock.unlock() }; return _dpiCapHistory
        }

        /// Record the call entry. Returns true while the page still has a
        /// failing attempt left, in which case the caller should throw
        /// `fillVerificationFailed`; the count is consumed atomically.
        func recordCallAndShouldFail(pageIndex: Int, dpiCap: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            _rasterizeCallCount += 1
            _dpiCapHistory.append((pageIndex: pageIndex, dpiCap: dpiCap))
            guard let remaining = _remainingFailures[pageIndex], remaining > 0 else { return false }
            _remainingFailures[pageIndex] = remaining - 1
            return true
        }
    }

    /// Task-local activation. Nil outside `withActivated`, which means the
    /// rasterize hook short-circuits to `false` and no telemetry is
    /// captured. Concurrent tests are isolated automatically because each
    /// activation scope is its own Task subtree.
    @TaskLocal static var activeRecorder: Recorder?

    /// Run `body` with the seam activated; calls into
    /// `PageRasterizer.rasterize` inside the closure observe `recorder`,
    /// nothing outside does.
    @discardableResult
    static func withActivated<R>(
        _ recorder: Recorder,
        body: () async throws -> R
    ) async rethrows -> R {
        try await $activeRecorder.withValue(recorder, operation: body)
    }

    /// Hook entry point. Returns true to request a simulated
    /// `fillVerificationFailed`; false otherwise. No-op when the seam is
    /// not activated.
    static func recordCallAndShouldFail(pageIndex: Int, dpiCap: Int) -> Bool {
        guard let recorder = activeRecorder else { return false }
        return recorder.recordCallAndShouldFail(pageIndex: pageIndex, dpiCap: dpiCap)
    }
}
#else
enum PageRasterizerTestSeam {
    /// Release-build no-op shim. The recorder retains the surface
    /// for binary compatibility with debug callers but holds no state.
    final class Recorder: @unchecked Sendable {
        init(simulatedVerifyFailures: Set<Int> = [], failingAttempts: Int = 1) {
            _ = simulatedVerifyFailures
            _ = failingAttempts
        }
        var rasterizeCallCount: Int { 0 }
        var dpiCapHistory: [(pageIndex: Int, dpiCap: Int)] { [] }
        func recordCallAndShouldFail(pageIndex: Int, dpiCap: Int) -> Bool { false }
    }

    @TaskLocal static var activeRecorder: Recorder?

    @discardableResult
    static func withActivated<R>(
        _ recorder: Recorder,
        body: () async throws -> R
    ) async rethrows -> R {
        try await body()
    }

    static func recordCallAndShouldFail(pageIndex: Int, dpiCap: Int) -> Bool { false }
}
#endif

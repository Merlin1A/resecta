import Foundation

// PERF-1 test seam — exercises the per-page verification retry path.
//
// The seam is `#if DEBUG`-gated so release builds carry zero state and no
// hooks. Callers inside `PageRasterizer.rasterize` reach the seam through
// `PageRasterizerTestSeam.shared.recordCallAndShouldFail(...)`; in release
// the entire type compiles to a no-op shim with the same public surface so
// the call sites don't need extra gating around individual properties.
//
// **Isolation model.** Earlier drafts used process-wide globals, which
// raced when Swift Testing scheduled tests in parallel (PERF-1
// `testRetryAtHalfDPISucceeds` and `testHalfDPIFloor96` would
// double-increment one another's `rasterizeCallCount`). The seam now keys
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
public enum PageRasterizerTestSeam {
    /// Per-test recorder. Tests construct one inside `withActivated` so the
    /// state is scoped to the surrounding Task — concurrent tests using the
    /// rasterizer do not contend for the same counters.
    public final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _simulatedVerifyFailures: Set<Int>
        private var _rasterizeCallCount: Int = 0
        private var _dpiCapHistory: [(pageIndex: Int, dpiCap: Int)] = []

        public init(simulatedVerifyFailures: Set<Int> = []) {
            self._simulatedVerifyFailures = simulatedVerifyFailures
        }

        /// Failure injections still pending. Tests rarely need to inspect
        /// this directly; expose for completeness.
        public var simulatedVerifyFailures: Set<Int> {
            lock.lock(); defer { lock.unlock() }; return _simulatedVerifyFailures
        }

        /// Total rasterize calls observed during the activation.
        public var rasterizeCallCount: Int {
            lock.lock(); defer { lock.unlock() }; return _rasterizeCallCount
        }

        /// Per-call (pageIndex, dpiCap) tuples in observation order.
        public var dpiCapHistory: [(pageIndex: Int, dpiCap: Int)] {
            lock.lock(); defer { lock.unlock() }; return _dpiCapHistory
        }

        /// Re-prime a page index for the NEXT rasterize call. Used by the
        /// "second-failure propagates" test which needs both attempts to
        /// throw — between them it inserts the index again so the retry
        /// also sees a simulated failure.
        public func insertSimulatedFailure(_ pageIndex: Int) {
            lock.lock(); defer { lock.unlock() }
            _simulatedVerifyFailures.insert(pageIndex)
        }

        /// Record the call entry. Returns true if the configured failure
        /// set includes `pageIndex`, in which case the caller should throw
        /// `fillVerificationFailed`; the page index is consumed atomically
        /// so only the first attempt for that page fails.
        public func recordCallAndShouldFail(pageIndex: Int, dpiCap: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            _rasterizeCallCount += 1
            _dpiCapHistory.append((pageIndex: pageIndex, dpiCap: dpiCap))
            if _simulatedVerifyFailures.contains(pageIndex) {
                _simulatedVerifyFailures.remove(pageIndex)
                return true
            }
            return false
        }
    }

    /// Task-local activation. Nil outside `withActivated`, which means the
    /// rasterize hook short-circuits to `false` and no telemetry is
    /// captured. Concurrent tests are isolated automatically because each
    /// activation scope is its own Task subtree.
    @TaskLocal public static var activeRecorder: Recorder?

    /// Run `body` with the seam activated; calls into
    /// `PageRasterizer.rasterize` inside the closure observe `recorder`,
    /// nothing outside does.
    @discardableResult
    public static func withActivated<R>(
        _ recorder: Recorder,
        body: () async throws -> R
    ) async rethrows -> R {
        try await $activeRecorder.withValue(recorder, operation: body)
    }

    /// Hook entry point. Returns true to request a simulated
    /// `fillVerificationFailed`; false otherwise. No-op when the seam is
    /// not activated.
    public static func recordCallAndShouldFail(pageIndex: Int, dpiCap: Int) -> Bool {
        guard let recorder = activeRecorder else { return false }
        return recorder.recordCallAndShouldFail(pageIndex: pageIndex, dpiCap: dpiCap)
    }
}
#else
public enum PageRasterizerTestSeam {
    /// Release-build no-op shim. The recorder retains the public surface
    /// for binary compatibility with debug callers but holds no state.
    public final class Recorder: @unchecked Sendable {
        public init(simulatedVerifyFailures: Set<Int> = []) { _ = simulatedVerifyFailures }
        public var simulatedVerifyFailures: Set<Int> { [] }
        public var rasterizeCallCount: Int { 0 }
        public var dpiCapHistory: [(pageIndex: Int, dpiCap: Int)] { [] }
        public func insertSimulatedFailure(_ pageIndex: Int) {}
        public func recordCallAndShouldFail(pageIndex: Int, dpiCap: Int) -> Bool { false }
    }

    @TaskLocal public static var activeRecorder: Recorder?

    @discardableResult
    public static func withActivated<R>(
        _ recorder: Recorder,
        body: () async throws -> R
    ) async rethrows -> R {
        try await body()
    }

    public static func recordCallAndShouldFail(pageIndex: Int, dpiCap: Int) -> Bool { false }
}
#endif
